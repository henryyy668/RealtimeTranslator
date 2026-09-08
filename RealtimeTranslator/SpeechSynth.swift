import AVFoundation

/// 语音合成:不直接外放,而是用 AVSpeechSynthesizer.write 拿到 PCM 缓冲,
/// 统一转换成播放格式后交给 AudioManager 按声道播放。
final class SpeechSynth {
    private let synthesizer = AVSpeechSynthesizer()

    /// 把一段文字合成为指定格式的 PCM 缓冲数组;gender 传 nil 用系统默认声音
    func render(
        _ text: String,
        lang: Lang,
        to format: AVAudioFormat,
        rate: Float,
        gender: SpeakerGender? = nil
    ) async -> [AVAudioPCMBuffer] {
        guard let voice = Self.pickVoice(locale: lang.speechLocale, gender: gender) else {
            return []
        }
        return await withCheckedContinuation { cont in
            var output: [AVAudioPCMBuffer] = []
            var converter: AVAudioConverter?
            var finished = false

            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            utterance.rate = rate

            synthesizer.write(utterance) { buffer in
                guard !finished else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    finished = true
                    cont.resume(returning: output)
                    return
                }
                if converter == nil {
                    converter = AVAudioConverter(from: pcm.format, to: format)
                }
                if let converted = Self.convert(pcm, with: converter, to: format) {
                    output.append(converted)
                }
            }
        }
    }

    /// 按语言和性别挑系统声音,优先高质量档
    private static func pickVoice(locale: String, gender: SpeakerGender?) -> AVSpeechSynthesisVoice? {
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.lowercased() == locale.lowercased()
        }
        var pool = candidates
        if let gender {
            let wanted: AVSpeechSynthesisVoiceGender = gender == .male ? .male : .female
            let matched = candidates.filter { $0.gender == wanted }
            if !matched.isEmpty { pool = matched }
        }
        let sorted = pool.sorted { $0.quality.rawValue > $1.quality.rawValue }
        return sorted.first ?? AVSpeechSynthesisVoice(language: locale)
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter?,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        var served = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if served {
                status.pointee = .noDataNow
                return nil
            }
            served = true
            status.pointee = .haveData
            return buffer
        }
        return (error == nil && out.frameLength > 0) ? out : nil
    }
}
