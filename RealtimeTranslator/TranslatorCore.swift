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
///   麦克风 -> VAD 断句(顺带判说话人性别)
///   -> 流式识别(Scribe v2 单路自动判语种,或双路 Deepgram)
///   -> Claude 流式翻译(带上下文) -> 按句切分 -> ElevenLabs 流式合成(性别匹配)
///   -> 音频块边到边播;翻译与合成并行,首句按逗号就开播
///
/// 每一段失败都会在界面上给出可读的原因,方便现场定位。
@MainActor
final class TranslatorCore: ObservableObject {
    enum PipelineState {
        case idle, listening, translating, playing
    }

    enum Engine: String, CaseIterable {
        case onDevice
        case cloud
    }

    enum ASRProvider: String, CaseIterable {
        case scribe
        case deepgram
    }

    enum VoiceMode: String, CaseIterable {
        case auto
        case male
        case female
    }

    @Published var running = false
    @Published var state: PipelineState = .idle
    @Published var partialText = ""
    @Published var entries: [TranscriptEntry] = []
    @Published var errorMessage: String?
    @Published var outputName = ""

    @Published var zhOnLeft = true
    @Published var speechRate: Float = 0.5
    @Published var vadThreshold: Float = 0.015

    @Published var engine: Engine = Engine(rawValue: UserDefaults.standard.string(forKey: "engine") ?? "") ?? .onDevice {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: "engine") }
    }
    @Published var asrProvider: ASRProvider = ASRProvider(rawValue: UserDefaults.standard.string(forKey: "asrProvider") ?? "") ?? .scribe {
        didSet { UserDefaults.standard.set(asrProvider.rawValue, forKey: "asrProvider") }
    }
    @Published var scribeKeyterms: String = UserDefaults.standard.string(forKey: "scribeKeyterms") ?? "" {
        didSet { UserDefaults.standard.set(scribeKeyterms, forKey: "scribeKeyterms") }
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
    @Published var elevenVoiceMaleId: String = UserDefaults.standard.string(forKey: "voiceMaleId") ?? "pNInz6obpgDQGcFmaJgB" {
        didSet { UserDefaults.standard.set(elevenVoiceMaleId, forKey: "voiceMaleId") }
    }
    @Published var voiceMode: VoiceMode = VoiceMode(rawValue: UserDefaults.standard.string(forKey: "voiceMode") ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(voiceMode.rawValue, forKey: "voiceMode") }
    }

    var zhToEn: TranslationSession?
    var enToZh: TranslationSession?

    private let audio = AudioManager()
    private let detector = UtteranceDetector()
    private let localRecognizer = DualRecognizer()
    private let localSynth = SpeechSynth()
    private let deepgramASR = DualDeepgramASR()
    private let scribeASR = ScribeASR()
    private let cloudTranslator = ClaudeTranslator()
    private let cloudTTS = ElevenLabsTTS()
    private var bag = Set<AnyCancellable>()
    private var lastGender: [Lang: SpeakerGender] = [:]

    init() {
        $vadThreshold
            .sink { [detector] value in detector.threshold = value }
            .store(in: &bag)
        audio.onRouteChange = { [weak self] name in
            Task { @MainActor in self?.outputName = name }
        }
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
                guard !anthropicKey.isEmpty, !elevenKey.isEmpty else {
                    errorMessage = "云端模式需要先在设置里填入 Anthropic 和 ElevenLabs 的 API Key"
                    return
                }
                if asrProvider == .deepgram && deepgramKey.isEmpty {
                    errorMessage = "选择 Deepgram 识别需要填入 Deepgram API Key,或切换到 Scribe"
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
        deepgramASR.disconnect()
        scribeASR.disconnect()
        cloudTranslator.reset()
        detector.reset()
        running = false
        state = .idle
        partialText = ""
    }

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

    private func resolveGender(detected: SpeakerGender?, lang: Lang) -> SpeakerGender {
        switch voiceMode {
        case .male:
            return .male
        case .female:
            return .female
        case .auto:
            if let detected {
                lastGender[lang] = detected
                return detected
            }
            return lastGender[lang] ?? .male
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

        let detected = detector.takeGender()

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
            let gender = resolveGender(detected: detected, lang: lang)
            let buffers = await localSynth.render(
                response.targetText,
                lang: targetLang,
                to: audio.playbackFormat,
                rate: speechRate,
                gender: gender
            )
            let playOnLeft = (targetLang == .zh) ? zhOnLeft : !zhOnLeft
            await audio.play(buffers: buffers, onLeft: playOnLeft)
        } catch {
            errorMessage = "翻译失败: \(error.localizedDescription)"
        }
    }

    // MARK: - 云端管线(v2)

    private var keytermList: [String] {
        scribeKeyterms
            .split(whereSeparator: { $0 == "," || $0 == "," || $0 == "\n" || $0 == "、" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func wireCloud() {
        let partialHandler: (String) -> Void = { [weak self] text in
            Task { @MainActor in self?.partialText = text }
        }
        let errorHandler: (String) -> Void = { [weak self] message in
            Task { @MainActor in self?.errorMessage = message }
        }

        detector.threshold = vadThreshold
        if asrProvider == .scribe {
            scribeASR.onPartial = partialHandler
            scribeASR.onError = errorHandler
            scribeASR.connect(apiKey: elevenKey, keyterms: keytermList)
            detector.onStart = { [scribeASR] in scribeASR.beginUtterance() }
            detector.forward = { [scribeASR] buffer in scribeASR.append(buffer) }
        } else {
            deepgramASR.onPartial = partialHandler
            deepgramASR.onError = errorHandler
            deepgramASR.connect(apiKey: deepgramKey)
            detector.onStart = { [deepgramASR] in deepgramASR.beginUtterance() }
            detector.forward = { [deepgramASR] buffer in deepgramASR.append(buffer) }
        }
        detector.onEnd = { [weak self] in
            Task { @MainActor in await self?.finishCloudUtterance() }
        }
        detector.reset()
        audio.onBuffer = { [detector] buffer in detector.feed(buffer) }
    }

    private func finishCloudUtterance() async {
        state = .translating
        let started = Date()
        defer {
            detector.resume()
            if running { state = .listening }
        }

        let detected = detector.takeGender()

        let hadPartial = !partialText.isEmpty
        let recognized: (text: String, lang: Lang)?
        if asrProvider == .scribe {
            if let u = await scribeASR.endUtterance() {
                recognized = (u.text, u.lang)
            } else {
                recognized = nil
            }
        } else {
            if let u = await deepgramASR.endUtterance() {
                recognized = (u.text, u.lang)
            } else {
                recognized = nil
            }
        }

        guard let utterance = recognized else {
            partialText = ""
            // 有过中间字幕却没拿到终稿:识别端超时或重复句被丢弃
            if hadPartial {
                errorMessage = "识别未返回终稿(\(Self.elapsed(started))),网络弱或与上一句重复"
            }
            return
        }
        partialText = ""

        let lang = utterance.lang
        let targetLang = lang.opposite
        let playOnLeft = (targetLang == .zh) ? zhOnLeft : !zhOnLeft
        let gender = resolveGender(detected: detected, lang: lang)
        let voiceId = gender == .male ? elevenVoiceMaleId : elevenVoiceId

        var full = ""
        var chunk = ""
        var firstChunk = true
        var ttsFailures: [String] = []

        let (sentences, feeder) = AsyncStream<String>.makeStream()
        let speaker = Task { [weak self] in
            var failures: [String] = []
            for await sentence in sentences {
                guard let self else { return failures }
                if let failure = await self.speakSentence(sentence, lang: targetLang, gender: gender, voiceId: voiceId, playOnLeft: playOnLeft) {
                    failures.append(failure)
                }
            }
            return failures
        }

        do {
            for try await token in cloudTranslator.stream(text: utterance.text, from: lang, apiKey: anthropicKey) {
                full += token
                chunk += token
                while let sentence = Self.takeSentence(&chunk, eager: firstChunk) {
                    firstChunk = false
                    state = .playing
                    feeder.yield(sentence)
                }
            }
            let rest = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty {
                state = .playing
                feeder.yield(rest)
            }
            feeder.finish()
            ttsFailures = await speaker.value

            let translation = full.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translation.isEmpty else {
                errorMessage = "译文为空(原文只有口头语)"
                return
            }
            entries.append(TranscriptEntry(lang: lang, original: utterance.text, translation: translation))
            cloudTranslator.remember(source: utterance.text, target: translation, lang: lang)

            if ttsFailures.isEmpty {
                errorMessage = nil
            } else {
                errorMessage = "合成降级到系统语音: \(ttsFailures.first ?? "")"
            }

            await audio.finishStream(onLeft: playOnLeft)
        } catch {
            feeder.finish()
            _ = await speaker.value
            errorMessage = "翻译失败(\(Self.elapsed(started))): \(error.localizedDescription)"
        }
    }

    /// 播一句译文:优先 ElevenLabs 云端音色,失败自动降级系统语音。返回失败原因(成功返回 nil)
    private func speakSentence(_ text: String, lang: Lang, gender: SpeakerGender, voiceId: String, playOnLeft: Bool) async -> String? {
        do {
            try await cloudTTS.stream(text: text, apiKey: elevenKey, voiceId: voiceId) { [audio] buffer in
                audio.scheduleStream(buffer, onLeft: playOnLeft)
            }
            return nil
        } catch {
            let buffers = await localSynth.render(text, lang: lang, to: audio.playbackFormat, rate: speechRate, gender: gender)
            if buffers.isEmpty {
                return "ElevenLabs 失败且系统语音也无输出: \(error.localizedDescription)"
            }
            await audio.play(buffers: buffers, onLeft: playOnLeft)
            return error.localizedDescription
        }
    }

    private static func elapsed(_ since: Date) -> String {
        String(format: "%.1f 秒", Date().timeIntervalSince(since))
    }

    private static func takeSentence(_ buffer: inout String, eager: Bool) -> String? {
        var enders: Set<Character> = ["。", "!", "?", "!", "?", ".", ";", ";", "\n"]
        if eager {
            enders.formUnion([",", ",", "、", ":", ":"])
        }
        if let idx = buffer.lastIndex(where: { enders.contains($0) }) {
            let head = String(buffer[...idx]).trimmingCharacters(in: .whitespacesAndNewlines)
            let minLength = eager ? 4 : 2
            guard head.count >= minLength else { return nil }
            buffer = String(buffer[buffer.index(after: idx)...])
            return head
        }
        if buffer.count > 90 {
            let head = buffer
            buffer = ""
            return head
        }
        return nil
    }
}
