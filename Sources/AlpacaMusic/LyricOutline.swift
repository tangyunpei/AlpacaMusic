import AppKit
import CoreText
import SwiftUI

/// Normalized glyph geometry is cached independently of animated font size.
/// Outline echoes therefore do not shape text again on every animation frame.
@MainActor enum LyricOutline {
    private struct Key: Hashable { let text: String; let weight: CGFloat; let tracking: CGFloat }
    private static var cache: [Key: Path] = [:]
    private static var order: [Key] = []
    private static let referenceSize: CGFloat = 100

    static func path(text: String, weight: Font.Weight, tracking: CGFloat, fontSize: CGFloat) -> Path? {
        guard !text.isEmpty, fontSize.isFinite, fontSize > 0 else { return nil }
        let nsWeight: NSFont.Weight = switch weight {
        case .black: .black
        case .heavy: .heavy
        case .bold: .bold
        case .semibold: .semibold
        case .medium: .medium
        case .light: .light
        case .ultraLight: .ultraLight
        case .thin: .thin
        default: .regular
        }
        let normalizedTracking = (tracking / fontSize * referenceSize * 100).rounded() / 100
        let key = Key(text: text, weight: nsWeight.rawValue, tracking: normalizedTracking)
        let normalized: Path
        if let existing = cache[key] { normalized = existing }
        else {
            let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: referenceSize, weight: nsWeight), .kern: normalizedTracking])
            let line = CTLineCreateWithAttributedString(attributed)
            let result = CGMutablePath()
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let rawFont = attributes[kCTFontAttributeName] else { continue }
                let font = rawFont as! CTFont
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                for index in glyphs.indices {
                    if let glyph = CTFontCreatePathForGlyph(font, glyphs[index], nil) {
                        result.addPath(glyph, transform: CGAffineTransform(translationX: positions[index].x, y: positions[index].y))
                    }
                }
            }
            guard !result.isEmpty else { return nil }
            let bounds = result.boundingBoxOfPath
            var center = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -bounds.midX, ty: bounds.midY)
            guard let centered = result.copy(using: &center) else { return nil }
            normalized = Path(centered)
            if order.count >= 48 { cache.removeValue(forKey: order.removeFirst()) }
            order.append(key); cache[key] = normalized
        }
        return normalized.applying(CGAffineTransform(scaleX: fontSize / referenceSize, y: fontSize / referenceSize))
    }
}
