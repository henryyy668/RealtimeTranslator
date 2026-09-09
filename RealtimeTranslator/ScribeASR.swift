import Foundation
import AVFoundation

/// ElevenLabs Scribe v2 Realtime 单路流式识别。
///
/// 和双路 Deepgram 的区别:一条连接同时听中英文,模型自带语种识别,
/// 不再靠两路置信度猜。音频全程持续上送(静默期送静音帧保持会话),
/// 句尾由 App 的 VAD 决定,发 commit 拿本句终稿;弱网下终稿超时就用最后一条中间结果顶上。
final class ScribeASR {
    struct Utterance {
        let text: String
        let lang: Lang
    }

    var onPartial: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private var socket: URLSessionWebSocketTask?
    private var apiKey = ""
    private var keyterms: [String] = []
    private var active = false
    private var fatal = false
    private let downsampler = MicDownsampler()
    private var idleTimer: Timer?
    private var lastAudioSent = Date.distantPast

    private var awaitingCommit = false
    private var committedText: String?
    private var committedLang: String?
    private var lastPartial = ""

    /// 100 毫秒 16k s16le 静音
    private static let silenceChunk = Data(count: 3_200)

    /// keyterms:常被听错的词,最多 50 个,每个 20 字符以内(ElevenLabs 对此加收 20% 费用)
    func connect(apiKey: String, keyterms: [String]) {
        self.apiKey = apiKey
        self.keyterms = Array(keyterms.prefix(50))
        active = true
        fatal = false
        open()

        // 静默期每 100 毫秒补一帧静音,保持会话连续,也让模型有足够上下文
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.active, self.socket != nil else { return }
            if Date().timeIntervalSince(self.lastAudioSent) > 0.15 {
                self.send(audio: Self.silenceChunk, commit: false)
            }
        }
    }

    private func open() {
        var components = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        var items: [URLQueryItem] = [
            .init(name: "model_id", value: "scribe_v2_realtime"),
            .init(name: "audio_format", value: "pcm_16000"),
            .init(name: "commit_strategy", value: "manual"),
            .init(name: "include_language_detection", value: "true"),
            .init(name: "secondary_languages", value: "zho"),
            .init(name: "secondary_languages", value: "eng"),
        ]
        for term in keyterms {
            items.append(.init(name: "keyterms", value: term))
        }
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()
        receiveLoop(task)
    }

    func disconnect() {
        active = false
        idleTimer?.invalidate()
        idleTimer = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        awaitingCommit = false
        committedText = nil
        committedLang = nil
        lastPartial = ""
    }

    /// 一句话开始(VAD 触发,音频线程调用)
    func beginUtterance() {
        committedText = nil
        committedLang = nil
        lastPartial = ""
    }

    /// 音频线程:降采样到 16k s16le 后上送
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let data = downsampler.convert(buffer) else { return }
        send(audio: data, commit: false)
    }

    /// 句尾:发 commit,等本句终稿(最多 5 秒,弱网留余量),语种信息稍后到再等 0.4 秒。
    /// 终稿等不到就用最后一条中间结果,不丢句。
    func endUtterance() async -> Utterance? {
        guard socket != nil else { return nil }
        committedText = nil
        committedLang = nil
        awaitingCommit = true
        send(audio: Self.silenceChunk, commit: true)

        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline, committedText == nil {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let langDeadline = Date().addingTimeInterval(0.4)
        while Date() < langDeadline, committedText != nil, committedLang == nil {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        awaitingCommit = false

        let text = (committedText ?? lastPartial).trimmingCharacters(in: .whitespacesAndNewlines)
        let code = committedLang
        committedText = nil
        committedLang = nil
        lastPartial = ""
        guard !text.isEmpty else { return nil }
        return Utterance(text: text, lang: Self.decideLang(text: text, code: code))
    }

    /// 先看文字本身的文字系统(最可靠),再看模型报的语种码
    private static func decideLang(text: String, code: String?) -> Lang {
        let han = text.unicodeScalars.filter { $0.properties.isIdeographic }.count
        let latin = text.unicodeScalars.filter { $0.isASCII && $0.properties.isAlphabetic }.count
        if han >= 2 || (han > 0 && latin == 0) { return .zh }
        if latin > 0 && han == 0 { return .en }
        if let code = code?.lowercased() {
            if code.hasPrefix("zh") || code.hasPrefix("cmn") || code.hasPrefix("yue") { return .zh }
            if code.hasPrefix("en") { return .en }
        }
        return han > 0 ? .zh : .en
    }

    private func send(audio: Data, commit: Bool) {
        guard let socket else { return }
        var message: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": audio.base64EncodedString(),
        ]
        if commit {
            message["commit"] = true
        }
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        lastAudioSent = Date()
        socket.send(.string(text)) { _ in }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self, self.socket === task else { return }
            switch result {
            case .failure(let error):
                if self.active && !self.fatal {
                    self.onError?("Scribe 连接断开: \(error.localizedDescription),1 秒后自动重连")
                }
                self.scheduleReconnect()
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handle(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { self.handle(text) }
                @unknown default:
                    break
                }
                self.receiveLoop(task)
            }
        }
    }

    private func scheduleReconnect() {
        socket = nil
        guard active, !fatal else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.active, !self.fatal, self.socket == nil else { return }
            self.open()
        }
    }

    private func handle(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["message_type"] as? String else { return }

        switch type {
        case "session_started", "warning", "committed_transcript_entities":
            break
        case "partial_transcript":
            let text = ((obj["text"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                lastPartial = text
                onPartial?(text)
            }
        case "committed_transcript":
            if awaitingCommit {
                committedText = (obj["text"] as? String) ?? ""
            }
        case "committed_transcript_with_timestamps":
            if awaitingCommit {
                committedLang = obj["language_code"] as? String
                if committedText == nil {
                    committedText = (obj["text"] as? String) ?? ""
                }
            }
        case "auth_error":
            fatal = true
            onError?("Scribe 鉴权失败:ElevenLabs Key 无效,或该 Key 没有 Speech to Text 权限")
        case "unaccepted_terms":
            fatal = true
            onError?("需要先在 ElevenLabs 网站的 Speech to Text 页面接受 Scribe 服务条款")
        case "quota_exceeded":
            fatal = true
            onError?("ElevenLabs 额度用完,请升级套餐或等下月重置")
        case "invalid_request":
            fatal = true
            onError?("Scribe 连接参数被拒绝: \((obj["error"] as? String) ?? "")")
        default:
            let detail = (obj["error"] as? String) ?? ""
            onError?("Scribe 识别出错(\(type)): \(detail)")
        }
    }
}
