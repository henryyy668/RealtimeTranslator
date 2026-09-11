import AVFoundation

/// 音频中枢:负责音频会话配置、麦克风采集、以及把两路译文分别送进左右声道。
///
/// 一副耳机(如 AirPods)对系统来说是一个立体声输出设备,
/// 你戴左耳、朋友戴右耳,中文译文只 pan 到左声道、英文译文只 pan 到右声道。
/// 收音始终用 iPhone 自带麦克风,耳机保持 A2DP 高音质输出。
///
/// 外放(手机喇叭 / 车机)时自动打开系统语音处理(回声消除 + 噪音抑制 + 自动增益)。
/// 语音处理是单声道的,连着耳机时必须关掉;而且它会改变输出格式,
/// 所以每次切换都把"混音器到输出"的连线拆掉重建,保证耳机时是立体声。
final class AudioManager {
    let engine = AVAudioEngine()
    private let playerLeft = AVAudioPlayerNode()
    private let playerRight = AVAudioPlayerNode()
    private var observers: [NSObjectProtocol] = []
    private var graphBuilt = false
    private var running = false

    /// TTS 播放统一转换到的单声道格式,经 pan 混入立体声输出
    let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    /// 每个麦克风缓冲的回调(音频线程调用)
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// 当前输出设备名称变化时回调(主线程)
    var onRouteChange: ((String) -> Void)?

    /// 当前是否开着系统语音处理(降噪)
    private(set) var voiceProcessingOn = false

    var currentOutputName: String {
        let outs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard let first = outs.first else { return "无" }
        switch first.portType {
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP:
            return voiceProcessingOn ? "\(first.portName)·降噪" : first.portName
        case .builtInSpeaker: return voiceProcessingOn ? "扬声器·降噪" : "扬声器"
        case .builtInReceiver: return "听筒"
        case .headphones: return "有线耳机"
        default: return first.portName
        }
    }

