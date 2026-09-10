import SwiftUI
import Combine
import Translation
import AVFoundation

/// 整条流水线的调度中心,三套引擎:
/// 端上(离线免费)/ 云端(Scribe + Claude + ElevenLabs,全双工排队)/ OpenAI 实时(边听边译)
@MainActor
final class TranslatorCore: ObservableObject {
    enum PipelineState {
        case idle, listening, translating, playing
    }

    enum Engine: String, CaseIterable {
        case onDevice
        case cloud
        case openai
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
    @Published var openaiKey: String = KeychainStore.get("openaiKey") {
        didSet { KeychainStore.set(openaiKey, for: "openaiKey") }
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
    private let openaiTranslator = OpenAIRealtimeTranslator()
    private var bag = Set<AnyCancellable>()
    private var lastGender: [Lang: SpeakerGender] = [:]

    private var pipeline: Task<Void, Never>?
    private var backlog = 0

    private var liveSource = ""
    private var liveTarget: [Lang: String] = [:]
    private var liveFlushTask: Task<Void, Never>?
    private var playingUntil = Date.distantPast
    private var unmuteTask: Task<Void, Never>?

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
            switch engine {
            case .onDevice:
                let speechOK = await DualRecognizer.requestPermission()
                guard speechOK else {
                    errorMessage = "需要语音识别权限,请到 设置 > 隐私与安全 中开启"
                    return
                }
            case .cloud:
                guard !anthropicKey.isEmpty, !elevenKey.isEmpty else {
                    errorMessage = "云端模式需要先在设置里填入 Anthropic 和 ElevenLabs 的 API Key"
                    return
                }
                if asrProvider == .deepgram && deepgramKey.isEmpty {
                    errorMessage = "选择 Deepgram 识别需要填入 Deepgram API Key,或切换到 Scribe"
                    return
                }
            case .openai:
                guard !openaiKey.isEmpty else {
                    errorMessage = "OpenAI 实时模式需要先在设置里填入 OpenAI API Key"
                    return
                }
            }
            do {
                try audio.configureSession()
                switch engine {
                case .onDevice: wireLocal()
                case .cloud: wireCloud()
                case .openai: wireOpenAI()
                }
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
        openaiTranslator.disconnect()
        cloudTranslator.reset()
        detector.reset()
        pipeline?.cancel()
        pipeline = nil
        backlog = 0
        liveFlushTask?.cancel()
        unmuteTask?.cancel()
        flushLive()
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

    private func setPlaying(_ playing: Bool) {
        state = playing ? .playing : (backlog > 0 ? .translating : .listening)
        detector.suppressed = playing && audio.voiceProcessingOn
    }

    // MARK: - 端上管线

    private func wireLocal() {
        localRecognizer.onPartial = { [weak self] text in
            Task { @MainActor in self?.partialText = text }
        }
        detector.threshold = vadThreshold
        detector.onStart = { [localRecognizer] in localRecognizer.begin() }
        detector.forward = { [localRecognizer] buffer in localRecognizer.append(buffer) }
        detector.onEnd = { [weak self] gender in
            Task { @MainActor in await self?.finishLocalUtterance(detected: gender) }
        }
        detector.reset()
        audio.onBuffer = { [detector] buffer in detector.feed(buffer) }
    }

    private func finishLocalUtterance(detected: SpeakerGender?) async {
        state = .translating
        defer { if running { state = .listening } }

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

            setPlaying(true)
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
            setPlaying(false)
        } catch {
            errorMessage = "翻译失败: \(error.localizedDescription)"
        }
    }

    // MARK: - 云端管线(全双工)

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
        detector.onEnd = { [weak self] gender in
            Task { @MainActor in self?.cloudUtteranceEnded(detected: gender) }
        }
        detector.reset()
        audio.onBuffer = { [detector] buffer in detector.feed(buffer) }
    }

