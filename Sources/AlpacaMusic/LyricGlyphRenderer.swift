import AppKit
import CoreText
import SwiftUI

struct LyricGlyphSample: Equatable {
    var text: String
    var opacity: Double
    /// A small downward starting displacement, in the fragment's local points.
    var lift: CGFloat
}

/// Reveal masks are taken from one complete shaped line. A lyric never changes
/// its advance, ligature, bidi ordering, fallback font, or emoji cluster as the
/// sung prefix grows. The cached line is normalized so moving compositions do
/// not reshape a string every time their font size changes.
@MainActor enum LyricGlyphRenderer {
    private static let referenceSize: CGFloat = 100
    private struct Key: Hashable {
        var text: String
        var weight: CGFloat
        var tracking: CGFloat
    }
    private struct Shape {
        var line: CTLine
        var outline: CGPath
        var regions: [CGRect]
        var width: CGFloat
        var midpoint: CGFloat
    }
    private static var cache: [Key: Shape] = [:]
    private static var order: [Key] = []

    static func samples(for piece: LyricTypeFragment, position: Double) -> [LyricGlyphSample] {
        let characters = piece.text.map(String.init)
        guard piece.revealUnits.count == characters.count,
              zip(piece.revealUnits, characters).allSatisfy({ $0.0.text == $0.1 }) else {
            return characters.map { .init(text: $0, opacity: 1, lift: 0) }
        }
        return piece.revealUnits.map { unit in
            let opacity = unit.opacity(at: position, reduceMotion: piece.reduceRevealMotion)
            return .init(text: unit.text, opacity: opacity,
                         lift: piece.reduceRevealMotion ? 0 : piece.fontSize * 0.055 * CGFloat(1 - opacity))
        }
    }

    /// A geometry-only inspection hook used by temporal rendering QA. Bounds
    /// are already centered, and do not depend on playback position or reveals.
    static func regions(for piece: LyricTypeFragment) -> [CGRect] {
        guard let shape = shape(for: piece) else { return [] }
        let scale = piece.fontSize / referenceSize
        return shape.regions.map {
            CGRect(x: ($0.minX - shape.width / 2) * scale,
                   y: -($0.maxY - shape.midpoint) * scale,
                   width: $0.width * scale, height: $0.height * scale)
        }
    }

    static func draw(in context: inout GraphicsContext, piece: LyricTypeFragment,
                     position: Double, readingLevel: Double) {
        guard readingLevel.isFinite, readingLevel > 0,
              let shape = shape(for: piece) else { return }
        let samples = samples(for: piece, position: position)
        guard samples.count == shape.regions.count else { return }
        let scale = piece.fontSize / referenceSize
        let boost = piece.accent?.weightBoost ?? 0
        let strokeBoost = boost.isFinite ? max(0, min(1, boost)) : 0
        context.withCGContext { canvas in
            canvas.saveGState()
            canvas.scaleBy(x: scale, y: -scale)
            canvas.translateBy(x: -shape.width / 2, y: -shape.midpoint)
            canvas.textMatrix = .identity
            canvas.setFillColor(CGColor(gray: 1, alpha: 1))
            canvas.setStrokeColor(CGColor(gray: 1, alpha: 1))
            canvas.setLineJoin(.round)
            for index in samples.indices {
                let sample = samples[index], region = shape.regions[index]
                guard sample.opacity > 0, region.width > 0 else { continue }
                canvas.saveGState()
                canvas.setAlpha(CGFloat(sample.opacity * min(1, readingLevel)))
                canvas.translateBy(x: 0, y: -sample.lift / scale)
                canvas.clip(to: region)
                if piece.ink == .outline, !shape.outline.isEmpty {
                    canvas.addPath(shape.outline)
                    canvas.setLineWidth(max(0.65 / scale, 0.7))
                    canvas.strokePath()
                } else {
                    // CTLineDraw preserves shaped joining and color glyphs such
                    // as emoji. Only the clipping mask and alpha change.
                    canvas.textPosition = .zero
                    CTLineDraw(shape.line, canvas)
                    if strokeBoost > 0, !shape.outline.isEmpty {
                        canvas.addPath(shape.outline)
                        canvas.setLineWidth(CGFloat(strokeBoost) * 1.1)
                        canvas.strokePath()
                    }
                }
                canvas.restoreGState()
            }
            canvas.restoreGState()
        }
    }

