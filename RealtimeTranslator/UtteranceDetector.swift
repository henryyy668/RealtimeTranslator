import AVFoundation

/// 说话人性别(由基频判断)
enum SpeakerGender: String {
    case male
    case female
}

/// 基于能量的语音活动检测(VAD),阈值随环境底噪自适应,
/// 并在说话期间顺带估算基频用于判断说话人性别。
///
/// 状态机:静音 -> 检测到音量超过触发线 -> 触发 onStart 并开始转发缓冲 ->
/// 持续静音超过 hangTime(或说话超过 maxUtterance)-> 触发 onEnd 并自动暂停(半双工),
/// 等流水线(翻译 + 播报)处理完后由外部调用 resume() 恢复。
///
/// 触发线 = max(用户设定的最低阈值, 环境底噪 x 3)。安静房间按滑块走,
/// 车里、街上底噪高时触发线自动抬高,不会把噪音当成说话。
final class UtteranceDetector {
    /// 用户设定的最低触发阈值(RMS),来自设置里的灵敏度滑块
    var threshold: Float = 0.015
    /// 尾部静音多久算一句话结束
    var hangTime: TimeInterval = 0.55
    /// 一句话最长多少秒,超过强制切断送翻,避免嘈杂环境下永远等不到句尾
    var maxUtterance: TimeInterval = 20
    /// 说话前保留几个缓冲,避免吃掉第一个音节
    private let prerollCount = 4

    private var speaking = false
    private var enabled = true
    private var lastVoice = Date.distantPast
    private var speechStart = Date.distantPast
    private var preroll: [AVAudioPCMBuffer] = []
    private var pitches: [Float] = []

    /// 环境底噪估计(RMS),只在没人说话时更新
    private var noiseFloor: Float = 0.003

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

    /// 底噪估计:往下跟得快(环境突然安静立刻生效),往上跟得慢(几秒内适应新的噪音水平),
    /// 并且不会跟到说话的音量上去(有上限)
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

    /// 流水线处理完毕,恢复聆听
    func resume() {
        preroll.removeAll()
        speaking = false
        enabled = true
    }

    func reset() {
        preroll.removeAll()
        pitches.removeAll()
        speaking = false
        enabled = true
        noiseFloor = 0.003
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
