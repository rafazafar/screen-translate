import AppKit
import ScreenCaptureKit
import Translation

/// Source text → translation, kept for a live session so repeated text is instant.
final class TranslationCache {
    private var entries: [String: String] = [:]

    subscript(text: String) -> String? {
        get { entries[text] }
        set {
            if entries.count > 2000 { entries.removeAll() }
            entries[text] = newValue
        }
    }
}

/// Tiny grayscale thumbnail of the screen, used to notice scrolling and other changes cheaply.
struct Fingerprint {
    private static let width = 160
    private static let height = 100
    private let pixels: [UInt8]

    init(_ image: CGImage) {
        let w = Self.width, h = Self.height
        var px = [UInt8](repeating: 0, count: w * h)
        px.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        pixels = px
    }

    /// Share of thumbnail pixels that changed noticeably. A blinking caret stays far below the threshold.
    func changedFraction(from other: Fingerprint) -> Double {
        var changed = 0
        for i in pixels.indices where abs(Int(pixels[i]) - Int(other.pixels[i])) > 20 { changed += 1 }
        return Double(changed) / Double(pixels.count)
    }
}

/// Keeps a click-through overlay on every screen and re-translates whenever the content underneath
/// changes and then settles (scrolling, switching tabs, new windows).
@MainActor
final class LiveTranslator {
    private final class Screen {
        let info: ScreenInfo
        let window: OverlayWindow
        var filter: SCContentFilter?
        var last: Fingerprint?
        var lastMotion = Date.distantPast
        var dirty = true

        init(info: ScreenInfo, window: OverlayWindow) {
            self.info = info
            self.window = window
        }
    }

    private static let interval: Duration = .milliseconds(300)
    private static let settleTime: TimeInterval = 0.35
    private static let motionThreshold = 0.004
    private static let thumbnailWidth = 320

    private let source: Language
    private let target: Language
    private let session: TranslationSession
    private let cache = TranslationCache()
    private var screens: [Screen] = []
    private var loop: Task<Void, Never>?

    init(source: Language, target: Language, session: TranslationSession) {
        self.source = source
        self.target = target
        self.session = session
    }

    func start(infos: [ScreenInfo]) async throws {
        for info in infos {
            let window = OverlayWindow(screenFrame: info.frame, blocks: [], clickThrough: true) {}
            window.present()
            screens.append(Screen(info: info, window: window))
        }
        // Our own overlays (and any toast) must stay out of the captures, or they'd trigger themselves.
        let ownWindows = screens.map { CGWindowID($0.window.windowNumber) } + [Toast.windowID].compactMap { $0 }
        for screen in screens {
            screen.filter = try await Pipeline.makeFilter(screen.info, excluding: ownWindows)
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        screens.forEach { $0.window.close() }
        screens.removeAll()
    }

    private func tick() async {
        for screen in screens {
            guard loop != nil, let filter = screen.filter,
                  let thumb = try? await Pipeline.capture(filter, width: Self.thumbnailWidth) else { continue }
            let print = Fingerprint(thumb)
            if let last = screen.last, print.changedFraction(from: last) > Self.motionThreshold {
                screen.lastMotion = Date()
                screen.dirty = true
                screen.window.setContentVisible(false)
            }
            screen.last = print

            if screen.dirty && Date().timeIntervalSince(screen.lastMotion) >= Self.settleTime {
                await retranslate(screen, filter: filter, before: print)
            }
        }
    }

    private func retranslate(_ screen: Screen, filter: SCContentFilter, before: Fingerprint) async {
        screen.dirty = false
        do {
            let image = try await Pipeline.capture(filter)
            let blocks = try await Pipeline.process(image: image, pointSize: screen.info.frame.size,
                                                    source: source, target: target, session: session, cache: cache)
            guard loop != nil else { return }

            // If the screen moved while we were working, these positions are already stale.
            let after = Fingerprint(try await Pipeline.capture(filter, width: Self.thumbnailWidth))
            if after.changedFraction(from: before) > Self.motionThreshold {
                screen.last = after
                screen.lastMotion = Date()
                screen.dirty = true
                return
            }
            screen.window.setBlocks(blocks)
            screen.window.setContentVisible(true)
        } catch {
            screen.dirty = true  // try again on the next quiet tick
        }
    }
}