    private static func shape(for piece: LyricTypeFragment) -> Shape? {
        guard !piece.text.isEmpty, piece.fontSize.isFinite, piece.fontSize > 0,
              piece.tracking.isFinite else { return nil }
        let weight = nsWeight(piece.weight)
        let tracking = (piece.tracking / piece.fontSize * referenceSize * 100).rounded() / 100
        let key = Key(text: piece.text, weight: weight.rawValue, tracking: tracking)
        if let cached = cache[key] { return cached }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: referenceSize, weight: weight),
            .kern: tracking,
            .foregroundColor: NSColor.white
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: piece.text, attributes: attributes))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        guard width.isFinite, ascent.isFinite, descent.isFinite else { return nil }
        let characters = piece.text.map(String.init)
        var offset = 0
        let ranges: [Range<Int>] = characters.map { text in
            defer { offset += text.utf16.count }
            return offset..<(offset + text.utf16.count)
        }
        var spans = Array(repeating: CGRect.null, count: characters.count)
        let outline = CGMutablePath()
        let rawBounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        let lineBounds = rawBounds.isNull || rawBounds.isInfinite
            ? CGRect(x: 0, y: -descent, width: width, height: ascent + descent) : rawBounds
        // Tall masks include combining marks and color glyphs without cropping.
        let lower = min(-descent, lineBounds.minY) - referenceSize * 0.12
        let upper = max(ascent, lineBounds.maxY) + referenceSize * 0.12
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let rawAttributes = CTRunGetAttributes(run) as NSDictionary
            guard let rawFont = rawAttributes[kCTFontAttributeName] else { continue }
            let font = rawFont as! CTFont
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
            let runRange = CTRunGetStringRange(run)
            let boundaries = Array(Set(indices + [runRange.location + runRange.length])).sorted()
            let rtl = CTRunGetStatus(run).contains(.rightToLeft)
            for glyphIndex in glyphs.indices {
                let origin = positions[glyphIndex]
                if let path = CTFontCreatePathForGlyph(font, glyphs[glyphIndex], nil) {
                    outline.addPath(path, transform: CGAffineTransform(translationX: origin.x, y: origin.y))
                }
                let start = indices[glyphIndex]
                let end = boundaries.first(where: { $0 > start }) ?? start + 1
                let owners = ranges.indices.filter { ranges[$0].lowerBound < end && ranges[$0].upperBound > start }
                guard !owners.isEmpty else { continue }
                let advance = abs(advances[glyphIndex].width)
                // Joining and ligatures remain shaped as a whole. A ligature's
                // advance is split into masks, rather than replacing it with
                // separately shaped letters or exposing its future characters.
                for (ordinal, owner) in owners.enumerated() {
                    let visual = rtl ? owners.count - ordinal - 1 : ordinal
                    let slice = advance / CGFloat(owners.count)
                    let x = min(origin.x, origin.x + advances[glyphIndex].width) + CGFloat(visual) * slice
                    if slice > 0 {
                        let rect = CGRect(x: x, y: lower, width: slice, height: upper - lower)
                        spans[owner] = spans[owner].union(rect)
                    }
                }
            }
        }
        // Preserve outer overhangs (e.g. a leaning first letter), while internal
        // boundaries remain disjoint so an unrevealed neighbor cannot leak.
        if let first = spans.indices.filter({ !spans[$0].isNull }).min(by: { spans[$0].minX < spans[$1].minX }),
           lineBounds.minX < spans[first].minX {
            let right = spans[first].maxX
            spans[first].origin.x = lineBounds.minX - 1
            spans[first].size.width = right - spans[first].minX
        }
        if let last = spans.indices.filter({ !spans[$0].isNull }).max(by: { spans[$0].maxX < spans[$1].maxX }),
           lineBounds.maxX > spans[last].maxX {
            spans[last].size.width = lineBounds.maxX - spans[last].minX + 1
        }
        // Non-rendering controls can have no glyph at all; they still retain a
        // timeline entry without contributing a drawing mask.
        spans = spans.map { $0.isNull ? .zero : $0 }
        let result = Shape(line: line, outline: outline, regions: spans,
                           width: width, midpoint: (ascent - descent) / 2)
        if order.count >= 96 { cache.removeValue(forKey: order.removeFirst()) }
        order.append(key); cache[key] = result
        return result
    }

    private static func nsWeight(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
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
    }
}
