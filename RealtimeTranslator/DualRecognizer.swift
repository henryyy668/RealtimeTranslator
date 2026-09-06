import Speech
import AVFoundation

/// 双路流式识别:同一段音频同时喂给中文和英文两个识别器,
/// 一句话结束后比较两路结果,自动判断说话人用的是哪种语言。
/// 这样两人自然对话,不需要按键切换说话方向。
final class DualRecognizer {
    private let zhRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let enRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    private final class Slot {
        var request: SFSpeechAudioBufferRecognitionRequest?
        var task: SFSpeechRecognitionTask?
        var text = ""
        var confidence: Double = 0
        var isFinal = false
    }

    private var zhSlot = Slot()
    private var enSlot = Slot()

    /// 中文路的中间识别结果,用于界面实时显示
    var onPartial: ((String) -> Void)?

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    /// 开始一句话的识别(可从音频线程调用)
    func begin() {
        zhSlot = Self.startTask(recognizer: zhRecognizer, onPartial: onPartial)
        enSlot = Self.startTask(recognizer: enRecognizer, onPartial: nil)
    }

    private static func startTask(
        recognizer: SFSpeechRecognizer?,
        onPartial: ((String) -> Void)?
    ) -> Slot {
        let slot = Slot()
        guard let recognizer, recognizer.isAvailable else { return slot }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        slot.request = request
        slot.task = recognizer.recognitionTask(with: request) { result, _ in
            guard let result else { return }
            let transcription = result.bestTranscription
            slot.text = transcription.formattedString
            let scored = transcription.segments.filter { $0.confidence > 0 }
            if !scored.isEmpty {
                slot.confidence = scored.map { Double($0.confidence) }.reduce(0, +) / Double(scored.count)
            }
            if result.isFinal {
                slot.isFinal = true
            }
            onPartial?(transcription.formattedString)
        }
        return slot
    }

    /// 追加音频缓冲(音频线程调用)
    func append(_ buffer: AVAudioPCMBuffer) {
        zhSlot.request?.append(buffer)
        enSlot.request?.append(buffer)
    }

    /// 结束本句:等待两路 final 结果(最多 1.5 秒),返回 (文本, 语言)
    func end() async -> (String, Lang)? {
        zhSlot.request?.endAudio()
        enSlot.request?.endAudio()

        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline, !(zhSlot.isFinal && enSlot.isFinal) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        zhSlot.task?.cancel()
        enSlot.task?.cancel()

        let zhText = zhSlot.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let enText = enSlot.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let zhConfidence = zhSlot.confidence
        let enConfidence = enSlot.confidence
        zhSlot = Slot()
        enSlot = Slot()

        if zhText.isEmpty && enText.isEmpty { return nil }
        if zhText.isEmpty { return (enText, .en) }
        if enText.isEmpty { return (zhText, .zh) }

        // 两路都有结果:先看置信度差距,再用文字特征兜底
        if zhConfidence > enConfidence + 0.12 { return (zhText, .zh) }
        if enConfidence > zhConfidence + 0.12 { return (enText, .en) }
        let hanCount = zhText.unicodeScalars.filter { $0.properties.isIdeographic }.count
        let hanRatio = Double(hanCount) / Double(max(zhText.count, 1))
        return hanRatio > 0.5 ? (zhText, .zh) : (enText, .en)
    }

    func cancel() {
        zhSlot.task?.cancel()
        enSlot.task?.cancel()
        zhSlot = Slot()
        enSlot = Slot()
    }
}
