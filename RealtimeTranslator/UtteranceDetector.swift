import AVFoundation

/// 说话人性别(由基频判断)
enum SpeakerGender: String {
    case male
    case female
}

/// 基于能量的语音活动检测(VAD),阈值随环境底噪自适应,
/// 并在说话期间顺带估算基频用于判断说话人性别。
///
/// 状态机:启动后先校准 1 秒底噪(只听不判)-> 静音 -> 音量超过触发线 -> onStart 并转发缓冲 ->
/// 持续静音超过 hangTime(或说话超过 maxUtterance)-> onEnd 并自动暂停(半双工),
/// 等流水线处理完后由外部调用 resume() 恢复;恢复后先空 0.4 秒吃掉喇叭尾音。
///
/// 触发线 = max(用户设定的最低阈值, 环境底噪 x 3)。
final class UtteranceDetector {
    /// 用户设定的最低触发阈值(RMS),来自设置里的灵敏度滑块
    var threshold: Float = 0.015
    /// 尾部静音多久算一句话结束(0.45 是不把一句话切成两半的稳妥下限)
    var hangTime: TimeInterval = 0.45
    /// 一句话最长多少秒,超过强制切断送翻
    var maxUtterance: TimeInterval = 20
    /// 启动后先校准底噪多久(期间不触发)
    var warmupTime: TimeInterval = 1.0
    /// 播报结束后多久内不触发(吃掉喇叭尾音)
    var postPlaybackGuard: TimeInterval = 0.4
    /// 说话前保留几个缓冲,避免吃掉第一个音节
    private let prerollCount = 4

    private var speaking = false
    private var enabled = true
    private var lastVoice = Date.distantPast
    private var speechStart = Date.distantPast
    private var warmupUntil = Date.distantPast
    private var preroll: [AVAudioPCMBuffer] = []
    private var pitches: [Float] = []

    /// 环境底噪估计(RMS),只在没人说话时更新
    private var noiseFloor: Float = 0.003
    private var calibrated = false

    /// 一句话开始(音频线程同步调用,先于第一个 forward)
    var onStart: (() -> Void)?
    /// 一句话结束(音频线程调用,此时检测器已自动暂停)
    var onEnd: (() -> Void)?
    /// 转发属于本句的音频缓冲
    var forward: ((AVAudioPCMBuffer) -> Void)?

    /// 当前实际使用的触发线
    var effectiveThreshold: Float {
        max(threshold, noiseFloor * 3)
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard enabled else { return }
        let level = Self.rms(buffer)
        let now = Date()

        // 校准 / 保护期:只测底噪,不触发
        if now < warmupUntil {
            if calibrated {
                noiseFloor = noiseFloor * 0.8 + level * 0.2
            } else {
                noiseFloor = level
                calibrated = true
            }
            noiseFloor = min(max(noiseFloor, 0.001), 0.15)
            return
        }

        if !speaking {
            updateNoiseFloor(level)

            preroll.append(buffer)
            if preroll.count > prerollCount {
                preroll.removeFirst()
            }
            if level > effectiveThreshold {
                speaking = true
                lastVoice = now
                speechStart = now
                pitches.removeAll()
                onStart?()
                for pending in preroll {
                    forward?(pending)
                }
                preroll.removeAll()
                if let f = Self.pitch(buffer) { pitches.append(f) }
            }
            return
        }

        forward?(buffer)
        if level > effectiveThreshold {
            lastVoice = now
            if let f = Self.pitch(buffer) { pitches.append(f) }
        }

        let silentLongEnough = now.timeIntervalSince(lastVoice) > hangTime
        let tooLong = now.timeIntervalSince(speechStart) > maxUtterance
        if silentLongEnough || tooLong {
            speaking = false
            enabled = false // 半双工:先处理完这句再继续听
            onEnd?()
        }
    }

    /// 底噪估计:往下跟得快,往上跟得慢,不会跟到说话的音量上去
    private func updateNoiseFloor(_ level: Float) {
        if level < noiseFloor {
            noiseFloor = noiseFloor * 0.7 + level * 0.3
        } else if level < noiseFloor * 4 {
            noiseFloor = noiseFloor * 0.97 + level * 0.03
        }
        noiseFloor = min(max(noiseFloor, 0.001), 0.15)
    }

    /// 取出本句说话人的性别判断(基频中位数),数据不足或处于模糊区间返回 nil
    func takeGender() -> SpeakerGender? {
        defer { pitches.removeAll() }
        guard pitches.count >= 3 else { return nil }
        let sorted = pitches.sorted()
        let median = sorted[sorted.count / 2]
        if median < 150 { return .male }
        if median > 175 { return .female }
        return nil
    }

    /// 流水线处理完毕,恢复聆听。先空一小段吃掉喇叭尾音,避免把自己的播报当成新的一句
    func resume() {
        preroll.removeAll()
        speaking = false
        enabled = true
        warmupUntil = Date().addingTimeInterval(postPlaybackGuard)
    }

    /// 会话开始时调用:清状态并进入 1 秒底噪校准
    func reset() {
        preroll.removeAll()
        pitches.removeAll()
        speaking = false
        enabled = true
        calibrated = false
        noiseFloor = 0.003
        warmupUntil = Date().addingTimeInterval(warmupTime)
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count {
            sum += data[i] * data[i]
        }
        return sqrt(sum / Float(count))
    }

    /// 自相关法估算基频(Hz)。先抽样到约 16k 降低运算量,只在 70 到 400 Hz 范围内找峰。
    private static func pitch(_ buffer: AVAudioPCMBuffer) -> Float? {
        guard let data = buffer.floatChannelData?[0] else { return nil }
        let sampleRate = Float(buffer.format.sampleRate)
        let total = Int(buffer.frameLength)
        let step = max(1, Int(sampleRate / 16_000))
        let fs = sampleRate / Float(step)

        var x: [Float] = []
        x.reserveCapacity(total / step + 1)
        var i = 0
        while i < total && x.count < 1024 {
            x.append(data[i])
            i += step
        }
        let count = x.count
        guard count >= 512 else { return nil }

        var mean: Float = 0
        for k in 0..<count { mean += x[k] }
        mean /= Float(count)
        var energy: Float = 0
        for k in 0..<count {
            x[k] -= mean
            energy += x[k] * x[k]
        }
        guard energy > 0 else { return nil }

        let minLag = Int(fs / 400)
        let maxLag = Int(fs / 70)
        guard maxLag < count, minLag > 0 else { return nil }

        var bestLag = 0
        var best: Float = 0
        for lag in minLag...maxLag {
            var sum: Float = 0
            var k = 0
            while k + lag < count {
                sum += x[k] * x[k + lag]
                k += 1
            }
            let norm = sum / energy
            if norm > best {
                best = norm
                bestLag = lag
            }
        }
        guard best > 0.45, bestLag > 0 else { return nil }
        return fs / Float(bestLag)
    }
}
