import AppKit
import SwiftUI

enum ScrollMode: String, CaseIterable, Identifiable {
    case voice, auto
    var id: String { rawValue }
    var label: String { self == .voice ? "Follow Voice" : "Auto Scroll" }
}

final class PrompterModel: ObservableObject {
    private let defaults = UserDefaults.standard

    // Settings (persisted)
    @Published var script: String { didSet { defaults.set(script, forKey: "script") } }
    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: "fontSize") } }
    @Published var speed: Double { didSet { defaults.set(speed, forKey: "speed") } }
    @Published var mirror: Bool { didSet { defaults.set(mirror, forKey: "mirror") } }
    @Published var inputDeviceUID: String {
        didSet {
            defaults.set(inputDeviceUID, forKey: "inputDeviceUID")
            if oldValue != inputDeviceUID, isPresenting, mode == .voice { speech.stop(); startListening() }
        }
    }
    @Published var inputDevices: [AudioInputDevice] = []
    @Published var floatOnTop: Bool { didSet { defaults.set(floatOnTop, forKey: "floatOnTop"); applyWindowLevel() } }
    @Published var mode: ScrollMode {
        didSet { defaults.set(mode.rawValue, forKey: "mode"); if oldValue != mode { modeChanged() } }
    }

    // Presentation state
    @Published var isPresenting = false
    @Published var isPlaying = false
    @Published var currentWord = 0
    @Published var micLevel: Float = 0
    @Published var lastHeard = ""
    @Published var status: String?
    @Published private(set) var resetToken = 0

    private(set) var words: [ScriptWord] = []
    private var matcher = ScriptMatcher(words: [])
    private let speech = SpeechTracker()

    init() {
        script = defaults.string(forKey: "script") ?? Self.sampleScript
        fontSize = defaults.object(forKey: "fontSize") as? Double ?? 56
        speed = defaults.object(forKey: "speed") as? Double ?? 60
        mirror = defaults.bool(forKey: "mirror")
        floatOnTop = defaults.bool(forKey: "floatOnTop")
        inputDeviceUID = defaults.string(forKey: "inputDeviceUID") ?? ""
        inputDevices = AudioDevices.inputs()
        mode = ScrollMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .voice

        speech.onWords = { [weak self] in self?.handleSpoken($0) }
        speech.onLevel = { [weak self] level in
            guard let self, abs(level - self.micLevel) > 0.03 else { return }
            self.micLevel = level
        }
        speech.onError = { [weak self] msg in
            dlog("error: \(msg)")
            self?.status = msg
            self?.isPlaying = false
        }
    }

    // MARK: Actions

    func start() {
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { NSSound.beep(); return }
        words = ScriptTokenizer.words(in: script)
        matcher = ScriptMatcher(words: words.map(\.norm))
        currentWord = 0
        status = nil
        lastHeard = ""
        isPlaying = false
        resetToken += 1
        dlog("start mode=\(mode.rawValue) words=\(words.count)")
        isPresenting = true
        if mode == .voice {
            startListening()
        } else {
            let token = resetToken
            status = "Starting…"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.isPresenting, self.mode == .auto, self.resetToken == token else { return }
                if self.status == "Starting…" { self.status = nil }
                self.isPlaying = true
            }
        }
    }

    func stop() {
        speech.stop()
        micLevel = 0
        isPlaying = false
        isPresenting = false
        status = nil
    }

    func togglePlay() {
        switch mode {
        case .auto:
            if status == "Starting…" { status = nil }
            isPlaying.toggle()
        case .voice:
            if speech.isRunning { stopListening() } else { startListening() }
        }
    }

    func restartFromTop() {
        currentWord = 0
        resetToken += 1
    }

    func nudge(_ delta: Int) {
        guard !words.isEmpty else { return }
        currentWord = min(max(0, currentWord + delta), words.count - 1)
    }

    func refreshDevices() {
        inputDevices = AudioDevices.inputs()
        dlog("inputs: " + inputDevices.map { "\($0.name) [\($0.uid)]" }.joined(separator: ", "))
    }

    var systemDefaultLabel: String { "System Default (\(AudioDevices.defaultInputName() ?? "unknown"))" }

    func adjustFont(_ delta: Double) { fontSize = min(160, max(20, fontSize + delta)) }
    func adjustSpeed(_ delta: Double) { speed = min(400, max(10, speed + delta)) }

    func pasteFromClipboard() -> Bool {
        guard let s = NSPasteboard.general.string(forType: .string),
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSSound.beep(); return false
        }
        script = s
        return true
    }

    func applyWindowLevel() {
        for w in NSApp.windows where w.isVisible || w.isMiniaturized {
            w.level = floatOnTop ? .floating : .normal
            if floatOnTop { w.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary]) }
            else { w.collectionBehavior.remove([.canJoinAllSpaces, .fullScreenAuxiliary]) }
        }
    }

    // MARK: Voice

    private func modeChanged() {
        guard isPresenting else { return }
        speech.stop()
        micLevel = 0
        isPlaying = false
        status = nil
        if mode == .voice { startListening() }
    }

    private func startListening() {
        status = "Starting microphone…"
        SpeechTracker.requestPermissions { [weak self] err in
            guard let self else { return }
            if let err { dlog(err); self.status = err; self.isPlaying = false; return }
            guard self.isPresenting, self.mode == .voice else { return }
            do {
                self.speech.contextualStrings = self.contextHints()
                self.speech.deviceUID = self.inputDeviceUID
                try self.speech.start()
                self.isPlaying = true
                self.status = nil
            } catch {
                dlog("start failed: \(error.localizedDescription)")
                self.status = error.localizedDescription
                self.isPlaying = false
            }
        }
    }

    private func stopListening() {
        speech.stop()
        micLevel = 0
        isPlaying = false
    }

    private func handleSpoken(_ spoken: [String]) {
        guard isPresenting, mode == .voice else { return }
        lastHeard = spoken.suffix(8).joined(separator: " ")
        let before = currentWord
        defer { if currentWord != before { dlog("heard '\(lastHeard)' -> word \(before) => \(currentWord)") } }
        if let next = matcher.advance(spoken: spoken, current: currentWord), next != currentWord {
            currentWord = min(next, words.count)
        }
    }

    /// Unusual words from the script help the recognizer with names and jargon.
    private func contextHints() -> [String] {
        let ns = script as NSString
        var seen = Set<String>()
        var out: [String] = []
        for w in words where w.norm.count >= 6 && !seen.contains(w.norm) {
            seen.insert(w.norm)
            out.append(ns.substring(with: w.range))
            if out.count >= 100 { break }
        }
        return out
    }

    static let sampleScript = """
    Welcome to your teleprompter.

    Paste your own script with the Paste button, or just type here. Then press Start.

    In Follow Voice mode, the app listens through your microphone and scrolls along as you read out loud. Words you've already said fade to gray, and the yellow markers show your reading line. If you go off script, it waits for you to come back.

    In Auto Scroll mode, the text moves at a steady speed. Use the up and down arrow keys to change the speed, and the space bar to pause.

    Press Escape when you're done.
    """
}
