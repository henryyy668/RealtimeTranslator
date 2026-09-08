import Foundation
import AVFoundation

/// ElevenLabs 流式合成:HTTP 分块返回原始 PCM(24k s16le 单声道),
/// 一边接收一边转成 Float32 缓冲交给播放器,首块音频到达即可开播。
final class ElevenLabsTTS {
    /// 与 AudioManager.playbackFormat 保持一致
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    /// 复用连接,省掉每句话的 TLS 握手
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    func stream(
        text: String,
        apiKey: String,
        voiceId: String,
        onChunk: @escaping (AVAudioPCMBuffer) -> Void
    ) async throws {
        var request = URLRequest(url: URL(string:
            "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)/stream?output_format=pcm_24000&optimize_streaming_latency=4")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "model_id": "eleven_flash_v2_5",
        ])

        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "ElevenLabsTTS", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "ElevenLabs 返回 \(http.statusCode),检查 Key、Voice ID 和额度"
            ])
        }

        // 每攒约 0.1 秒音频出一个缓冲,首声更快;跨块的奇数字节留到下一轮
        var raw = Data()
        raw.reserveCapacity(16_384)
        for try await byte in bytes {
            raw.append(byte)
            if raw.count >= 4_800 {
                emit(&raw, onChunk: onChunk)
            }
        }
        emit(&raw, onChunk: onChunk)
        raw.removeAll()
    }

    private func emit(_ raw: inout Data, onChunk: (AVAudioPCMBuffer) -> Void) {
        let usable = raw.count - raw.count % 2
        guard usable >= 2 else { return }
        if let buffer = Self.pcmBuffer(from: Data(raw.prefix(usable)), format: format) {
            onChunk(buffer)
        }
        raw.removeFirst(usable)
    }

    /// s16le 转 Float32,逐字节读避免对齐问题
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
                let sample = Int16(bitPattern: (hi << 8) | lo)
                dst[i] = Float(sample) / 32_768.0
            }
        }
        return buffer
    }
}
