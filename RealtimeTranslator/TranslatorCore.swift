import SwiftUI
import Combine
import Translation
import AVFoundation

/// 整条流水线的调度中心,支持两套引擎:
///
/// 端上(v1,离线免费):
///   麦克风 -> VAD 断句 -> 双路 SFSpeech 识别判语种 -> Translation 框架翻译
///   -> AVSpeechSynthesizer 合成 -> 对应声道播放
///
/// 云端(v2,低延迟高质量):
///   麦克风 -> VAD 断句 -> 双路 Deepgram 流式识别判语种
///   -> Claude 流式翻译(带上下文) -> 按句切分 -> ElevenLabs 流式合成
///   -> 音频块边到边播,首句不等整段翻完
@MainActor
final class TranslatorCore: ObservableObject {
    enum PipelineState {
        case idle, listening, translating, playing
    }

    enum Engine: String, CaseIterable {
        case onDevice
        case cloud
    }

    @Published var running = false
    @Published var state: PipelineState = .idle
    @Published var partialText = ""
    @Published var entries: [TranscriptEntry] = []
    @Published var errorMessage: String?

    // 通用设置
    @Published var zhOnLeft = true          // 中文译文送到左耳(说中文的人戴左耳)
    @Published var speechRate: Float = 0.5  // 端上引擎的播报语速
    @Published var vadThreshold: Float = 0.015

