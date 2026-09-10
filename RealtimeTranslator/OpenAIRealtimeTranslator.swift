import Foundation
import AVFoundation

/// OpenAI gpt-realtime-translate 端到端语音翻译引擎(边听边译)。
///
/// 一路麦克风音频同时喂给两个翻译会话:一个输出英文,一个输出中文。
/// 模型自己判断源语言并边听边译。哪一路的源语言和目标语言相同,那一路的输出丢掉,
/// 依据是源语言字幕(input_transcript)的文字系统和 elapsed_ms 时间对齐。
final class OpenAIRealtimeTranslator {
    var onSourceText: ((String) -> Void)?
    var onTargetText: ((String, Lang) -> Void)?
    var onTargetAudio: ((AVAudioPCMBuffer, Lang) -> Void)?
    var onError: ((String) -> Void)?

    private var sessions: [Lang: TranslationSocket] = [:]
    private let timeline = LanguageTimeline()
    private var converter: AVAudioConverter?
    private var accumulator = Data()
    private let chunkBytes = 9_600
    private var muted = false

    private let wireFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    func connect(apiKey: String) {
        disconnect()
        timeline.reset()
        for target in [Lang.en, Lang.zh] {
            let socket = TranslationSocket(target: target, apiKey: apiKey, transcribe: target == .en, timeline: timeline)
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

private final class LanguageTimeline {
    private var entries: [(ms: Int, lang: Lang)] = []
    private let lock = NSLock()

    func reset() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
    }

    func record(ms: Int, text: String) {
        let han = text.unicodeScalars.contains { $0.properties.isIdeographic }
        let latin = text.unicodeScalars.contains { $0.isASCII && $0.properties.isAlphabetic }
        let lang: Lang
        if han { lang = .zh } else if latin { lang = .en } else { return }
        lock.lock(); defer { lock.unlock() }
        if let last = entries.last, last.ms == ms {
            entries[entries.count - 1] = (ms, lang)
        } else {
            entries.append((ms, lang))
        }
        if entries.count > 400 {
            entries.removeFirst(entries.count - 400)
        }
    }

    func language(at ms: Int?) -> Lang? {
        lock.lock(); defer { lock.unlock() }
        guard let ms else { return entries.last?.lang }
        return entries.last(where: { $0.ms <= ms + 600 })?.lang ?? entries.first?.lang
    }
}

private final class TranslationSocket {
    let target: Lang
    private let apiKey: String
    private let transcribe: Bool
    private let timeline: LanguageTimeline
    private var socket: URLSessionWebSocketTask?
    private var closing = false

    var onSourceText: ((String) -> Void)?
    var onTargetText: ((String) -> Void)?
    var onTargetAudio: ((Data) -> Void)?
    var onError: ((String) -> Void)?

    init(target: Lang, apiKey: String, transcribe: Bool, timeline: LanguageTimeline) {
        self.target = target
        self.apiKey = apiKey
        self.transcribe = transcribe
        self.timeline = timeline
    }

    func open() {
        closing = false
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()
        receive(task)

        var input: [String: Any] = ["noise_reduction": ["type": "far_field"]]
        if transcribe {
            input["transcription"] = ["model": "gpt-realtime-whisper"]
        }
        send([
            "type": "session.update",
            "session": [
                "audio": [
                    "input": input,
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

    private func handle(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        let elapsed = obj["elapsed_ms"] as? Int

        switch type {
        case "session.input_transcript.delta":
            let delta = (obj["delta"] as? String) ?? ""
            timeline.record(ms: elapsed ?? 0, text: delta)
            onSourceText?(delta)
        case "session.output_audio.delta":
            if timeline.language(at: elapsed) == target { return }
            if let b64 = obj["delta"] as? String, let audio = Data(base64Encoded: b64) {
                onTargetAudio?(audio)
            }
        case "session.output_transcript.delta":
            if timeline.language(at: elapsed) == target { return }
            onTargetText?((obj["delta"] as? String) ?? "")
        case "error":
            let err = obj["error"] as? [String: Any]
            onError?("OpenAI 翻译出错: \((err?["message"] as? String) ?? type)")
        default:
            break
        }
    }
}
