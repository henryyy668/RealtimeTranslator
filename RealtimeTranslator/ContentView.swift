import SwiftUI
import Translation

struct ContentView: View {
    @StateObject private var core = TranslatorCore()
    @State private var zhEnConfig: TranslationSession.Configuration?
    @State private var enZhConfig: TranslationSession.Configuration?
    @State private var faceToFace = true
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // 上半屏给对面的英文使用者看,面对面模式下旋转 180 度
            pane(.en)
                .rotationEffect(faceToFace ? .degrees(180) : .degrees(0))
            centerBar
            pane(.zh)
            controls
        }
        .background(Color(.systemGroupedBackground))
        .onAppear {
            if zhEnConfig == nil {
                zhEnConfig = TranslationSession.Configuration(
                    source: Locale.Language(identifier: "zh-CN"),
                    target: Locale.Language(identifier: "en-US")
                )
                enZhConfig = TranslationSession.Configuration(
                    source: Locale.Language(identifier: "en-US"),
                    target: Locale.Language(identifier: "zh-CN")
                )
            }
        }
        .translationTask(zhEnConfig) { session in
            core.zhToEn = session
        }
        .translationTask(enZhConfig) { session in
            core.enToZh = session
        }
        .sheet(isPresented: $showSettings) {
            settings
        }
    }

    // MARK: - 对话面板

    /// 每个面板用对应语言渲染整段对话:
    /// 自己说的显示原文(浅色),对方说的显示译文(深色加粗)
    private func pane(_ lang: Lang) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(core.entries) { entry in
                        bubble(entry, side: lang)
                    }
                }
                .padding()
            }
            .onChange(of: core.entries.count) {
                if let last = core.entries.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func bubble(_ entry: TranscriptEntry, side: Lang) -> some View {
        let mine = entry.lang == side
        let text = mine ? entry.original : entry.translation
        return Text(text)
            .font(.title3)
            .fontWeight(mine ? .regular : .semibold)
            .foregroundStyle(mine ? .secondary : .primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.systemBackground).opacity(mine ? 0.6 : 1.0))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
            .id(entry.id)
    }

    // MARK: - 中缝状态条

    private var centerBar: some View {
        VStack(spacing: 4) {
            Divider()
            HStack(spacing: 8) {
                Circle()
                    .fill(core.running ? Color.teal : Color.gray)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !core.partialText.isEmpty {
                    Text(core.partialText)
                        .font(.footnote)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
                if core.running, !core.outputName.isEmpty {
                    Text("输出: \(core.outputName)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 2)
            Divider()
        }
    }

    private var statusText: String {
        switch core.state {
        case .idle: return "点击麦克风开始对话"
        case .listening: return "正在聆听"
        case .translating: return "翻译中"
        case .playing: return "播报中"
        }
    }

    // MARK: - 底部控制区

    private var controls: some View {
        VStack(spacing: 10) {
            if let error = core.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Button {
                core.toggle()
            } label: {
                Image(systemName: core.running ? "stop.fill" : "mic.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white)
                    .frame(width: 76, height: 76)
                    .background(core.running ? Color.red : Color.teal)
                    .clipShape(Circle())
                    .shadow(radius: 4)
            }
            HStack {
                Button("下载语言包") {
                    core.downloadLanguages()
                }
                Spacer()
                Toggle("面对面", isOn: $faceToFace)
                    .fixedSize()
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
            }
            .font(.callout)
            .padding(.horizontal, 24)
        }
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: - 设置

    private var settings: some View {
        NavigationStack {
            Form {
                Section("翻译引擎") {
                    Picker("引擎", selection: $core.engine) {
                        Text("端上(离线免费)").tag(TranslatorCore.Engine.onDevice)
                        Text("云端(低延迟)").tag(TranslatorCore.Engine.cloud)
                    }
                    .pickerStyle(.segmented)
                    if core.engine == .cloud {
                        SecureField("Deepgram API Key(识别)", text: $core.deepgramKey)
                        SecureField("Anthropic API Key(翻译)", text: $core.anthropicKey)
                        SecureField("ElevenLabs API Key(合成)", text: $core.elevenKey)
                        Text("Key 只保存在设备钥匙串,请求直连各服务商。三个平台注册都有免费额度。切换引擎会停止当前会话。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("译文声音") {
                    Picker("声音", selection: $core.voiceMode) {
                        Text("跟随说话人").tag(TranslatorCore.VoiceMode.auto)
                        Text("固定男声").tag(TranslatorCore.VoiceMode.male)
                        Text("固定女声").tag(TranslatorCore.VoiceMode.female)
                    }
                    .pickerStyle(.segmented)
                    if core.engine == .cloud {
                        TextField("ElevenLabs 男声 Voice ID", text: $core.elevenVoiceMaleId)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        TextField("ElevenLabs 女声 Voice ID", text: $core.elevenVoiceId)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    Text("「跟随说话人」会根据说话人的声音高低自动判断男女,男声说的话用男声播译文,女声用女声。判断不准时可以固定。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("声道分配") {
                    Toggle("中文译文送到左耳", isOn: $core.zhOnLeft)
                    Text("两人各戴一只耳机。说中文的人戴接收中文译文的那只,说英文的朋友戴另一只。译文只送进对应的耳朵,互不干扰。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("播报") {
                    VStack(alignment: .leading) {
                        Text("语速(端上引擎和兜底语音)")
                        Slider(value: $core.speechRate, in: 0.35...0.6)
                    }
                }
                Section("拾音") {
                    VStack(alignment: .leading) {
                        Text("触发灵敏度(环境吵就往右调)")
                        Slider(value: $core.vadThreshold, in: 0.005...0.05)
                    }
                }
            }
            .onChange(of: core.engine) {
                if core.running { core.stop() }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    ContentView()
}
