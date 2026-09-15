import Foundation
import AVFoundation
import Speech

/// Records a voice note and transcribes it. Prefers on-device recognition when the OS supports it.
@MainActor
@Observable
final class SpeechService {
    enum State: Equatable { case idle, requestingPermission, recording, transcribing, done, failed(String) }

    private(set) var state: State = .idle
    private(set) var liveTranscript: String = ""
    private(set) var audioLevel: Float = 0
    private(set) var recordedFileURL: URL?

    private var audioEngine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var fileWriter: AVAudioFile?
    private var finalTranscript: String = ""
    private var isOnDevice = false

    var usesOnDeviceRecognition: Bool { isOnDevice }

    func requestPermissions() async -> Bool {
        state = .requestingPermission
        let mic = await AVAudioApplication.requestRecordPermission()
        guard mic else { state = .failed("Microphone access is needed to record."); return false }
        let speech = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speech == .authorized else { state = .failed("Speech recognition isn't allowed."); return false }
        state = .idle
        return true
    }

    func start() throws {
        let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else { state = .failed("Speech recognition isn't available right now."); return }
        self.recognizer = recognizer

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
            isOnDevice = true
        }
        req.addsPunctuation = true
        request = req

        let url = FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString).caf")
        fileWriter = try AVAudioFile(forWriting: url, settings: format.settings)
        recordedFileURL = url

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.request?.append(buffer)
            try? self.fileWriter?.write(from: buffer)
            let level = Self.rms(buffer)
            Task { @MainActor in self.audioLevel = level }
        }

        engine.prepare()
        try engine.start()
        audioEngine = engine
        liveTranscript = ""
        finalTranscript = ""
        state = .recording

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.liveTranscript = result.bestTranscription.formattedString
                    if result.isFinal { self.finalTranscript = result.bestTranscription.formattedString }
                }
                if let error, self.state == .recording {
                    // Ignore the cancellation error we trigger ourselves when stopping.
                    let ns = error as NSError
                    if ns.code != 216 && ns.code != 1110 { Log.capture.error("Speech error: \(ns.localizedDescription)") }
                }
            }
        }
    }

    /// Stops recording and returns the best transcript.
    func stop() async -> String {
        guard state == .recording else { return liveTranscript }
        state = .transcribing
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        request?.endAudio()
        fileWriter = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        // Give the recognizer a moment to finalize; fall back to the live transcript.
        for _ in 0..<20 where finalTranscript.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }
        task?.cancel()
        task = nil
        request = nil
        audioEngine = nil
        state = .done
        let text = finalTranscript.isEmpty ? liveTranscript : finalTranscript
        return text
    }

    func cancel() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        task?.cancel()
        request?.endAudio()
        task = nil; request = nil; audioEngine = nil; fileWriter = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if let url = recordedFileURL { try? FileManager.default.removeItem(at: url) }
        recordedFileURL = nil
        state = .idle
    }

    private nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        return min(1, sqrt(sum / Float(n)) * 8)
    }
}
