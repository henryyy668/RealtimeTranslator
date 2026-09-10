import AVFoundation

/// 说话人性别(由基频判断)
enum SpeakerGender: String {
    case male
    case female
}

/// 基于能量的语音活动检测(VAD),阈值随环境底噪自适应,
/// 并在说话期间顺带估算基频用于判断说话人性别。
///
/// 全双工:一句话结束后触发 onEnd,检测器继续听,后面的话一句不漏。
/// suppressed 为 true 时(外放播报期间)不开始新句,避免把自己的播报当成说话。
final class UtteranceDetector {
    var threshold: Float = 0.015
    var hangTime: TimeInterval = 0.6
    var maxUtterance: TimeInterval = 20
    var warmupTime: TimeInterval = 1.0
    var suppressed = false
    private let prerollCount = 4

    private var speaking = false
    private var lastVoice = Date.distantPast
    private var speechStart = Date.distantPast
    private var warmupUntil = Date.distantPast
    private var preroll: [AVAudioPCMBuffer] = []
    private var pitches: [Float] = []

    private var noiseFloor: Float = 0.003
    private var calibrated = false

    var onStart: (() -> Void)?
    var onEnd: ((SpeakerGender?) -> Void)?
    var forward: ((AVAudioPCMBuffer) -> Void)?

    var effectiveThreshold: Float {
        max(threshold, noiseFloor * 3)
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        let level = Self.rms(buffer)
        let now = Date()

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
            if !suppressed, level > effectiveThreshold {
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
            let gender = takeGender()
            preroll.removeAll()
            onEnd?(gender)
        }
    }

    private func updateNoiseFloor(_ level: Float) {
        if level < noiseFloor {
            noiseFloor = noiseFloor * 0.7 + level * 0.3
        } else if level < noiseFloor * 4 {
            noiseFloor = noiseFloor * 0.97 + level * 0.03
        }
        noiseFloor = min(max(noiseFloor, 0.001), 0.15)
    }

    private func takeGender() -> SpeakerGender? {
        defer { pitches.removeAll() }
        guard pitches.count >= 3 else { return nil }
        let sorted = pitches.sorted()
        let median = sorted[sorted.count / 2]
        if median < 150 { return .male }
        if median > 175 { return .female }
        return nil
    }

    func reset() {
        preroll.removeAll()
        pitches.removeAll()
        speaking = false
        suppressed = false
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
