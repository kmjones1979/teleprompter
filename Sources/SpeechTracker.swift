import AVFoundation
import Foundation
import Speech

/// Streams microphone audio into Apple's speech recognizer and reports recognized words.
/// Recognition tasks are restarted automatically so listening can go on indefinitely.
final class SpeechTracker {
    var onWords: (([String]) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onError: ((String) -> Void)?
    var contextualStrings: [String] = []

    private(set) var isRunning = false
    private var engine = AVAudioEngine()
    /// CoreAudio UID of the input to use; empty means the system default.
    var deviceUID = ""
    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var preferOnDevice = true
    private var quickFailures = 0
    private var peak: Float = 0
    private var lastPeakLog = Date.distantPast

    static let dictationOffMessage = "Voice tracking needs Dictation turned on: System Settings › Keyboard › Dictation."

    static func requestPermissions(_ completion: @escaping (String?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            dlog("speech auth status: \(status.rawValue) (3 = authorized)")
            DispatchQueue.main.async {
                guard status == .authorized else {
                    completion("Speech Recognition access is off. Turn it on in System Settings › Privacy & Security › Speech Recognition.")
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    dlog("mic access: \(ok)")
                    DispatchQueue.main.async {
                        completion(ok ? nil : "Microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone.")
                    }
                }
            }
        }
    }

    func start() throws {
        guard !isRunning else { return }
        dlog("recognizer locale=\(recognizer?.locale.identifier ?? "nil") available=\(recognizer?.isAvailable ?? false) onDevice=\(recognizer?.supportsOnDeviceRecognition ?? false)")
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "Teleprompter", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Speech recognition isn't available right now. Check that Dictation/Siri is enabled in System Settings."])
        }
        engine = AVAudioEngine()   // fresh engine so a newly chosen device takes effect
        let input = engine.inputNode
        if !deviceUID.isEmpty, let devID = AudioDevices.deviceID(forUID: deviceUID), let unit = input.audioUnit {
            var dev = devID
            let err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                           &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
            dlog("using input device \(deviceUID) (status \(err))")
        } else {
            dlog("using system default input: \(AudioDevices.defaultInputName() ?? "?")")
        }
        // Use the device's real hardware format; the output format can be stale after switching devices.
        let hw = input.inputFormat(forBus: 0)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: hw.sampleRate, channels: max(1, hw.channelCount)) else {
            throw NSError(domain: "Teleprompter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Couldn't read the microphone's audio format."])
        }
        dlog("input format: \(format)")
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Teleprompter", code: 2, userInfo: [NSLocalizedDescriptionKey: "No microphone input found."])
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock(); let req = self.request; self.lock.unlock()
            req?.append(buffer)

            let n = Int(buffer.frameLength)
            if let data = buffer.floatChannelData?[0], n > 0 {
                var sum: Float = 0
                for i in 0..<n { sum += data[i] * data[i] }
                let db = 20 * log10(max(sqrt(sum / Float(n)), 1e-7))
                let level = max(0, min(1, (db + 55) / 45))
                self.peak = max(self.peak, level)
                let now = Date()
                if now.timeIntervalSince(self.lastPeakLog) > 2 {
                    dlog(String(format: "mic peak level %.2f", self.peak)); self.peak = 0; self.lastPeakLog = now
                }
                DispatchQueue.main.async { self.onLevel?(level) }
            }
        }
        engine.prepare()
        try engine.start()
        isRunning = true
        quickFailures = 0
        startTask()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation += 1
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        lock.lock(); request?.endAudio(); request = nil; lock.unlock()
        task?.cancel()
        task = nil
    }

    private func startTask() {
        guard isRunning, let recognizer else { return }
        generation += 1
        let gen = generation
        let startedAt = Date()

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        req.addsPunctuation = false
        req.contextualStrings = contextualStrings
        if preferOnDevice && recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        lock.lock(); request?.endAudio(); request = req; lock.unlock()
        dlog("recognition task #\(gen) started, onDevice=\(req.requiresOnDeviceRecognition)")

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let words = result.map { ScriptTokenizer.spokenTokens($0.bestTranscription.formattedString) }
            let finished = error != nil || (result?.isFinal ?? false)
            DispatchQueue.main.async {
                guard let self, gen == self.generation, self.isRunning else { return }
                if let words, !words.isEmpty {
                    self.quickFailures = 0
                    self.onWords?(words)
                }
                guard finished else { return }
                if let error = error as NSError?, error.code == 201 {
                    dlog("dictation disabled (201)")
                    self.stop()
                    self.onError?(SpeechTracker.dictationOffMessage)
                    return
                }
                if let error = error as NSError? {
                    dlog("task #\(gen) ended with error \(error.domain) \(error.code): \(error.localizedDescription)")
                } else {
                    dlog("task #\(gen) final: \(words?.joined(separator: " ") ?? "")")
                }
                self.task = nil
                if let error, words == nil, Date().timeIntervalSince(startedAt) < 1.5 {
                    self.quickFailures += 1
                    if self.quickFailures == 2, self.preferOnDevice {
                        self.preferOnDevice = false   // fall back to server recognition
                    } else if self.quickFailures >= 4 {
                        self.stop()
                        self.onError?("Speech recognition stopped: \(error.localizedDescription)")
                        return
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self, gen == self.generation, self.isRunning else { return }
                    self.startTask()
                }
            }
        }
    }
}
