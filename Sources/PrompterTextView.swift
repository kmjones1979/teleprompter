import AppKit
import QuartzCore
import SwiftUI

/// Fraction of the view height where the reading line sits.
let readingLineFraction: CGFloat = 0.35

/// The scrolling text, backed by NSTextView so we can locate any word on screen.
struct PrompterTextView: NSViewRepresentable {
    @ObservedObject var model: PrompterModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> FlipContainer {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = true
        scroll.backgroundColor = .black
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = false
        tv.drawsBackground = true
        tv.backgroundColor = .black
        tv.textContainer?.lineFragmentPadding = 0
        context.coordinator.attach(scroll: scroll, textView: tv)
        let container = FlipContainer(content: scroll)
        container.mirrored = model.mirror
        return container
    }

    func updateNSView(_ nsView: FlipContainer, context: Context) {
        nsView.mirrored = model.mirror
        context.coordinator.update()
    }

    static func dismantleNSView(_ nsView: FlipContainer, coordinator: Coordinator) {
        coordinator.stopTimer()
    }

    final class Coordinator {
        let model: PrompterModel
        private weak var scroll: NSScrollView?
        private weak var textView: NSTextView?
        private var timer: Timer?

        private var pos: CGFloat = 0
        private var lastTick = CACurrentMediaTime()
        private var lastUserScroll: CFTimeInterval = 0
        private var builtScript: String?
        private var builtFont: Double = 0
        private var shownWord = -1
        private var shownMode: ScrollMode?
        private var seenReset = -1
        private var pendingReset = false
        private var pendingAnchorWord: Int?
        private var lastClipSize: NSSize = .zero

        init(model: PrompterModel) { self.model = model }

        func attach(scroll: NSScrollView, textView: NSTextView) {
            self.scroll = scroll
            self.textView = textView
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }

        func stopTimer() { timer?.invalidate(); timer = nil }

        private var readingOffset: CGFloat { (scroll?.contentView.bounds.height ?? 0) * readingLineFraction }

        func update() {
            guard let tv = textView else { return }
            if builtScript != model.script || builtFont != model.fontSize {
                let anchor = builtScript == model.script ? wordAtReadingLine() : nil
                rebuild(tv)
                if let anchor { pendingAnchorWord = model.mode == .voice ? model.currentWord : anchor }
            }
            if seenReset != model.resetToken {
                seenReset = model.resetToken
                pendingReset = true
            }
            if shownMode != model.mode {
                let previous = shownMode
                shownMode = model.mode
                shownWord = -1
                if previous != nil, model.mode == .voice {
                    let idx = wordAtReadingLine()
                    DispatchQueue.main.async { self.model.currentWord = idx }
                }
            }
            if shownWord != model.currentWord {
                shownWord = model.currentWord
                applyHighlight()
            }
        }

        private func rebuild(_ tv: NSTextView) {
            builtScript = model.script
            builtFont = model.fontSize
            let para = NSMutableParagraphStyle()
            para.lineSpacing = model.fontSize * 0.25
            para.paragraphSpacing = model.fontSize * 0.4
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: model.fontSize, weight: .semibold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: para,
            ]
            tv.textStorage?.setAttributedString(NSAttributedString(string: model.script, attributes: attrs))
            shownWord = -1
        }

