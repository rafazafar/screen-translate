import AppKit
import ScreenCaptureKit
import Vision
import Translation
import NaturalLanguage

struct ScreenInfo {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let scale: CGFloat

    init?(_ screen: NSScreen) {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
        displayID = id
        frame = screen.frame
        scale = screen.backingScaleFactor
    }
}

/// One translated paragraph, positioned in screen-local points (origin bottom-left).
struct RenderBlock {
    var rect: CGRect
    var text: String
    var lines: Int
    var lineHeight: CGFloat
    var bg: NSColor
    var fg: NSColor
}

enum PipelineError: LocalizedError {
    case noDisplay
    case unsupportedPair(String, String)
    case languagesNotInstalled

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "Couldn't find the display to capture."
        case let .unsupportedPair(s, t): return "Apple Translation doesn't support \(s) → \(t)."
        case .languagesNotInstalled: return "The translation languages aren't downloaded yet."
        }
    }
}

enum Pipeline {
    // MARK: Capture

    static func capture(_ info: ScreenInfo) async throws -> CGImage {
        try await capture(makeFilter(info))
    }

    /// A filter for one display, leaving out the given windows (our own overlays).
    static func makeFilter(_ info: ScreenInfo, excluding windowIDs: [CGWindowID] = []) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: windowIDs.isEmpty)
        guard let display = content.displays.first(where: { $0.displayID == info.displayID }) else {
            throw PipelineError.noDisplay
        }
        let excluded = content.windows.filter { windowIDs.contains($0.windowID) }
        return SCContentFilter(display: display, excludingWindows: excluded)
    }

    /// Full-resolution capture, or a small one `width` pixels wide for change detection.
    static func capture(_ filter: SCContentFilter, width: Int? = nil) async throws -> CGImage {
        let config = SCStreamConfiguration()
        let rect = filter.contentRect
        if let width {
            config.width = width
            config.height = max(1, Int(CGFloat(width) * rect.height / rect.width))
        } else {
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(rect.width * scale)
            config.height = Int(rect.height * scale)
        }
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    // MARK: Translation session

    static func makeSession(source: Language, target: Language) async throws -> TranslationSession {
        let src = Locale.Language(identifier: source.code)
        let tgt = Locale.Language(identifier: target.code)
        switch await LanguageAvailability().status(from: src, to: tgt) {
        case .installed: break
        case .supported: throw PipelineError.languagesNotInstalled
        default: throw PipelineError.unsupportedPair(source.name, target.name)
        }
        return TranslationSession(installedSource: src, target: tgt)
    }

    // MARK: Pipeline

    static func process(image: CGImage, pointSize: CGSize, source: Language, target: Language,
                        session: TranslationSession, cache: TranslationCache? = nil) async throws -> [RenderBlock] {
        let lines = try recognize(image, languages: source.visionCodes + ["en-US"])
        let size = CGSize(width: image.width, height: image.height)
        let joiner = ["ja", "zh-Hans", "zh-Hant"].contains(source.code) ? "" : " "
        let groups = group(lines, imageSize: size, joiner: joiner)
            .filter { needsTranslation($0.text, source: source, target: target) }
        guard !groups.isEmpty else { return [] }

        // Only send text the cache hasn't seen; in live mode most of the screen repeats.
        var translated: [Int: String] = [:]
        var requests: [TranslationSession.Request] = []
        for (i, g) in groups.enumerated() {
            if let hit = cache?[g.text] {
                translated[i] = hit
            } else {
                requests.append(TranslationSession.Request(sourceText: g.text, clientIdentifier: String(i)))
            }
        }
        if !requests.isEmpty {
            for r in try await session.translations(from: requests) {
                guard let id = r.clientIdentifier, let i = Int(id) else { continue }
                translated[i] = r.targetText
                cache?[groups[i].text] = r.targetText
            }
        }

        let sampler = PixelSampler(image)
        let sx = pointSize.width / size.width
        let sy = pointSize.height / size.height

        return groups.enumerated().compactMap { index, g in
            guard let text = translated[index], !text.isEmpty else { return nil }
            let (bg, fg) = sampler.colors(for: g.rect)
            return RenderBlock(
                rect: CGRect(x: g.rect.minX * sx, y: g.rect.minY * sy, width: g.rect.width * sx, height: g.rect.height * sy),
                text: text,
                lines: g.lineHeights.count,
                lineHeight: g.lineHeights.reduce(0, +) / CGFloat(g.lineHeights.count) * sy,
                bg: bg, fg: fg
            )
        }
    }

    // MARK: OCR

    private static func recognize(_ image: CGImage, languages: [String]) throws -> [(String, CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let usable = languages.filter { supported.contains($0) }
        if !usable.isEmpty { request.recognitionLanguages = usable }

        try VNImageRequestHandler(cgImage: image).perform([request])
        let w = CGFloat(image.width), h = CGFloat(image.height)
        return (request.results ?? []).compactMap { obs in
            guard let top = obs.topCandidates(1).first else { return nil }
            let b = obs.boundingBox  // normalized, origin bottom-left
            return (top.string, CGRect(x: b.minX * w, y: b.minY * h, width: b.width * w, height: b.height * h))
        }
    }

    // MARK: Grouping lines into paragraphs

    struct Group {
        var text: String
        var rect: CGRect              // pixels, origin bottom-left
        var lineHeights: [CGFloat]
        var last: CGRect
    }

    private static func group(_ lines: [(String, CGRect)], imageSize: CGSize, joiner: String) -> [Group] {
        var groups: [Group] = []
        for (text, rect) in lines.sorted(by: { $0.1.maxY != $1.1.maxY ? $0.1.maxY > $1.1.maxY : $0.1.minX < $1.1.minX }) {
            var best: (index: Int, gap: CGFloat)?
            for (i, g) in groups.enumerated() {
                let p = g.last
                let h = max(p.height, rect.height)
                guard min(p.height, rect.height) / h >= 0.7 else { continue }
                let gap = p.minY - rect.maxY
                guard gap >= -0.5 * h, gap <= 0.4 * h else { continue }
                let leftAligned = abs(p.minX - rect.minX) < 1.5 * h
                let centered = abs(p.midX - rect.midX) < 1.5 * h
                guard leftAligned || centered, p.maxX > rect.minX, rect.maxX > p.minX else { continue }
                if best == nil || gap < best!.gap { best = (i, gap) }
            }
            if let (i, _) = best {
                groups[i].text += joiner + text
                groups[i].rect = groups[i].rect.union(rect)
                groups[i].lineHeights.append(rect.height)
                groups[i].last = rect
            } else {
                groups.append(Group(text: text, rect: rect, lineHeights: [rect.height], last: rect))
            }
        }
        return groups
    }

    // MARK: Filtering

    private static func needsTranslation(_ text: String, source: Language, target: Language) -> Bool {
        let scalars = text.unicodeScalars
        func has(_ ranges: [ClosedRange<UInt32>]) -> Bool {
            scalars.contains { s in ranges.contains { $0.contains(s.value) } }
        }
        switch source.code {
        case "ja": return has([0x3040...0x30FF, 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xFF66...0xFF9F])
        case "zh-Hans", "zh-Hant": return has([0x4E00...0x9FFF, 0x3400...0x4DBF])
        case "ko": return has([0xAC00...0xD7A3, 0x1100...0x11FF])
        default:
            guard scalars.contains(where: { CharacterSet.letters.contains($0) }) else { return false }
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            if let dominant = recognizer.dominantLanguage,
               dominant.rawValue.hasPrefix(String(target.code.prefix(2))),
               (recognizer.languageHypotheses(withMaximum: 1)[dominant] ?? 0) > 0.7 {
                return false
            }
            return true
        }
    }
}

// MARK: - Colour sampling

/// Reads pixels from the capture so the overlay can match the original background and text colour.
final class PixelSampler {
    private let width: Int
    private let height: Int
    private var data: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        data = [UInt8](repeating: 0, count: width * height * 4)
        let w = width, h = height
        data.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    /// x, y in pixels with origin bottom-left.
    private func pixel(_ x: Int, _ y: Int) -> (CGFloat, CGFloat, CGFloat) {
        let cx = min(max(x, 0), width - 1)
        let row = height - 1 - min(max(y, 0), height - 1)
        let i = (row * width + cx) * 4
        return (CGFloat(data[i]) / 255, CGFloat(data[i + 1]) / 255, CGFloat(data[i + 2]) / 255)
    }

    private func luminance(_ c: (CGFloat, CGFloat, CGFloat)) -> CGFloat {
        0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2
    }

    func colors(for rect: CGRect) -> (bg: NSColor, fg: NSColor) {
        // Background: median of samples on a ring just outside the text.
        let r = rect.insetBy(dx: -3, dy: -3)
        var ring: [(CGFloat, CGFloat, CGFloat)] = []
        let steps = 12
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = Int(r.minX + t * r.width), y = Int(r.minY + t * r.height)
            ring.append(pixel(x, Int(r.minY))); ring.append(pixel(x, Int(r.maxY)))
            ring.append(pixel(Int(r.minX), y)); ring.append(pixel(Int(r.maxX), y))
        }
        func median(_ values: [CGFloat]) -> CGFloat { values.sorted()[values.count / 2] }
        let bg = (median(ring.map { $0.0 }), median(ring.map { $0.1 }), median(ring.map { $0.2 }))

        // Foreground: the sampled pixel inside the text that differs most from the background.
        var fg = bg
        var bestDistance: CGFloat = 0
        let cols = 24, rows = 6
        for ix in 0..<cols {
            for iy in 0..<rows {
                let p = pixel(Int(rect.minX + (CGFloat(ix) + 0.5) / CGFloat(cols) * rect.width),
                              Int(rect.minY + (CGFloat(iy) + 0.5) / CGFloat(rows) * rect.height))
                let d = abs(p.0 - bg.0) + abs(p.1 - bg.1) + abs(p.2 - bg.2)
                if d > bestDistance { bestDistance = d; fg = p }
            }
        }
        if abs(luminance(fg) - luminance(bg)) < 0.3 {
            fg = luminance(bg) > 0.5 ? (0.1, 0.1, 0.1) : (0.95, 0.95, 0.95)
        }
        return (NSColor(srgbRed: bg.0, green: bg.1, blue: bg.2, alpha: 1),
                NSColor(srgbRed: fg.0, green: fg.1, blue: fg.2, alpha: 1))
    }
}
