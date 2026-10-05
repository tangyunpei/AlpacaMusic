import AppKit
import SwiftUI

/// A gesture is a few strokes around the moving word, rather than a static
/// badge. Geometry and opacity are reconstructed from the supplied event state.
struct LyricGestureLayer {
    var path: Path
    var opacity: Double
    var lineWidth: CGFloat
}

@MainActor enum LyricAccentRenderer {
    static func font(for piece: LyricTypeFragment) -> Font {
        let base: NSFont.Weight = switch piece.weight {
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
        let amount = piece.accent?.weightBoost ?? 0
        guard amount.isFinite, amount > 0 else { return .system(size: piece.fontSize, weight: piece.weight) }
        let target = max(base.rawValue, NSFont.Weight.heavy.rawValue)
        let interpolated = NSFont.Weight(rawValue: base.rawValue + (target - base.rawValue) * CGFloat(min(1, amount)))
        return Font(NSFont.systemFont(ofSize: piece.fontSize, weight: interpolated))
    }

    /// Glyph sizes remain natural sizes. The canvas applies the word's scale
    /// once to both glyph and marks; these bounds are in that same local space.
    static func markBounds(for piece: LyricTypeFragment, kind: LyricAccentKind? = nil) -> CGRect {
        guard usable(piece) else { return .zero }
        let base = gestureRect(for: piece)
        let reach = min(10, piece.fontSize * 0.12) + padding(for: piece) * 0.95
        let expanded = base.insetBy(dx: -reach, dy: -reach)
        let tilted = tiltEnvelope(expanded.size, degrees: 5)
        // The triangular flourish lives above a word's outer corner. Reserve
        // both mirrored positions and its complete approach/recoil, even when
        // preflight is sampling a fragment before any event has begun.
        let span = triangleSpan(for: piece)
        let triangleWidth = piece.size.width + span * 1.5
        let triangleHeight = piece.size.height + padding(for: piece) * 4 + span * 2.24
        let selected = kind ?? piece.accent?.kind
        let includesTriangle = selected == nil || selected == .triangle
        let reserved = includesTriangle
            ? CGSize(width: max(tilted.width, triangleWidth), height: max(tilted.height, triangleHeight))
            : tilted
        let strokeMargin = max(1.5, strokeWidth(for: piece) * 0.9)
        return CGRect(x: -reserved.width / 2, y: -reserved.height / 2,
                      width: reserved.width, height: reserved.height).insetBy(dx: -strokeMargin, dy: -strokeMargin)
    }

    /// On a base fragment this reserves the complete accent motion. On a
    /// fragment already carrying a sampled accent, center/rotation have already
    /// moved: use the actual axis scales without reserving movement twice.
    static func maximumWorldBounds(for piece: LyricTypeFragment, kind: LyricAccentKind? = nil) -> CGRect {
        worldEnvelope(markBounds(for: piece, kind: kind), for: piece)
    }

    static func maximumGlyphWorldBounds(for piece: LyricTypeFragment) -> CGRect {
        guard usable(piece) else { return .zero }
        return worldEnvelope(CGRect(x: -piece.size.width / 2, y: -piece.size.height / 2,
                                    width: piece.size.width, height: piece.size.height), for: piece)
    }

    static func drawMark(in context: inout GraphicsContext, piece: LyricTypeFragment, accent: LyricAccentState) {
        for stroke in markLayers(for: piece, accent: accent) {
            var layer = context
            layer.opacity *= stroke.opacity
            layer.stroke(stroke.path, with: .color(.white),
                         style: StrokeStyle(lineWidth: stroke.lineWidth, lineCap: .round, lineJoin: .round))
        }
    }

    /// Exposed to geometry QA. There is no per-frame path cache and no glyph
    /// flashing: even a luminous strike only changes these decorative strokes.
    static func markLayers(for piece: LyricTypeFragment, accent: LyricAccentState) -> [LyricGestureLayer] {
        guard usable(piece), accent.intensity.isFinite, accent.progress.isFinite, accent.trail.isFinite,
              accent.intensity > 0 else { return [] }
        // Lift the ink's contrast without lengthening the event or brightening
        // the lyric itself. Zero remains zero, and the core still owns release.
        let strength = pow(clamp(accent.intensity), 0.64), progress = clamp(accent.progress), trail = clamp(accent.trail)
        let rect = gestureRect(for: piece), width = strokeWidth(for: piece)
        let direction: CGFloat = (piece.id & 1) == 0 ? 1 : -1
        let flourish = CGFloat(sin(progress * .pi))
        let tilt = direction * (CGFloat(-4.5 + 8.9 * progress) + flourish * 0.75)
        let rotation = CGAffineTransform(rotationAngle: tilt * .pi / 180)
        func layer(_ path: Path, opacity: Double, width multiplier: CGFloat = 1, rotate: Bool = true) -> LyricGestureLayer {
            .init(path: rotate ? path.applying(rotation) : path, opacity: clamp(opacity) * strength, lineWidth: width * multiplier)
        }
        switch accent.kind {
        case .ring:
            // Write the complete oval first. Its open notch remains readable
            // through presentation; only the exit clock may erase the stroke.
            let oval = handOval(in: rect, bend: direction * (0.065 + flourish * 0.075))
            let head = min(0.985, 0.05 + progress * 0.93)
            let tail = min(head, 0.015 + trail * 0.965)
            let ink = oval.trimmedPath(from: tail, to: head)
            return [layer(ink, opacity: 0.98 * (1 - trail))]
        case .box:
            // Opposite brackets finish their approach and both arms before
            // holding. The exit retreats and removes ink in one direction.
            let approach = CGFloat(1 - smooth(min(1, progress / 0.64)))
            let overshoot = flourish * min(5, piece.fontSize * 0.05)
            let retreat = CGFloat(trail) * padding(for: piece) * 0.45
            let displacement = padding(for: piece) * 0.72 * approach - overshoot + retreat
            let cornerRect = rect.insetBy(dx: -displacement, dy: -displacement * 0.8)
            let horizontal = cornerRect.width * 0.49
            let vertical = cornerRect.height * 0.65
            var top = Path(), bottom = Path()
            top.move(to: CGPoint(x: cornerRect.minX, y: cornerRect.minY + vertical))
            top.addQuadCurve(to: CGPoint(x: cornerRect.minX + 0.9, y: cornerRect.minY),
                             control: CGPoint(x: cornerRect.minX - 0.7, y: cornerRect.minY + 0.8))
            top.addLine(to: CGPoint(x: cornerRect.minX + horizontal, y: cornerRect.minY + 0.6))
            bottom.move(to: CGPoint(x: cornerRect.maxX, y: cornerRect.maxY - vertical))
            bottom.addQuadCurve(to: CGPoint(x: cornerRect.maxX - 0.6, y: cornerRect.maxY),
                                control: CGPoint(x: cornerRect.maxX + 0.6, y: cornerRect.maxY - 0.9))
            bottom.addLine(to: CGPoint(x: cornerRect.maxX - horizontal, y: cornerRect.maxY - 0.4))
            let head = 0.04 + progress * 0.96
            let tail = min(head, trail)
            return [layer(top.trimmedPath(from: tail, to: head), opacity: 0.98 * (1 - trail)),
                    layer(bottom.trimmedPath(from: tail, to: head), opacity: 0.92 * (1 - trail), width: 0.96)]
        case .triangle:
            // An asymmetric, nearly closed triangle writes itself above the
            // word's outer corner. Its three sides stay outside the glyphs;
            // this is a pen flourish, never a plate or a line through a letter.
            let span = triangleSpan(for: piece)
            let approach = CGFloat(1 - smooth(min(1, progress / 0.62))) * padding(for: piece) * 0.65
            let recoil = flourish * min(5, piece.fontSize * 0.045)
            let retreat = CGFloat(trail) * padding(for: piece) * 0.30
            let anchor = CGPoint(x: direction * (piece.size.width / 2 - span * 0.22),
                                 y: -piece.size.height / 2 - padding(for: piece) - span * 0.10 - approach + recoil - retreat)
            let twist = direction * CGFloat(-3 + 6 * progress) * .pi / 180
            var wedge = Path()
            wedge.move(to: CGPoint(x: direction * -span * 0.60, y: 0))
            wedge.addLine(to: CGPoint(x: direction * span * 0.04, y: -span * 0.86))
            wedge.addLine(to: CGPoint(x: direction * span * 0.70, y: -span * 0.08))
            wedge.addLine(to: CGPoint(x: direction * -span * 0.60, y: 0))
            let head = min(0.988, 0.08 + progress * 0.91)
            // Three complete edges survive the presentation phase. The tail
            // advances once on exit, with no rebound that redraws old ink.
            let tail = min(head, 0.008 + trail * 0.980)
            let ink = wedge.trimmedPath(from: tail, to: head)
                .applying(CGAffineTransform(rotationAngle: twist))
                .applying(CGAffineTransform(translationX: anchor.x, y: anchor.y))
            return [layer(ink, opacity: 0.99 * (1 - trail), rotate: false)]
        case .flash:
            // A narrow pen streak sweeps along the lower edge. The wider faint
            // stroke is local luminous ink, never a filled tile over the word.
            let travel = CGFloat(progress), reach = rect.width * 0.38
            let center = rect.minX + rect.width * travel
            let left = max(rect.minX, center - reach * 0.55)
            let right = min(rect.maxX, center + reach * 0.45)
            let y = rect.maxY - 1.5 - flourish * min(3, piece.fontSize * 0.035)
            var streak = Path()
            streak.move(to: CGPoint(x: left, y: y + direction * 0.7))
            streak.addQuadCurve(to: CGPoint(x: right, y: y - direction * 0.7),
                                control: CGPoint(x: (left + right) / 2, y: y - 1.0))
            let ink = streak.trimmedPath(from: trail, to: 1)
            return [layer(ink, opacity: 0.20 * (1 - trail), width: 1.7),
                    layer(ink, opacity: 0.99 * (1 - trail), width: 0.90)]
        case .weight:
            // The smooth single font carries the emphasis. A fleeting taper
            // below it provides a small visual afterstroke rather than a badge.
            let draw = smooth(min(1, progress / 0.62))
            let length = rect.width * CGFloat(0.20 + draw * 0.30)
            let center = rect.midX + direction * rect.width * CGFloat(progress - 0.5) * 0.12
            var underline = Path()
            underline.move(to: CGPoint(x: center - length / 2, y: rect.maxY - 0.4))
            underline.addQuadCurve(to: CGPoint(x: center + length / 2, y: rect.maxY - 1.0),
                                   control: CGPoint(x: center, y: rect.maxY - 2.2 - flourish))
            return [layer(underline.trimmedPath(from: trail, to: 1), opacity: 0.48 * (1 - trail) * draw, width: 0.90)]
        case .pulse:
            // The expanding arc writes once, holds its completed contour,
            // then dissolves from the original tail toward the final head.
            let spread = CGFloat(progress) * min(10, piece.fontSize * 0.12)
            let arc = handOval(in: rect.insetBy(dx: -spread, dy: -spread), bend: -direction * 0.05)
            let end = 0.03 + progress * 0.88
            let start = min(end, 0.03 + trail * 0.88)
            return [layer(arc.trimmedPath(from: start, to: end),
                          opacity: 0.86 * (1 - trail), width: 0.98)]
        }
    }

    private static func handOval(in rect: CGRect, bend: CGFloat) -> Path {
        let x = rect.width / 2, y = rect.height / 2
        var path = Path()
        path.move(to: CGPoint(x: -x * 0.88, y: -y * 0.40))
        path.addCurve(to: CGPoint(x: x * 0.12, y: -y * 0.94),
                      control1: CGPoint(x: -x * 0.82, y: -y * 0.94),
                      control2: CGPoint(x: -x * (0.20 + bend), y: -y * 1.02))
        path.addCurve(to: CGPoint(x: x * 0.91, y: y * 0.44),
                      control1: CGPoint(x: x * 0.81, y: -y * (0.89 - bend)),
                      control2: CGPoint(x: x * 1.02, y: y * 0.06))
        path.addCurve(to: CGPoint(x: -x * 0.85, y: -y * 0.31),
                      control1: CGPoint(x: x * (0.55 - bend), y: y * 1.02),
                      control2: CGPoint(x: -x * 1.01, y: y * 0.97))
        return path
    }

    private static func gestureRect(for piece: LyricTypeFragment) -> CGRect {
        let padding = padding(for: piece)
        return CGRect(x: -piece.size.width / 2 - padding, y: -piece.size.height * 0.44 - padding,
                      width: piece.size.width + padding * 2, height: piece.size.height * 0.88 + padding * 2)
    }
    private static func padding(for piece: LyricTypeFragment) -> CGFloat { min(16, max(3, piece.fontSize * 0.15)) }
    private static func strokeWidth(for piece: LyricTypeFragment) -> CGFloat { min(6, max(1.5, piece.fontSize * 0.058)) }
    private static func triangleSpan(for piece: LyricTypeFragment) -> CGFloat { min(66, max(16, piece.fontSize * 0.62)) }

    private static func worldEnvelope(_ local: CGRect, for piece: LyricTypeFragment) -> CGRect {
        guard usable(piece), local.width.isFinite, local.height.isFinite else { return .zero }
        let sampled = piece.accent
        let sx = sampled.map { axisScale($0.scaleX) } ?? 1.08
        let sy = sampled.map { axisScale($0.scaleY) } ?? 1.08
        let scaled = CGSize(width: local.width * sx, height: local.height * sy)
        let reserved = sampled == nil ? tiltEnvelope(scaled, degrees: 3) : scaled
        let angle = piece.rotation * .pi / 180
        let width = (abs(reserved.width * cos(angle)) + abs(reserved.height * sin(angle))) * piece.scale
        let height = (abs(reserved.width * sin(angle)) + abs(reserved.height * cos(angle))) * piece.scale
        let offset = sampled == nil ? piece.fontSize * 0.09 * piece.scale * sqrt(2) : 0
        return CGRect(x: piece.center.x - width / 2, y: piece.center.y - height / 2,
                      width: width, height: height).insetBy(dx: -offset - 1.2, dy: -offset - 1.2)
    }

    private static func tiltEnvelope(_ size: CGSize, degrees: CGFloat) -> CGSize {
        let angle = degrees * .pi / 180
        return CGSize(width: max(size.width, size.width * cos(angle) + size.height * sin(angle)),
                      height: max(size.height, size.width * sin(angle) + size.height * cos(angle)))
    }
    private static func usable(_ piece: LyricTypeFragment) -> Bool {
        piece.fontSize.isFinite && piece.fontSize > 0 && piece.size.width.isFinite && piece.size.width > 0
            && piece.size.height.isFinite && piece.size.height > 0 && piece.scale.isFinite && piece.scale > 0
            && piece.center.x.isFinite && piece.center.y.isFinite && piece.rotation.isFinite
    }
    private static func axisScale(_ value: Double) -> CGFloat { value.isFinite ? CGFloat(min(1.08, max(0.90, value))) : 1 }
    private static func clamp(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
    private static func smooth(_ value: Double) -> Double { let x = clamp(value); return x * x * (3 - 2 * x) }
}
