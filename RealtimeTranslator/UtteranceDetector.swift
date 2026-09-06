import AVFoundation

/// 基于能量的语音活动检测(VAD)。
///
/// 状态机:静音 -> 检测到音量超过阈值 -> 触发 onStart 并开始转发缓冲 ->
/// 持续静音超过 hangTime -> 触发 onEnd 并自动暂停(半双工),
/// 等流水线(翻译 + 播报)处理完后由外部调用 resume() 恢复,
/// 避免把自己播的译文又当成新的一句话录进去。
final class UtteranceDetector {
    /// 触发阈值(RMS),环境越吵需要越高
    var threshold: Float = 0.015
    /// 尾部静音多久算一句话结束
    private let hangTime: TimeInterval = 0.9
    /// 说话前保留几个缓冲,避免吃掉第一个音节
    private let prerollCount = 4

    private var speaking = false
    private var enabled = true
    private var lastVoice = Date.distantPast
    private var preroll: [AVAudioPCMBuffer] = []

    /// 一句话开始(音频线程同步调用,先于第一个 forward)
    var onStart: (() -> Void)?
    /// 一句话结束(音频线程调用,此时检测器已自动暂停)
    var onEnd: (() -> Void)?
    /// 转发属于本句的音频缓冲
    var forward: ((AVAudioPCMBuffer) -> Void)?

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard enabled else { return }
        let level = Self.rms(buffer)
        let now = Date()

        if !speaking {
            preroll.append(buffer)
            if preroll.count > prerollCount {
                preroll.removeFirst()
            }
            if level > threshold {
                speaking = true
                lastVoice = now
                onStart?()
                for pending in preroll {
                    forward?(pending)
                }
                preroll.removeAll()
            }
            return
        }

        forward?(buffer)
        if level > threshold {
            lastVoice = now
        } else if now.timeIntervalSince(lastVoice) > hangTime {
            speaking = false
            enabled = false // 半双工:先处理完这句再继续听
            onEnd?()
        }
    }

    /// 流水线处理完毕,恢复聆听
    func resume() {
        preroll.removeAll()
        speaking = false
        enabled = true
    }

    func reset() {
        preroll.removeAll()
        speaking = false
        enabled = true
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
}
