# Teleprompter

A small native macOS teleprompter (SwiftUI, macOS 14+).

- **Follow Voice**: listens to your mic (Apple on-device speech recognition) and scrolls along as you read. Words you've read turn gray. If you go off-script it holds its place.
- **Auto Scroll**: steady scroll at an adjustable speed.
- **Paste & Start** (⇧⌘V): replaces the script with your clipboard and starts right away.

## Build & run

    ./build.sh run        # builds build/Teleprompter.app and opens it

Optional: `cp -R build/Teleprompter.app /Applications/`

On the first Follow Voice run, macOS asks for Microphone and Speech Recognition access.
Launch it with `open` or Finder rather than running the binary from Terminal, so the permissions belong to the app.

## Keys (while prompting)

| Key | Action |
|---|---|
| Space | Play/pause (Auto) · start/stop listening (Voice) |
| ↑ / ↓ | Speed ± (Auto) · jump back/forward ~a line (Voice) |
| ← / → | Move one word back/forward (Voice) |
| + / − | Text size |
| R | Back to top |
| M | Mirror (for beam-splitter glass) |
| Esc | Back to editor |

You can also scroll by hand with the trackpad. In Voice mode, wherever you stop becomes the new position.
"Keep on top" floats the window above other apps, which is handy over a video call.
