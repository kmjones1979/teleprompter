import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct TeleprompterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = PrompterModel()

    var body: some Scene {
        Window("Teleprompter", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 720, minHeight: 440)
        }
        .defaultSize(width: 1000, height: 680)
    }
}

struct ContentView: View {
    @EnvironmentObject var model: PrompterModel

    var body: some View {
        Group {
            if model.isPresenting { PrompterView() } else { EditorView() }
        }
        .onAppear {
            DispatchQueue.main.async {
                model.applyWindowLevel()
                if CommandLine.arguments.contains("--autostart") { model.start() }
            }
        }
    }
}

// MARK: - Editor

struct EditorView: View {
    @EnvironmentObject var model: PrompterModel

    private var wordCount: Int { model.script.split(whereSeparator: \.isWhitespace).count }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    if model.pasteFromClipboard() { model.start() }
                } label: {
                    Label("Paste & Start", systemImage: "doc.on.clipboard.fill")
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .help("Replace the script with the clipboard and start (⇧⌘V)")

                Button {
                    _ = model.pasteFromClipboard()
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .help("Replace the script with the clipboard")

                Button(role: .destructive) { model.script = "" } label: { Label("Clear", systemImage: "trash") }

                Spacer()

                Picker("Mode", selection: $model.mode) {
                    ForEach(ScrollMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)

                Button { model.start() } label: { Label("Start", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Start (⌘↩)")
            }
            .padding(12)

            Divider()

            TextEditor(text: $model.script)
                .font(.system(size: 16))
                .padding(10)

            Divider()

            HStack(spacing: 18) {
                HStack(spacing: 6) {
                    Image(systemName: "textformat.size")
                    Slider(value: $model.fontSize, in: 20...160).frame(width: 130)
                    Text("\(Int(model.fontSize)) pt").monospacedDigit().frame(width: 48, alignment: .leading)
                }
                HStack(spacing: 6) {
                    Image(systemName: "tortoise")
                    Slider(value: $model.speed, in: 10...400).frame(width: 130)
                    Image(systemName: "hare")
                }
                .disabled(model.mode == .voice)
                .help("Auto-scroll speed")
                Toggle("Flip Horizontal", isOn: $model.mirror)
                    .help("Mirror the text for teleprompter glass (M)")
                MicPicker().frame(width: 230)
                Toggle("Keep on top", isOn: $model.floatOnTop)
                    .help("Float above other windows, e.g. over a video call")
                Spacer()
                Text("\(wordCount) words · ~\(max(1, Int((Double(wordCount) / 150).rounded()))) min")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(12)
        }
    }
}

// MARK: - Prompter

struct PrompterView: View {
    @EnvironmentObject var model: PrompterModel
    @State private var hudVisible = true
    @State private var hideWork: DispatchWorkItem?
    @State private var keyMonitor: Any?

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black

            ZStack {
                PrompterTextView(model: model)
                GeometryReader { geo in
                    let y = geo.size.height * readingLineFraction
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.yellow.opacity(0.85))
                        .position(x: 16, y: y)
                    Image(systemName: "arrowtriangle.left.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.yellow.opacity(0.85))
                        .position(x: geo.size.width - 16, y: y)
                }
                .allowsHitTesting(false)
            }

            VStack(spacing: 10) {
                if let status = model.status {
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.red.opacity(status.hasPrefix("Starting") ? 0 : 0.6), in: Capsule())
                        .background(.ultraThinMaterial, in: Capsule())
                    if status.contains("Dictation") || status.contains("Privacy") {
                        Button("Open System Settings") {
                            let url = status.contains("Dictation")
                                ? "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
                                : "x-apple.systempreferences:com.apple.preference.security?Privacy"
                            NSWorkspace.shared.open(URL(string: url)!)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                if model.mode == .voice, model.isPlaying {
                    Text(model.lastHeard.isEmpty ? "Listening… start reading" : "Heard: \(model.lastHeard)")
                        .font(.callout.monospaced())
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.black.opacity(0.6), in: Capsule())
                        .opacity(hudVisible ? 1 : 0.5)
                }
                PrompterHUD()
                    .opacity(hudVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.25), value: hudVisible)
            }
            .padding(.bottom, 20)
            .environment(\.colorScheme, .dark)
        }
        .onContinuousHover { _ in poke() }
        .onAppear { installKeys(); poke() }
        .onDisappear { removeKeys() }
        .onChange(of: model.isPlaying) { poke() }
    }

    private func poke() {
        hudVisible = true
        hideWork?.cancel()
        let work = DispatchWorkItem { if model.isPlaying { hudVisible = false } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command) { return event }
            switch event.keyCode {
            case 49: model.togglePlay()                                      // space
            case 53: model.stop()                                            // esc
            case 126: model.mode == .auto ? model.adjustSpeed(10) : model.nudge(-8)   // up
            case 125: model.mode == .auto ? model.adjustSpeed(-10) : model.nudge(8)   // down
            case 123: model.nudge(-1)                                        // left
            case 124: model.nudge(1)                                         // right
            default:
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "=", "+": model.adjustFont(4)
                case "-", "_": model.adjustFont(-4)
                case "r": model.restartFromTop()
                case "m": model.mirror.toggle()
                default: return event
                }
            }
            poke()
            return nil
        }
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

