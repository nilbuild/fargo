import Foundation
import Speech
import AVFoundation
import CoreMedia

@MainActor
@Observable
final class CaptionService {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    var currentText: String = "" {
        didSet {
            onTextChanged?(currentText)
        }
    }
    var onTextChanged: ((String) -> Void)?
    var isRunning: Bool = false
    var errorMessage: String?

    private var consecutiveErrors: Int = 0

    var textVersion: UInt64 = 0

    func start() {
        guard !isRunning else { return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                switch status {
                case .authorized:
                    self.beginRecognition()
                case .denied:
                    self.errorMessage = "Speech recognition permission denied"
                case .restricted:
                    self.errorMessage = "Speech recognition restricted on this device"
                case .notDetermined:
                    self.errorMessage = "Speech recognition not authorized"
                @unknown default:
                    self.errorMessage = "Speech recognition unavailable"
                }
            }
        }
    }

    func stop() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        isRunning = false
    }

    func resetErrorState() {
        consecutiveErrors = 0
        errorMessage = nil
    }

    nonisolated func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        // Safe to capture the request off the main actor: appendAudioSampleBuffer is
        // thread-safe and we only clear it from main.
        Task { @MainActor [weak self] in
            self?.recognitionRequest?.appendAudioSampleBuffer(sampleBuffer)
        }
    }

    private func beginRecognition() {
        guard let recognizer else {
            errorMessage = "Speech recognizer unavailable for en-US"
            return
        }
        guard recognizer.isAvailable else {
            errorMessage = "Speech recognizer not available right now"
            return
        }

        errorMessage = nil
        print("[Captions] beginRecognition - supportsOnDevice=\(recognizer.supportsOnDeviceRecognition)")

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13, *) {
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            request.addsPunctuation = true
        }
        recognitionRequest = request

        isRunning = true
        print("[Captions] recognition session started (consuming AVCaptureSession audio)")

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    print("[Captions] partial: \"\(text)\" isFinal=\(result.isFinal)")
                    if text != self.currentText {
                        self.currentText = text
                        self.textVersion &+= 1
                    }
                    self.consecutiveErrors = 0
                    if result.isFinal {
                        self.currentText = ""
                        self.textVersion &+= 1
                    }
                }
                if let error {
                    let nsError = error as NSError
                    print("[Captions] task error \(nsError.code): \(nsError.localizedDescription)")
                    if nsError.code != 1110 {
                        self.errorMessage = error.localizedDescription
                    }
                    self.restartAfterError()
                }
            }
        }
    }

    private func restartAfterError() {
        guard isRunning else { return }
        consecutiveErrors += 1
        guard consecutiveErrors <= 10 else {
            errorMessage = "Speech recognition stopped after repeated errors"
            stop()
            return
        }
        let delay = min(10.0, 0.5 * pow(2.0, Double(consecutiveErrors - 1)))
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.start()
        }
    }
}
