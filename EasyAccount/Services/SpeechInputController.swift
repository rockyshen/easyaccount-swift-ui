import AVFoundation
import Foundation
import Speech

/// 按住说话：调用系统 Speech 框架，将语音实时识别为文字。
@MainActor
final class SpeechInputController: ObservableObject {
    @Published private(set) var partialText = ""
    @Published private(set) var isListening = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

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
        stopEngine(cancelTask: true)
        partialText = ""

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
                if let result {
                    self.partialText = result.bestTranscription.formattedString
                }
                if error != nil {
                    // 松手结束为主；识别器中间错误不强制清空已有 partial
                    return
                }
            }
        }
    }

    /// 结束识别并返回最终文本。
    @discardableResult
    func stop() -> String {
        let text = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        recognitionRequest?.endAudio()
        stopEngine(cancelTask: true)
        recognitionRequest = nil
        partialText = ""
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return text
    }

    func cancel() {
        stopEngine(cancelTask: true)
        recognitionRequest = nil
        partialText = ""
        isListening = false
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
