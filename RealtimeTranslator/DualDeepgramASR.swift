import Foundation
import AVFoundation

/// 双路 Deepgram 流式识别。
///
/// nova-3 的 multi 混合模式目前不含中文,所以照搬 v1 验证过的双路思路:
/// 中文和英文各开一条 websocket,同一段音频同时上送,
/// 句尾发 Finalize 强制出终稿,比较两路整体置信度自动判定语种。
/// 专语言模型的准确率也比混合模式更高。
final class DualDeepgramASR {
    struct Utterance {
        let text: String
        let lang: Lang
    }

    var onPartial: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private final class Leg {
        let lang: Lang
        var socket: URLSessionWebSocketTask?
        var pending = ""
        var confidenceSum: Double = 0
        var confidenceCount = 0
        var finalized = false

        init(lang: Lang) { self.lang = lang }

        var confidence: Double {
            confidenceCount == 0 ? 0 : confidenceSum / Double(confidenceCount)
        }

        func resetUtterance() {
            pending = ""
            confidenceSum = 0
            confidenceCount = 0
            finalized = false
        }
    }

    private let zhLeg = Leg(lang: .zh)
    private let enLeg = Leg(lang: .en)
    private var keepAlive: Timer?
    private let downsampler = MicDownsampler()
    private var apiKey = ""
    private var closing = false

    func connect(apiKey: String) {
        self.apiKey = apiKey
        closing = false
        open(leg: zhLeg, language: "zh-CN", apiKey: apiKey)
        open(leg: enLeg, language: "en-US", apiKey: apiKey)
        // 只在说话时上送音频,静默期靠 KeepAlive 维持连接不被服务端关闭
        keepAlive = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            let ping = URLSessionWebSocketTask.Message.string(#"{"type":"KeepAlive"}"#)
            self?.zhLeg.socket?.send(ping) { _ in }
            self?.enLeg.socket?.send(ping) { _ in }
        }
    }

    private func open(leg: Leg, language: String, apiKey: String) {
        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        components.queryItems = [
            .init(name: "model", value: "nova-3"),
            .init(name: "language", value: language),
            .init(name: "encoding", value: "linear16"),
            .init(name: "sample_rate", value: "16000"),
            .init(name: "channels", value: "1"),
            .init(name: "interim_results", value: "true"),
            .init(name: "smart_format", value: "true"),
            .init(name: "punctuate", value: "true"),
            .init(name: "endpointing", value: "false"), // 断句由 App 端 VAD 决定
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        leg.socket = task
        task.resume()
        receiveLoop(leg)
    }

    func disconnect() {
        closing = true
        keepAlive?.invalidate()
        keepAlive = nil
        zhLeg.socket?.cancel(with: .goingAway, reason: nil)
        enLeg.socket?.cancel(with: .goingAway, reason: nil)
        zhLeg.socket = nil
        enLeg.socket = nil
        zhLeg.resetUtterance()
        enLeg.resetUtterance()
    }

    /// 一句话开始(VAD 触发,音频线程调用)
    func beginUtterance() {
        zhLeg.resetUtterance()
        enLeg.resetUtterance()
    }

    /// 音频线程:降采样到 16k s16le 后同时上送两条腿
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let data = downsampler.convert(buffer) else { return }
        zhLeg.socket?.send(.data(data)) { _ in }
        enLeg.socket?.send(.data(data)) { _ in }
    }

    /// 句尾:Finalize 两条腿,等终稿(最多 2 秒)后比较置信度定语种
    func endUtterance() async -> Utterance? {
        let finalize = URLSessionWebSocketTask.Message.string(#"{"type":"Finalize"}"#)
        zhLeg.socket?.send(finalize) { _ in }
        enLeg.socket?.send(finalize) { _ in }

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, !(zhLeg.finalized && enLeg.finalized) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        let zhText = zhLeg.pending.trimmingCharacters(in: .whitespacesAndNewlines)
        let enText = enLeg.pending.trimmingCharacters(in: .whitespacesAndNewlines)
        let zhConfidence = zhLeg.confidence
        let enConfidence = enLeg.confidence
        zhLeg.resetUtterance()
        enLeg.resetUtterance()

        if zhText.isEmpty && enText.isEmpty { return nil }
        if zhText.isEmpty { return Utterance(text: enText, lang: .en) }
        if enText.isEmpty { return Utterance(text: zhText, lang: .zh) }

        // 先看置信度差距,再用汉字占比兜底
        if zhConfidence > enConfidence + 0.08 { return Utterance(text: zhText, lang: .zh) }
        if enConfidence > zhConfidence + 0.08 { return Utterance(text: enText, lang: .en) }
        let hanCount = zhText.unicodeScalars.filter { $0.properties.isIdeographic }.count
        let hanRatio = Double(hanCount) / Double(max(zhText.count, 1))
        return hanRatio > 0.4
            ? Utterance(text: zhText, lang: .zh)
            : Utterance(text: enText, lang: .en)
    }

    private func receiveLoop(_ leg: Leg) {
        leg.socket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                // 网络切换(如 Wi-Fi/5G/LTE 互切)会掐断长连接,这里自动重连,不打扰用户
                guard !self.closing else { return }
                leg.socket = nil
                leg.resetUtterance()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self, !self.closing else { return }
                    self.open(leg: leg,
                              language: leg.lang == .zh ? "zh-CN" : "en-US",
                              apiKey: self.apiKey)
                }
            case .success(let message):
                if case .string(let text) = message {
                    self.handle(text, leg: leg)
                }
                self.receiveLoop(leg)
            }
        }
    }

    private func handle(_ raw: String, leg: Leg) {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "Results",
              let channel = obj["channel"] as? [String: Any],
              let alternatives = channel["alternatives"] as? [[String: Any]],
              let first = alternatives.first else { return }

        let transcript = ((first["transcript"] as? String) ?? "")
            .trimmingCharacters(in: .whitespaces)
        let isFinal = obj["is_final"] as? Bool ?? false
        let fromFinalize = obj["from_finalize"] as? Bool ?? false

        if isFinal {
            if !transcript.isEmpty {
                leg.pending += leg.pending.isEmpty ? transcript : " " + transcript
                if let confidence = first["confidence"] as? Double {
                    leg.confidenceSum += confidence
                    leg.confidenceCount += 1
                }
            }
            if fromFinalize {
                leg.finalized = true
            }
        } else if !transcript.isEmpty {
            // 两路的中间结果都往界面推,后到者覆盖,只为显示"正在听懂"
            onPartial?(leg.pending.isEmpty ? transcript : leg.pending + " " + transcript)
        }
    }
}

/// 麦克风缓冲降采样到 Deepgram 需要的 16k 单声道 s16le
final class MicDownsampler {
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        if converter == nil {
            converter = AVAudioConverter(from: buffer.format, to: outFormat)
        }
        guard let converter else { return nil }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
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
        guard error == nil, out.frameLength > 0, let channel = out.int16ChannelData else {
            return nil
        }
        return Data(bytes: channel[0], count: Int(out.frameLength) * 2)
    }
}
