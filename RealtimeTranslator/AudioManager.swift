import AVFoundation

/// 音频中枢:负责音频会话配置、麦克风采集、以及把两路译文分别送进左右声道。
///
/// 核心思路:一副耳机(如 AirPods)对系统来说是一个立体声输出设备,
/// 你戴左耳、朋友戴右耳,中文译文只 pan 到左声道、英文译文只 pan 到右声道,
/// 两人各听各的互不干扰。收音始终用 iPhone 自带麦克风,
/// 这样耳机保持 A2DP 高音质输出,不会因为蓝牙上行掉到 HFP 低音质。
final class AudioManager {
    let engine = AVAudioEngine()
    private let playerLeft = AVAudioPlayerNode()
    private let playerRight = AVAudioPlayerNode()

    /// TTS 播放统一转换到的单声道格式,经 pan 混入立体声输出
    let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    /// 每个麦克风缓冲的回调(音频线程调用)
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // 只允许 A2DP 蓝牙输出保证耳机音质;不用 voiceChat 和 defaultToSpeaker,
        // 否则 iOS 会把输出强制按在手机喇叭上,耳机没声。
        // 半双工设计(播报时不收音)本身就避免了回声,不需要 voiceChat 的回声消除。
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.allowBluetoothA2DP]
        )
        try session.setActive(true)

        // 强制用 iPhone 自带麦克风收音,耳机只做输出
        if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
        }

        // 没连蓝牙耳机时,把输出切到扬声器(否则默认走听筒,声音很小)
        let hasBluetooth = session.currentRoute.outputs.contains {
            $0.portType == .bluetoothA2DP || $0.portType == .bluetoothLE || $0.portType == .bluetoothHFP
        }
        if !hasBluetooth {
            try? session.overrideOutputAudioPort(.speaker)
        }
    }

    func start() throws {
        engine.attach(playerLeft)
        engine.attach(playerRight)
        engine.connect(playerLeft, to: engine.mainMixerNode, format: playbackFormat)
        engine.connect(playerRight, to: engine.mainMixerNode, format: playbackFormat)
        playerLeft.pan = -1.0   // 完全左声道
        playerRight.pan = 1.0   // 完全右声道

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.onBuffer?(buffer)
        }

        engine.prepare()
        try engine.start()
        playerLeft.play()
        playerRight.play()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        playerLeft.stop()
        playerRight.stop()
        engine.stop()
    }

    /// 把一段 TTS 缓冲调度到指定声道播放,播放完成后才返回
    func play(buffers: [AVAudioPCMBuffer], onLeft: Bool) async {
        guard !buffers.isEmpty else { return }
        let player = onLeft ? playerLeft : playerRight
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            for (index, buffer) in buffers.enumerated() {
                if index == buffers.count - 1 {
                    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                        cont.resume()
                    }
                } else {
                    player.scheduleBuffer(buffer)
                }
            }
        }
    }

    // MARK: - 云端流式播放(v2)

    /// 云端 TTS 的音频块到一块播一块,不等整句合成完
    func scheduleStream(_ buffer: AVAudioPCMBuffer, onLeft: Bool) {
        (onLeft ? playerLeft : playerRight).scheduleBuffer(buffer)
    }

    /// 等待某个声道队列里的音频全部播完:队尾排一小段静音,它播完即全部播完
    func finishStream(onLeft: Bool) async {
        guard let tail = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: 240) else { return }
        tail.frameLength = 240
        if let channel = tail.floatChannelData {
            memset(channel[0], 0, Int(tail.frameLength) * MemoryLayout<Float>.size)
        }
        let player = onLeft ? playerLeft : playerRight
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            player.scheduleBuffer(tail, completionCallbackType: .dataPlayedBack) { _ in
                cont.resume()
            }
        }
    }
}
