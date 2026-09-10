import Foundation
import AVFoundation

/// OpenAI gpt-realtime-translate 端到端语音翻译引擎(边听边译)。
///
/// 一路麦克风音频同时喂给两个翻译会话:一个输出英文,一个输出中文。
/// 源语言字幕比翻译输出来得晚,所以每一路的输出先扣住一小段时间,
/// 等字幕告诉我们"现在说的是哪种语言"之后再决定:源语言和本路目标语言相同就丢掉。
final class OpenAIRealtimeTranslator {
    var onSourceText: ((String) -> Void)?
    var onTargetText: ((String, Lang) -> Void)?
    var onTargetAudio: ((AVAudioPCMBuffer, Lang) -> Void)?
    var onError: ((String) -> Void)?

    private var sessions: [Lang: TranslationSocket] = [:]
    private let speaker = SpeakerLanguage()
    private var converter: AVAudioConverter?
    private var accumulator = Data()
    private let chunkBytes = 9_600
    private var muted = false

    private let wireFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    func connect(apiKey: String) {
        disconnect()
        speaker.reset()
        for target in [Lang.en, Lang.zh] {
            // 两个会话都开源语言字幕,谁先到用谁,判断更快
            let socket = TranslationSocket(target: target, apiKey: apiKey, speaker: speaker)
            socket.onSourceText = { [weak self] text in self?.onSourceText?(text) }
            socket.onTargetText = { [weak self] text in self?.onTargetText?(text, target) }
            socket.onTargetAudio = { [weak self] data in
                guard let self, let buffer = Self.pcmBuffer(from: data, format: self.playbackFormat) else { return }
                self.onTargetAudio?(buffer, target)
            }
            socket.onError = { [weak self] message in self?.onError?(message) }
            socket.open()
            sessions[target] = socket
        }
    }

    func disconnect() {
        sessions.values.forEach { $0.close() }
        sessions.removeAll()
        accumulator.removeAll()
        converter = nil
    }

    func setMuted(_ value: Bool) {
        muted = value
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: wireFormat)
        }
        guard let converter else { return }
        let ratio = wireFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: capacity) else { return }
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
        guard error == nil, out.frameLength > 0, let channel = out.int16ChannelData else { return }
        let bytes = Int(out.frameLength) * 2
        if muted {
            accumulator.append(Data(count: bytes))
        } else {
            accumulator.append(Data(bytes: channel[0], count: bytes))
        }
        while accumulator.count >= chunkBytes {
            let chunk = accumulator.prefix(chunkBytes)
            accumulator.removeFirst(chunkBytes)
            let encoded = chunk.base64EncodedString()
            sessions.values.forEach { $0.appendAudio(encoded) }
        }
    }

    private static func pcmBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = data.count / 2
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            let dst = buffer.floatChannelData![0]
            for i in 0..<frames {
                let lo = UInt16(ptr[2 * i])
                let hi = UInt16(ptr[2 * i + 1])
                dst[i] = Float(Int16(bitPattern: (hi << 8) | lo)) / 32_768.0
            }
        }
        return buffer
    }
}

/// 当前说话人正在说的语言,由源语言字幕的文字系统推断,带最近更新时间
private final class SpeakerLanguage {
    private var current: Lang?
    private var updatedAt = Date.distantPast
    private let lock = NSLock()

    func reset() {
        lock.lock(); defer { lock.unlock() }
        current = nil
        updatedAt = .distantPast
    }

    func observe(_ text: String) {
        let han = text.unicodeScalars.contains { $0.properties.isIdeographic }
        let latin = text.unicodeScalars.contains { $0.isASCII && $0.properties.isAlphabetic }
        let lang: Lang
        if han { lang = .zh } else if latin { lang = .en } else { return }
        lock.lock(); defer { lock.unlock() }
        current = lang
        updatedAt = Date()
    }

    /// 最近 6 秒内听到的语言;更久没字幕就当不知道(放行)
    func recent() -> Lang? {
        lock.lock(); defer { lock.unlock() }
        guard Date().timeIntervalSince(updatedAt) < 6 else { return nil }
        return current
    }
}

/// 一个翻译会话:固定一个目标语言,输出先扣住 holdSeconds 再决定放不放
private final class TranslationSocket {
    let target: Lang
    private let apiKey: String
    private let speaker: SpeakerLanguage
    private var socket: URLSessionWebSocketTask?
    private var closing = false
    private let queue = DispatchQueue(label: "openai.translate.hold")
    private let holdSeconds: TimeInterval = 0.7

    var onSourceText: ((String) -> Void)?
    var onTargetText: ((String) -> Void)?
    var onTargetAudio: ((Data) -> Void)?
    var onError: ((String) -> Void)?

    init(target: Lang, apiKey: String, speaker: SpeakerLanguage) {
        self.target = target
        self.apiKey = apiKey
        self.speaker = speaker
    }

    func open() {
        closing = false
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()
        receive(task)

        send([
            "type": "session.update",
            "session": [
                "audio": [
                    "input": [
                        "noise_reduction": ["type": "far_field"],
                        "transcription": ["model": "gpt-realtime-whisper"],
                    ],
                    "output": ["language": target == .en ? "en" : "zh"],
                ],
            ],
        ])
    }

    func appendAudio(_ base64: String) {
        send(["type": "session.input_audio_buffer.append", "audio": base64])
    }

    func close() {
        closing = true
        send(["type": "session.close"])
        let task = socket
        socket = nil
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            task?.cancel(with: .normalClosure, reason: nil)
        }
    }

    private func send(_ object: [String: Any]) {
        guard let socket,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self, self.socket === task else { return }
            switch result {
            case .failure(let error):
                guard !self.closing else { return }
                self.onError?("OpenAI 翻译连接断开(\(self.target == .en ? "英文" : "中文")路): \(error.localizedDescription),2 秒后重连")
                self.socket = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, !self.closing, self.socket == nil else { return }
                    self.open()
                }
            case .success(let message):
                if case .string(let text) = message {
                    self.handle(text)
                } else if case .data(let data) = message, let text = String(data: data, encoding: .utf8) {
                    self.handle(text)
                }
                self.receive(task)
            }
        }
    }

    /// 扣住一小段时间再判断:源语言 == 本路目标语言 -> 丢;不知道 -> 放
    private func hold(_ deliver: @escaping () -> Void) {
        queue.asyncAfter(deadline: .now() + holdSeconds) { [weak self] in
            guard let self, !self.closing else { return }
            if self.speaker.recent() == self.target { return }
            deliver()
        }
    }

    private func handle(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "session.input_transcript.delta":
            let delta = (obj["delta"] as? String) ?? ""
            speaker.observe(delta)
            // 只用英文路的字幕更新界面,避免两路重复显示
            if target == .en { onSourceText?(delta) }
        case "session.output_audio.delta":
            guard let b64 = obj["delta"] as? String, let audio = Data(base64Encoded: b64) else { return }
            hold { [weak self] in self?.onTargetAudio?(audio) }
        case "session.output_transcript.delta":
            let delta = (obj["delta"] as? String) ?? ""
            hold { [weak self] in self?.onTargetText?(delta) }
        case "error":
            let err = obj["error"] as? [String: Any]
            onError?("OpenAI 翻译出错: \((err?["message"] as? String) ?? type)")
        default:
            break
        }
    }
}