    private var hasBluetoothOutput: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            $0.portType == .bluetoothA2DP || $0.portType == .bluetoothLE || $0.portType == .bluetoothHFP
        }
    }

    func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.allowBluetoothA2DP]
        )
        try session.setActive(true)

        if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
        }

        applyOutputOverride()
        installObservers()
        notifyRoute()
    }

    private func applyOutputOverride() {
        let session = AVAudioSession.sharedInstance()
        if hasBluetoothOutput {
            try? session.overrideOutputAudioPort(.none)
        } else {
            try? session.overrideOutputAudioPort(.speaker)
        }
    }

    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.applyOutputOverride()
            self.reconfigureForRouteIfNeeded()
            self.restartEngineIfNeeded()
            self.notifyRoute()
        })

        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in
            self?.restartEngineIfNeeded()
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            self.restartEngineIfNeeded()
        })
    }

    private func notifyRoute() {
        let name = currentOutputName
        DispatchQueue.main.async { [weak self] in
            self?.onRouteChange?(name)
        }
    }

    private func restartEngineIfNeeded() {
        guard graphBuilt, running, !engine.isRunning else { return }
        engine.prepare()
        do {
            try engine.start()
            playerLeft.play()
            playerRight.play()
        } catch {
            print("音频引擎重启失败: \(error)")
        }
    }

    /// 把混音器重新连到输出节点,让连线格式跟随当前硬件(耳机立体声 / 语音处理单声道)
    private func relinkMixerToOutput() {
        guard graphBuilt else { return }
        engine.disconnectNodeOutput(engine.mainMixerNode)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
    }

    /// 按当前路由决定语音处理开关:有蓝牙耳机 -> 关(保立体声),外放 -> 开(降噪)。
    /// 返回是否真的切换了。
    private func applyVoiceProcessing() -> Bool {
        let input = engine.inputNode
        let wantVP = !hasBluetoothOutput
        guard input.isVoiceProcessingEnabled != wantVP else {
            voiceProcessingOn = input.isVoiceProcessingEnabled
            return false
        }
        do {
            try input.setVoiceProcessingEnabled(wantVP)
        } catch {
            print("语音处理切换失败: \(error)")
        }
        voiceProcessingOn = input.isVoiceProcessingEnabled
        relinkMixerToOutput()
        return true
    }

    private func installTap() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.onBuffer?(buffer)
        }
    }

    /// 耳机连上 / 断开后,如果语音处理状态和新路由不匹配,停下引擎重配一次
    private func reconfigureForRouteIfNeeded() {
        guard running, graphBuilt else { return }
        let input = engine.inputNode
        let wantVP = !hasBluetoothOutput
        guard input.isVoiceProcessingEnabled != wantVP else { return }

        input.removeTap(onBus: 0)
        engine.stop()
        _ = applyVoiceProcessing()
        installTap()
        engine.prepare()
        do {
            try engine.start()
            playerLeft.play()
            playerRight.play()
        } catch {
            print("路由切换后引擎重启失败: \(error)")
        }
    }

    func start() throws {
        running = true
        let vpToggled = applyVoiceProcessing()

        if !graphBuilt {
            engine.attach(playerLeft)
            engine.attach(playerRight)
            engine.connect(playerLeft, to: engine.mainMixerNode, format: playbackFormat)
            engine.connect(playerRight, to: engine.mainMixerNode, format: playbackFormat)
            playerLeft.pan = -1.0
            playerRight.pan = 1.0
            graphBuilt = true
        }

        applyOutputOverride()

        // 每次开始都按当前输出格式重连一次,确保耳机时是立体声
        relinkMixerToOutput()

        // 语音处理刚切换过:先空跑一次让硬件格式稳定下来
        if vpToggled {
            engine.prepare()
            try engine.start()
            Thread.sleep(forTimeInterval: 0.25)
            engine.stop()
            relinkMixerToOutput()
        }

        installTap()
        engine.prepare()
        try engine.start()
        playerLeft.play()
        playerRight.play()
        notifyRoute()
    }

    func stop() {
        running = false
        engine.inputNode.removeTap(onBus: 0)
        playerLeft.stop()
        playerRight.stop()
        engine.stop()
    }

    /// 把一段 TTS 缓冲调度到指定声道播放,播放完成后返回;超时也返回,绝不卡死
    func play(buffers: [AVAudioPCMBuffer], onLeft: Bool) async {
        guard !buffers.isEmpty else { return }
        restartEngineIfNeeded()
        let player = onLeft ? playerLeft : playerRight
        let seconds = buffers.reduce(0.0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
        await waitPlayback(timeout: seconds + 3) { done in
            for (index, buffer) in buffers.enumerated() {
                if index == buffers.count - 1 {
                    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in done() }
                } else {
                    player.scheduleBuffer(buffer)
                }
            }
        }
    }

    // MARK: - 云端流式播放

    func scheduleStream(_ buffer: AVAudioPCMBuffer, onLeft: Bool) {
        restartEngineIfNeeded()
        (onLeft ? playerLeft : playerRight).scheduleBuffer(buffer)
    }

    func finishStream(onLeft: Bool) async {
        restartEngineIfNeeded()
        guard let tail = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: 240) else { return }
        tail.frameLength = 240
        if let channel = tail.floatChannelData {
            memset(channel[0], 0, Int(tail.frameLength) * MemoryLayout<Float>.size)
        }
        let player = onLeft ? playerLeft : playerRight
        await waitPlayback(timeout: 12) { done in
            player.scheduleBuffer(tail, completionCallbackType: .dataPlayedBack) { _ in done() }
        }
    }

    private func waitPlayback(timeout: TimeInterval, schedule: (@escaping () -> Void) -> Void) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(cont)
            schedule { once.resume() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.resume()
            }
        }
    }
}

private final class ResumeOnce {
    private var resumed = false
    private let lock = NSLock()
    private let continuation: CheckedContinuation<Void, Never>

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume()
    }
}
