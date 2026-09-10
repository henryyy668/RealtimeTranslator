import Foundation
import AVFoundation

/// ElevenLabs Scribe v2 Realtime 单路流式识别(全双工版)。
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

    private var ready = false
    private var pending: [(Data, Bool)] = []
    private let pendingLimit = 100
    private let queue = DispatchQueue(label: "scribe.send")

    private var waiters: [CommitWaiter] = []
    private var lastPartial = ""
    private var lastDelivered = ""

    private static let silenceChunk = Data(count: 3_200)

    func connect(apiKey: String, keyterms: [String]) {
        self.apiKey = apiKey
        self.keyterms = Array(keyterms.prefix(50))
        active = true
        fatal = false
        lastDelivered = ""
        open()

        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.active, self.socket != nil, self.ready else { return }
            if Date().timeIntervalSince(self.lastAudioSent) > 0.15 {
                self.send(audio: Self.silenceChunk, commit: false)
            }
        }
    }

    private func open() {
        ready = false
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
        ready = false
        queue.sync {
            pending.removeAll()
            let stale = waiters
            waiters.removeAll()
            stale.forEach { $0.resume(nil) }
        }
        lastPartial = ""
    }

    func beginUtterance() {
        lastPartial = ""
        if socket == nil, active, !fatal {
            open()
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let data = downsampler.convert(buffer) else { return }
        send(audio: data, commit: false)
    }

    func endUtterance() async -> Utterance? {
        guard socket != nil else { return nil }
        let partialSnapshot = lastPartial
        lastPartial = ""

        let committed: String? = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let waiter = CommitWaiter(cont)
            queue.sync { waiters.append(waiter) }
            send(audio: Self.silenceChunk, commit: true)
            DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) { [weak self] in
                self?.queue.sync { self?.waiters.removeAll { $0 === waiter } }
                waiter.resume(nil)
            }
        }

        let text = (committed ?? partialSnapshot).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard text != lastDelivered else { return nil }
        lastDelivered = text
        return Utterance(text: text, lang: Self.decideLang(text: text))
    }

    private static func decideLang(text: String) -> Lang {
        let han = text.unicodeScalars.filter { $0.properties.isIdeographic }.count
        let latin = text.unicodeScalars.filter { $0.isASCII && $0.properties.isAlphabetic }.count
        if han >= 2 || (han > 0 && latin == 0) { return .zh }
        if latin > 0 && han == 0 { return .en }
        return han > 0 ? .zh : .en
    }

    private func send(audio: Data, commit: Bool) {
        queue.sync {
            if !ready {
                if pending.count < pendingLimit {
                    pending.append((audio, commit))
                }
                return
            }
            sendNow(audio: audio, commit: commit)
        }
    }

    private func sendNow(audio: Data, commit: Bool) {
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

    private func flushPending() {
        queue.sync {
            ready = true
            let items = pending
            pending.removeAll()
            for (audio, commit) in items {
                sendNow(audio: audio, commit: commit)
            }
        }
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
        ready = false
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
        case "session_started":
            flushPending()
        case "warning", "committed_transcript_entities", "committed_transcript_with_timestamps":
            break
        case "partial_transcript":
            let text = ((obj["text"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                lastPartial = text
                onPartial?(text)
            }
        case "committed_transcript":
            let text = (obj["text"] as? String) ?? ""
            let waiter: CommitWaiter? = queue.sync {
                waiters.isEmpty ? nil : waiters.removeFirst()
            }
            waiter?.resume(text)
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

private final class CommitWaiter {
    private var resumed = false
    private let lock = NSLock()
    private let continuation: CheckedContinuation<String?, Never>

    init(_ continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    func resume(_ text: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: text)
    }
}