    private func cloudUtteranceEnded(detected: SpeakerGender?) {
        let hadPartial = !partialText.isEmpty
        partialText = ""
        backlog += 1
        if state == .listening { state = .translating }

        let provider = asrProvider
        let scribe = scribeASR
        let deepgram = deepgramASR
        let recognizing = Task<(text: String, lang: Lang)?, Never> {
            if provider == .scribe {
                if let u = await scribe.endUtterance() { return (u.text, u.lang) }
            } else {
                if let u = await deepgram.endUtterance() { return (u.text, u.lang) }
            }
            return nil
        }

        let previous = pipeline
        pipeline = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let result = await recognizing.value
            await self.processCloud(result, detected: detected, hadPartial: hadPartial)
            self.backlog = max(0, self.backlog - 1)
            if self.running, self.backlog == 0, self.state != .playing { self.state = .listening }
        }
    }

    private func processCloud(_ recognized: (text: String, lang: Lang)?, detected: SpeakerGender?, hadPartial: Bool) async {
        let started = Date()
        guard let utterance = recognized else {
            if hadPartial {
                errorMessage = "识别未返回终稿(\(Self.elapsed(started))),网络弱或与上一句重复"
            }
            return
        }

        let lang = utterance.lang
        let targetLang = lang.opposite
        let playOnLeft = (targetLang == .zh) ? zhOnLeft : !zhOnLeft
        let gender = resolveGender(detected: detected, lang: lang)
        let voiceId = gender == .male ? elevenVoiceMaleId : elevenVoiceId

        var full = ""
        var chunk = ""
        var firstChunk = true

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
                    setPlaying(true)
                    feeder.yield(sentence)
                }
            }
            let rest = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty {
                setPlaying(true)
                feeder.yield(rest)
            }
            feeder.finish()
            let ttsFailures = await speaker.value

            let translation = full.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translation.isEmpty else {
                setPlaying(false)
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
            setPlaying(false)
        } catch {
            feeder.finish()
            _ = await speaker.value
            setPlaying(false)
            errorMessage = "翻译失败(\(Self.elapsed(started))): \(error.localizedDescription)"
        }
    }

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

    // MARK: - OpenAI 实时管线(边听边译)

    private func wireOpenAI() {
        liveSource = ""
        liveTarget = [:]
        openaiTranslator.onSourceText = { [weak self] text in
            Task { @MainActor in self?.appendLiveSource(text) }
        }
        openaiTranslator.onTargetText = { [weak self] text, lang in
            Task { @MainActor in self?.appendLiveTarget(text, lang: lang) }
        }
        openaiTranslator.onTargetAudio = { [weak self] buffer, lang in
            Task { @MainActor in
                guard let self else { return }
                let playOnLeft = (lang == .zh) ? self.zhOnLeft : !self.zhOnLeft
                self.audio.scheduleStream(buffer, onLeft: playOnLeft)
                self.noteAudioScheduled(seconds: Double(buffer.frameLength) / 24_000)
            }
        }
        openaiTranslator.onError = { [weak self] message in
            Task { @MainActor in self?.errorMessage = message }
        }
        openaiTranslator.connect(apiKey: openaiKey)
        audio.onBuffer = { [openaiTranslator] buffer in openaiTranslator.append(buffer) }
    }

    private func noteAudioScheduled(seconds: Double) {
        let now = Date()
        let base = max(now, playingUntil)
        playingUntil = base.addingTimeInterval(seconds)
        state = .playing
        if audio.voiceProcessingOn {
            openaiTranslator.setMuted(true)
        }
        unmuteTask?.cancel()
        let wait = playingUntil.timeIntervalSince(now) + 0.3
        unmuteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.openaiTranslator.setMuted(false)
            if self.running { self.state = .listening }
        }
    }

    private func appendLiveSource(_ text: String) {
        liveSource += text
        partialText = liveSource
        scheduleLiveFlush()
    }

    private func appendLiveTarget(_ text: String, lang: Lang) {
        liveTarget[lang, default: ""] += text
        scheduleLiveFlush()
    }

    private func scheduleLiveFlush() {
        liveFlushTask?.cancel()
        liveFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.flushLive()
        }
    }

    private func flushLive() {
        let source = liveSource.trimmingCharacters(in: .whitespacesAndNewlines)
        for (lang, text) in liveTarget {
            let translation = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translation.isEmpty else { continue }
            entries.append(TranscriptEntry(lang: lang.opposite, original: source, translation: translation))
        }
        liveSource = ""
        liveTarget = [:]
        partialText = ""
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
