import Foundation

/// Claude 流式翻译:SSE 逐 token 返回,并维护滚动对话上下文,
/// 保证人名、地名、专有名词在整段对话中前后一致。
final class ClaudeTranslator {
    private struct Exchange {
        let source: String
        let target: String
        let lang: Lang
    }

    private var history: [Exchange] = []

    /// 一句翻完后登记进上下文,只保留最近 10 轮
    func remember(source: String, target: String, lang: Lang) {
        history.append(Exchange(source: source, target: target, lang: lang))
        if history.count > 10 {
            history.removeFirst(history.count - 10)
        }
    }

    func reset() {
        history.removeAll()
    }

    /// 流式翻译,逐 token 产出
    func stream(text: String, from lang: Lang, apiKey: String) -> AsyncThrowingStream<String, Error> {
        let request = makeRequest(text: text, from: lang, apiKey: apiKey)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        throw NSError(domain: "ClaudeTranslator", code: http.statusCode, userInfo: [
                            NSLocalizedDescriptionKey: "Claude API 返回 \(http.statusCode),检查 Key 和额度"
                        ])
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = obj["type"] as? String else { continue }
                        if type == "content_block_delta",
                           let delta = obj["delta"] as? [String: Any],
                           let token = delta["text"] as? String {
                            continuation.yield(token)
                        } else if type == "message_stop" {
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeRequest(text: String, from lang: Lang, apiKey: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var context = ""
        if !history.isEmpty {
            let lines = history.map { exchange -> String in
                exchange.lang == .zh
                    ? "中: \(exchange.source)\nEN: \(exchange.target)"
                    : "EN: \(exchange.source)\n中: \(exchange.target)"
            }
            context = "对话上下文(仅供术语和人名保持一致,不要翻译这部分):\n"
                + lines.joined(separator: "\n") + "\n\n"
        }
        let direction = lang == .zh ? "把下面这句中文翻成英文" : "把下面这句英文翻成中文"
        let prompt = context + direction + ",这是面对面口语对话,译文要自然口语化,只输出译文本身:\n\(text)"

        let body: [String: Any] = [
            "model": "claude-haiku-4-5",
            "max_tokens": 1024,
            "stream": true,
            "system": "你是专业同声传译。只输出译文,不解释,不加引号,不加任何前后缀。人名、地名、专有名词与对话上下文保持一致。",
            "messages": [["role": "user", "content": prompt]],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }
}
