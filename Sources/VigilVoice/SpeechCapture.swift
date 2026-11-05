import AVFoundation
import Foundation
import Speech

/// Push-to-talk speech capture for "speak to schedule". On-device recognition only: if the
/// on-device model isn't available for the user's language, it refuses rather than using Apple's servers.
@MainActor
public final class SpeechCapture: ObservableObject {
    @Published public private(set) var transcript = ""
    @Published public private(set) var listening = false
    @Published public var problem: String?

    private let recognizer = SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    public init() {}

    public var available: Bool { recognizer?.supportsOnDeviceRecognition == true }

    public func toggle() async { if listening { stop() } else { await start() } }

    public func start() async {
        problem = nil
        transcript = ""
        guard let recognizer, recognizer.isAvailable else { problem = "Speech recognition isn't available right now."; return }
        guard recognizer.supportsOnDeviceRecognition else {
            problem = "On-device speech isn't available for your language, so Vigil won't listen. Type the task instead."
            return
        }
        let speechOK = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speechOK else { problem = "Allow Speech Recognition for Vigil in System Settings → Privacy & Security."; return }
        let micOK = await AVCaptureDevice.requestAccess(for: .audio)
        guard micOK else { problem = "Allow Microphone access for Vigil in System Settings → Privacy & Security."; return }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true      // never leaves the device
        req.shouldReportPartialResults = true
        request = req
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in req.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch { problem = "Couldn't start the microphone."; cleanup(); return }
        listening = true
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result { self.transcript = result.bestTranscription.formattedString }
                if error != nil || result?.isFinal == true { self.cleanup() }
            }
        }
    }

    /// Stops listening; the final transcript arrives a moment later.
    public func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        listening = false
    }

    private func cleanup() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request = nil
        task = nil
        listening = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
