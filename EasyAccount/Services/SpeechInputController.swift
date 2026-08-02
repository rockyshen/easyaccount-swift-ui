import AVFoundation
import Foundation
import Speech

/// 按住说话：调用系统 Speech 框架，将语音实时识别为文字。
@MainActor
final class SpeechInputController: ObservableObject {
    @Published private(set) var partialText = ""
    @Published private(set) var isListening = false
    /// 松手后的续录 / 等待最终结果阶段（后台进行，不驱动录制 UI）。
    @Published private(set) var isFinalizing = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var receivedFinal = false
    private var sessionGeneration = 0

    /// 松手后继续录入的时长，避免吞掉句尾几个字。
    private let defaultTailSeconds: TimeInterval = 1.2
    /// 停止送音频后，等待 `isFinal` 的最长时间。
    private let finalResultTimeoutSeconds: TimeInterval = 2.0

    var isAvailable: Bool {
        recognizer?.isAvailable == true
    }

    /// 申请语音识别与麦克风权限。
    func requestPermissions() async -> Bool {
        let speechAuthorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speechAuthorized else { return false }

        let micAuthorized = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
        return micAuthorized
    }

    func start() throws {
        cancel()
        partialText = ""
        receivedFinal = false
        sessionGeneration += 1
        let generation = sessionGeneration

        guard let recognizer, recognizer.isAvailable else {
            throw SpeechInputError.recognizerUnavailable
        }

        let session = AVAudioSession.sharedInstance()
        // 用 playAndRecord 而非 record：record 会独占音频硬件并屏蔽 Taptic，
        // 导致按住说话期间（如上滑取消）的震动反馈无法播放。
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .allowBluetooth, .defaultToSpeaker])
        try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        // 有网时可用云端识别，提升中文效果；设备支持时也可走端侧
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = false
        }
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw SpeechInputError.audioEngineFailed
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isListening = true

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                guard self.sessionGeneration == generation else { return }
                if let result {
                    self.partialText = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.receivedFinal = true
                    }
                }
                if error != nil {
                    // 松手结束为主；识别器中间错误不强制清空已有 partial
                    return
                }
            }
        }
    }

    /// 松手发送：续录一小段尾音，再结束音频并等待最终识别结果。
    func finish(tailSeconds: TimeInterval? = nil) async -> String {
        let tail = max(0, tailSeconds ?? defaultTailSeconds)
        guard recognitionRequest != nil else {
            return partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let generation = sessionGeneration
        isFinalizing = true
        isListening = true

        // 1) 松手后续录，把句尾几个字送进识别器。
        if audioEngine.isRunning, tail > 0 {
            try? await Task.sleep(nanoseconds: UInt64(tail * 1_000_000_000))
        }
        guard sessionGeneration == generation else { return "" }

        // 2) 声明「没有更多音频」，但不要立刻 cancel task，否则最终结果会被丢掉。
        recognitionRequest?.endAudio()
        stopEngine(cancelTask: false)
        isListening = false

        // 3) 等待 isFinal（最后几个字经常只出现在最终结果里）。
        let timeoutNanoseconds = UInt64(finalResultTimeoutSeconds * 1_000_000_000)
        let started = DispatchTime.now().uptimeNanoseconds
        while !receivedFinal {
            guard sessionGeneration == generation else { return "" }
            let elapsed = DispatchTime.now().uptimeNanoseconds &- started
            if elapsed >= timeoutNanoseconds { break }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }

        let text = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        tearDownSession(cancelTask: true)
        return text
    }

    /// 立即停止并丢弃结果（上滑取消）。
    func cancel() {
        sessionGeneration += 1
        tearDownSession(cancelTask: true)
    }

    private func tearDownSession(cancelTask: Bool) {
        stopEngine(cancelTask: cancelTask)
        recognitionRequest = nil
        if cancelTask {
            recognitionTask = nil
        }
        partialText = ""
        receivedFinal = false
        isListening = false
        isFinalizing = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func stopEngine(cancelTask: Bool) {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        if cancelTask {
            recognitionTask?.cancel()
            recognitionTask = nil
        }
    }
}

enum SpeechInputError: LocalizedError {
    case recognizerUnavailable
    case audioEngineFailed
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "当前无法使用语音识别，请检查系统中文语音资源或网络"
        case .audioEngineFailed:
            return "无法启动麦克风录音"
        case .permissionDenied:
            return "需要麦克风和语音识别权限，请在系统设置中开启"
        }
    }
}