    // 引擎选择与云端凭据(Key 存钥匙串)
    @Published var engine: Engine = Engine(rawValue: UserDefaults.standard.string(forKey: "engine") ?? "") ?? .onDevice {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: "engine") }
    }
    @Published var deepgramKey: String = KeychainStore.get("deepgramKey") {
        didSet { KeychainStore.set(deepgramKey, for: "deepgramKey") }
    }
    @Published var anthropicKey: String = KeychainStore.get("anthropicKey") {
        didSet { KeychainStore.set(anthropicKey, for: "anthropicKey") }
    }
    @Published var elevenKey: String = KeychainStore.get("elevenKey") {
        didSet { KeychainStore.set(elevenKey, for: "elevenKey") }
    }
    @Published var elevenVoiceId: String = UserDefaults.standard.string(forKey: "voiceId") ?? "21m00Tcm4TlvDq8ikWAM" {
        didSet { UserDefaults.standard.set(elevenVoiceId, forKey: "voiceId") }
    }

    // 端上翻译会话由 ContentView 的 translationTask 注入
    var zhToEn: TranslationSession?
    var enToZh: TranslationSession?

    private let audio = AudioManager()
    private let detector = UtteranceDetector()
    private let localRecognizer = DualRecognizer()
    private let localSynth = SpeechSynth()
    private let cloudASR = DualDeepgramASR()
    private let cloudTranslator = ClaudeTranslator()
    private let cloudTTS = ElevenLabsTTS()
    private var bag = Set<AnyCancellable>()

    init() {
        $vadThreshold
            .sink { [detector] value in detector.threshold = value }
            .store(in: &bag)
    }

    func toggle() {
        running ? stop() : start()
    }

    func start() {
        Task {
            let micOK = await AVAudioApplication.requestRecordPermission()
            guard micOK else {
                errorMessage = "需要麦克风权限,请到 设置 > 隐私与安全 中开启"
                return
            }
            if engine == .onDevice {
                let speechOK = await DualRecognizer.requestPermission()
                guard speechOK else {
                    errorMessage = "需要语音识别权限,请到 设置 > 隐私与安全 中开启"
                    return
                }
            } else {
                guard !deepgramKey.isEmpty, !anthropicKey.isEmpty, !elevenKey.isEmpty else {
                    errorMessage = "云端模式需要先在设置里填入 Deepgram / Anthropic / ElevenLabs 三个 API Key"
                    return
                }
            }
            do {
                try audio.configureSession()
                engine == .onDevice ? wireLocal() : wireCloud()
                try audio.start()
                running = true
                state = .listening
                errorMessage = nil
            } catch {
                errorMessage = "音频启动失败: \(error.localizedDescription)"
            }
        }
    }

    func stop() {
        audio.stop()
        localRecognizer.cancel()
        cloudASR.disconnect()
        cloudTranslator.reset()
        detector.reset()
        running = false
        state = .idle
        partialText = ""
    }

    /// 端上模式:触发系统翻译模型下载(首次使用需要)
    func downloadLanguages() {
        Task {
            do {
                try await zhToEn?.prepareTranslation()
                try await enToZh?.prepareTranslation()
                errorMessage = nil
            } catch {
                errorMessage = "语言包准备失败: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - 端上管线(v1)

    private func wireLocal() {
        localRecognizer.onPartial = { [weak self] text in
            Task { @MainActor in self?.partialText = text }
        }
        detector.threshold = vadThreshold
        detector.onStart = { [localRecognizer] in localRecognizer.begin() }
        detector.forward = { [localRecognizer] buffer in localRecognizer.append(buffer) }
        detector.onEnd = { [weak self] in
            Task { @MainActor in await self?.finishLocalUtterance() }
        }
        detector.reset()
        audio.onBuffer = { [detector] buffer in detector.feed(buffer) }
    }

    private func finishLocalUtterance() async {
        state = .translating
        defer {
            detector.resume()
            if running { state = .listening }
        }

        guard let (text, lang) = await localRecognizer.end() else {
            partialText = ""
            return
        }
        partialText = ""

        guard let session = (lang == .zh ? zhToEn : enToZh) else {
            errorMessage = "翻译引擎未就绪,请先点「下载语言包」"
            return
        }

        do {
            let response = try await session.translate(text)
            entries.append(TranscriptEntry(lang: lang, original: text, translation: response.targetText))
            errorMessage = nil

            state = .playing
            let targetLang = lang.opposite
            let buffers = await localSynth.render(
                response.targetText,
                lang: targetLang,
                to: audio.playbackFormat,
                rate: speechRate
            )
            let playOnLeft = (targetLang == .zh) ? zhOnLeft : !zhOnLeft
            await audio.play(buffers: buffers, onLeft: playOnLeft)
        } catch {
            errorMessage = "翻译失败: \(error.localizedDescription)"
        }
    }

    // MARK: - 云端管线(v2)

    private func wireCloud() {
        cloudASR.onPartial = { [weak self] text in
            Task { @MainActor in self?.partialText = text }
        }
        cloudASR.onError = { [weak self] message in
            Task { @MainActor in self?.errorMessage = message }
        }
        cloudASR.connect(apiKey: deepgramKey)

        detector.threshold = vadThreshold
        detector.onStart = { [cloudASR] in cloudASR.beginUtterance() }
        detector.forward = { [cloudASR] buffer in cloudASR.append(buffer) }
        detector.onEnd = { [weak self] in
            Task { @MainActor in await self?.finishCloudUtterance() }
        }
        detector.reset()
        audio.onBuffer = { [detector] buffer in detector.feed(buffer) }
    }

    private func finishCloudUtterance() async {
        state = .translating
        defer {
            detector.resume()
            if running { state = .listening }
        }

        guard let utterance = await cloudASR.endUtterance() else {
            partialText = ""
            return
        }
        partialText = ""

        let lang = utterance.lang
        let targetLang = lang.opposite
        let playOnLeft = (targetLang == .zh) ? zhOnLeft : !zhOnLeft
        var full = ""
        var chunk = ""

        do {
            // Claude 逐 token 返回;攒到句子边界就先送去合成,
            // 首句音频不等整段翻完,音频块到一块播一块
            for try await token in cloudTranslator.stream(text: utterance.text, from: lang, apiKey: anthropicKey) {
                full += token
                chunk += token
                while let sentence = Self.takeSentence(&chunk) {
                    state = .playing
                    await speakSentence(sentence, lang: targetLang, playOnLeft: playOnLeft)
                }
            }
            let rest = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty {
                state = .playing
                await speakSentence(rest, lang: targetLang, playOnLeft: playOnLeft)
            }

            let translation = full.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translation.isEmpty else { return }
            entries.append(TranscriptEntry(lang: lang, original: utterance.text, translation: translation))
            cloudTranslator.remember(source: utterance.text, target: translation, lang: lang)
            errorMessage = nil

            // 等这个声道队列里的音频全部播完再恢复聆听
            await audio.finishStream(onLeft: playOnLeft)
        } catch {
            errorMessage = "云端管线出错: \(error.localizedDescription)"
        }
    }

    /// 播一句译文:优先 ElevenLabs 云端音色,失败(如免费档限流)自动降级系统语音,保证对话不中断
    private func speakSentence(_ text: String, lang: Lang, playOnLeft: Bool) async {
        do {
            try await cloudTTS.stream(text: text, apiKey: elevenKey, voiceId: elevenVoiceId) { [audio] buffer in
                audio.scheduleStream(buffer, onLeft: playOnLeft)
            }
        } catch {
            let buffers = await localSynth.render(text, lang: lang, to: audio.playbackFormat, rate: speechRate)
            await audio.play(buffers: buffers, onLeft: playOnLeft)
        }
    }

    /// 从缓冲里切出一个完整句子;不够一句返回 nil
    private static func takeSentence(_ buffer: inout String) -> String? {
        let enders: Set<Character> = ["。", "!", "?", "!", "?", ".", ";", ";", "\n"]
        if let idx = buffer.lastIndex(where: { enders.contains($0) }) {
            let head = String(buffer[...idx]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[buffer.index(after: idx)...])
            return head.count >= 2 ? head : nil
        }
        if buffer.count > 90 {
            let head = buffer
            buffer = ""
            return head
        }
        return nil
    }
}