        private func applyHighlight() {
            guard let ts = textView?.textStorage, ts.length > 0 else { return }
            let words = model.words
            ts.beginEditing()
            ts.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: 0, length: ts.length))
            if model.mode == .voice, model.currentWord > 0, !words.isEmpty {
                let end = model.currentWord < words.count ? words[model.currentWord].range.location : ts.length
                ts.addAttribute(.foregroundColor, value: NSColor(white: 0.42, alpha: 1),
                                range: NSRange(location: 0, length: min(end, ts.length)))
            }
            ts.endEditing()
        }

        private func tick() {
            guard let scroll, let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            let now = CACurrentMediaTime()
            let dt = CGFloat(min(0.1, now - lastTick))
            lastTick = now
            let clip = scroll.contentView
            let size = clip.bounds.size
            guard size.width > 0, size.height > 0 else { return }

            if size != lastClipSize {
                let anchor = lastClipSize == .zero ? nil : wordAtReadingLine()
                lastClipSize = size
                // Big top/bottom padding so the first and last lines can reach the reading line.
                tv.textContainerInset = NSSize(width: max(40, size.width * 0.08), height: size.height * (1 - readingLineFraction))
                lm.ensureLayout(for: tc)
                if let anchor, pendingAnchorWord == nil { pendingAnchorWord = anchor }
            }

            if pendingReset {
                pendingReset = false
                pendingAnchorWord = nil
                lm.ensureLayout(for: tc)
                jump(to: goal(forWord: 0) ?? 0)
            } else if let a = pendingAnchorWord {
                pendingAnchorWord = nil
                lm.ensureLayout(for: tc)
                if let g = goal(forWord: a) { jump(to: g) }
            }

            let maxY = max(0, tv.frame.height - size.height)
            let actual = clip.bounds.origin.y
            if abs(actual - pos) > 1.5 {
                // The user scrolled by hand.
                if model.mode == .voice { dlog("manual scroll detected: \(pos) -> \(actual)") }
                pos = actual
                lastUserScroll = now
                if model.mode == .voice {
                    let idx = wordAtReadingLine()
                    if idx != model.currentWord { model.currentWord = idx }
                }
            }

            var target = pos
            switch model.mode {
            case .auto:
                if model.isPlaying { target += CGFloat(model.speed) * dt }
            case .voice:
                if now - lastUserScroll > 1.2, let g = goal(forWord: model.currentWord) {
                    target += (g - pos) * min(1, dt * 5)
                }
            }
            target = min(max(0, target), maxY)
            if abs(target - pos) > 0.001 { set(target) }

            if model.mode == .auto, model.isPlaying, pos >= maxY - 0.5 {
                model.isPlaying = false
            }
        }

        private func jump(to y: CGFloat) {
            guard let scroll, let tv = textView else { return }
            let maxY = max(0, tv.frame.height - scroll.contentView.bounds.height)
            set(min(max(0, y), maxY))
        }

        private func set(_ y: CGFloat) {
            guard let scroll else { return }
            pos = y
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        /// Scroll offset that puts word `i` on the reading line.
        private func goal(forWord i: Int) -> CGFloat? {
            let words = model.words
            guard !words.isEmpty, let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
            let idx = min(max(0, i), words.count - 1)
            guard NSMaxRange(words[idx].range) <= (tv.textStorage?.length ?? 0) else { return nil }
            let gr = lm.glyphRange(forCharacterRange: words[idx].range, actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: gr, in: tc)
            let mid = rect.midY - CGFloat(model.fontSize) * 0.125 + tv.textContainerOrigin.y
            return mid - readingOffset
        }

        private func wordAtReadingLine() -> Int {
            let words = model.words
            guard !words.isEmpty, let scroll, let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer,
                  (tv.textStorage?.length ?? 0) > 0 else { return 0 }
            let y = scroll.contentView.bounds.origin.y + readingOffset - tv.textContainerOrigin.y
            let ci = lm.characterIndex(for: NSPoint(x: 0, y: max(0, y)), in: tc, fractionOfDistanceBetweenInsertionPoints: nil)
            var lo = 0, hi = words.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if NSMaxRange(words[mid].range) <= ci { lo = mid + 1 } else { hi = mid }
            }
            return min(lo, words.count - 1)
        }
    }
}

/// Hosts the scroll view and mirrors its rendering horizontally when `mirrored` is on.
final class FlipContainer: NSView {
    private let content: NSView
    var mirrored = false { didSet { if mirrored != oldValue { needsLayout = true } } }

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        content.frame = bounds
        guard let layer else { return }
        if mirrored {
            // Mirror around the layer's anchor point so content stays in place.
            var t = CATransform3DIdentity
            t.m11 = -1
            t.m41 = bounds.width - 2 * layer.anchorPoint.x * bounds.width
            layer.sublayerTransform = t
        } else {
            layer.sublayerTransform = CATransform3DIdentity
        }
    }
}
