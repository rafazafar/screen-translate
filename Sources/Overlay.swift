import AppKit

/// A paragraph with its font size and rectangles already worked out.
private struct Layout {
    let fill: CGRect
    let textRect: CGRect
    let text: NSAttributedString
    let bg: NSColor

    static func make(_ block: RenderBlock, maxX: CGFloat) -> Layout {
        let minSize: CGFloat = 9
        let startSize = min(max(block.lineHeight * 0.8, minSize), 44)
        let limit = block.rect.height * 1.08 + 1

        func attributed(_ s: CGFloat) -> NSAttributedString {
            NSAttributedString(string: block.text, attributes: [
                .font: NSFont.systemFont(ofSize: s),
                .foregroundColor: block.fg,
            ])
        }
        func measure(_ a: NSAttributedString, _ width: CGFloat) -> CGSize {
            let r = a.boundingRect(with: CGSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin])
            return CGSize(width: ceil(r.width) + 1, height: ceil(r.height))
        }
        /// Shrinks from the start size until the text fits the box height at this width.
        func attempt(width: CGFloat, floor: CGFloat) -> (NSAttributedString, CGSize)? {
            var s = startSize
            while true {
                let a = attributed(s)
                let m = measure(a, width)
                if m.height <= limit { return (a, m) }
                if s <= floor { return nil }
                s = max(floor, s - 0.5)
            }
        }

        let fitted: (NSAttributedString, CGSize)
        if block.lines == 1 {
            // English is usually wider than Japanese: shrink a little first, then let it grow to the right.
            let growWidth = max(block.rect.width, min(block.rect.width * 1.8 + 24, maxX - block.rect.minX - 4))
            fitted = attempt(width: block.rect.width, floor: max(minSize, startSize * 0.7))
                ?? attempt(width: growWidth, floor: minSize)
                ?? { let a = attributed(minSize); return (a, measure(a, growWidth)) }()
        } else {
            fitted = attempt(width: block.rect.width, floor: minSize)
                ?? { let a = attributed(minSize); return (a, measure(a, block.rect.width)) }()
        }

        let (text, measured) = fitted
        let y = block.lines == 1
            ? block.rect.midY - measured.height / 2
            : block.rect.maxY - measured.height
        let textRect = CGRect(x: block.rect.minX, y: y, width: measured.width, height: measured.height)
        return Layout(fill: block.rect.union(textRect).insetBy(dx: -3, dy: -2), textRect: textRect, text: text, bg: block.bg)
    }
}

final class OverlayView: NSView {
    private var layouts: [Layout]
    private let backdrop: CGImage?
    var onDismiss: (() -> Void)?

    init(size: CGSize, blocks: [RenderBlock], backdrop: CGImage? = nil) {
        layouts = blocks.map { Layout.make($0, maxX: size.width) }
        self.backdrop = backdrop
        super.init(frame: CGRect(origin: .zero, size: size))
    }

    func setBlocks(_ blocks: [RenderBlock]) {
        layouts = blocks.map { Layout.make($0, maxX: bounds.width) }
        needsDisplay = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if let backdrop { NSGraphicsContext.current?.cgContext.draw(backdrop, in: bounds) }
        for layout in layouts {
            layout.bg.setFill()
            NSBezierPath(roundedRect: layout.fill, xRadius: 3, yRadius: 3).fill()
            layout.text.draw(with: layout.textRect, options: [.usesLineFragmentOrigin])
        }
    }

    override func mouseDown(with event: NSEvent) { onDismiss?() }
    override func rightMouseDown(with event: NSEvent) { onDismiss?() }
    override func scrollWheel(with event: NSEvent) { onDismiss?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDismiss?() }  // Esc
    }
}

/// Borderless, transparent panel covering one screen. It is non-activating so showing it never
/// makes this app frontmost, which would make macOS rearrange the user's windows or Spaces.
final class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private let clickThrough: Bool

    /// With `clickThrough` the overlay ignores the mouse so the app underneath stays usable (live mode).
    init(screenFrame: CGRect, blocks: [RenderBlock], clickThrough: Bool = false, onDismiss: @escaping () -> Void) {
        self.clickThrough = clickThrough
        super.init(contentRect: screenFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        ignoresMouseEvents = clickThrough
        isFloatingPanel = true
        hidesOnDeactivate = false
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = OverlayView(size: screenFrame.size, blocks: blocks)
        view.onDismiss = onDismiss
        contentView = view
        setFrame(screenFrame, display: true)
    }

    func present() {
        orderFrontRegardless()
        guard !clickThrough else { return }  // keep keyboard focus in the app underneath
        makeKey()
        makeFirstResponder(contentView)
    }

    func setBlocks(_ blocks: [RenderBlock]) {
        (contentView as? OverlayView)?.setBlocks(blocks)
    }

    /// Hides instantly (stale text over moving content looks broken) and fades back in.
    func setContentVisible(_ visible: Bool) {
        if visible {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().alphaValue = 1 }
        } else {
            alphaValue = 0
        }
    }
}

/// Brief floating message, for "nothing found" style feedback.
enum Toast {
    private static var window: NSWindow?

    /// So live mode can leave the toast out of its captures.
    static var windowID: CGWindowID? { window.map { CGWindowID($0.windowNumber) } }

    static func show(_ message: String) {
        window?.close()
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        label.sizeToFit()
        let size = CGSize(width: label.frame.width + 40, height: label.frame.height + 24)

        let w = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .screenSaver
        w.isOpaque = false
        w.backgroundColor = NSColor.black.withAlphaComponent(0.8)
        w.hasShadow = true
        w.isReleasedWhenClosed = false
        w.ignoresMouseEvents = true
        w.contentView?.wantsLayer = true
        w.contentView?.layer?.cornerRadius = 10
        label.frame.origin = CGPoint(x: 20, y: 12)
        w.contentView?.addSubview(label)
        if let screen = NSScreen.main {
            w.setFrameOrigin(CGPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - 140))
        }
        w.orderFrontRegardless()
        window = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if window === w { w.close(); window = nil }
        }
    }
}