struct PrompterHUD: View {
    @EnvironmentObject var model: PrompterModel

    var body: some View {
        HStack(spacing: 14) {
            Button { model.stop() } label: { Image(systemName: "xmark") }
                .help("Back to editor (Esc)")

            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : (model.mode == .voice ? "mic.fill" : "play.fill"))
                    .frame(width: 18)
            }
            .help(model.mode == .voice ? "Start/stop listening (Space)" : "Play/pause (Space)")

            Picker("Mode", selection: $model.mode) {
                ForEach(ScrollMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)

            if model.mode == .auto {
                HStack(spacing: 6) {
                    Image(systemName: "tortoise")
                    Slider(value: $model.speed, in: 10...400).frame(width: 130)
                    Image(systemName: "hare")
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: model.isPlaying ? "mic.fill" : "mic.slash")
                        .foregroundStyle(model.isPlaying ? .green : .secondary)
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.15))
                        Capsule().fill(.green).frame(width: 90 * CGFloat(model.isPlaying ? model.micLevel : 0))
                    }
                    .frame(width: 90, height: 6)
                    .animation(.linear(duration: 0.08), value: model.micLevel)
                }
                .help(model.isPlaying ? "Listening" : "Not listening, press Space")
                MicPicker().frame(width: 170)
            }

            Divider().frame(height: 18)

            Button { model.adjustFont(-4) } label: { Image(systemName: "textformat.size.smaller") }
                .help("Smaller text (−)")
            Button { model.adjustFont(4) } label: { Image(systemName: "textformat.size.larger") }
                .help("Larger text (+)")
            Toggle(isOn: $model.mirror) {
                Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
            }
            .toggleStyle(.button)
            .help("Flip horizontal for teleprompter glass (M)")
            Button { model.restartFromTop() } label: { Image(systemName: "backward.end.fill") }
                .help("Back to the top (R)")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

struct MicPicker: View {
    @EnvironmentObject var model: PrompterModel

    var body: some View {
        Picker(selection: $model.inputDeviceUID) {
            Text(model.systemDefaultLabel).tag("")
            ForEach(model.inputDevices) { Text($0.name).tag($0.uid) }
            if !model.inputDeviceUID.isEmpty, !model.inputDevices.contains(where: { $0.uid == model.inputDeviceUID }) {
                Text("Unavailable device").tag(model.inputDeviceUID)
            }
        } label: {
            Image(systemName: "mic")
        }
        .help("Microphone used for Follow Voice")
        .onAppear { model.refreshDevices() }
    }
}
