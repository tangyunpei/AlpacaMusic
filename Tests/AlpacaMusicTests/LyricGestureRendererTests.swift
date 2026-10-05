import AppKit
import SwiftUI
import Testing
@testable import AlpacaMusic

@MainActor private func gestureFixture(text: String, width: CGFloat, font: CGFloat, id: Int = 0) -> LyricTypeFragment {
    .init(id: id, text: text, center: CGPoint(x: 500, y: 300),
          size: CGSize(width: width, height: font * 1.2), fontSize: font, weight: .semibold,
          timedStart: nil, timedEnd: nil)
}

private func gestureElements(_ path: Path) -> [Path.Element] {
    var elements: [Path.Element] = []
    path.forEach { elements.append($0) }
    return elements
}

private func gesturePoints(_ path: Path) -> [CGPoint] {
    var points: [CGPoint] = []
    path.forEach {
        switch $0 {
        case let .move(to: point), let .line(to: point): points.append(point)
        case let .quadCurve(to: point, control: control): points += [point, control]
        case let .curve(to: point, control1: first, control2: second): points += [point, first, second]
        case .closeSubpath: break
        }
    }
    return points
}

/// Measure rendered geometry, including Bezier arcs, rather than relying on
/// the event envelope alone to prove that the pen actually finished its path.
private func gestureLength(_ path: Path) -> Double {
    var length = 0.0, cursor = CGPoint.zero
    func segment(to next: CGPoint) {
        length += hypot(Double(next.x - cursor.x), Double(next.y - cursor.y))
        cursor = next
    }
    path.forEach { element in
        switch element {
        case let .move(to: point): cursor = point
        case let .line(to: point): segment(to: point)
        case let .quadCurve(to: end, control: control):
            let start = cursor
            for tick in 1...48 {
                let t = CGFloat(tick) / 48, u = 1 - t
                segment(to: .init(x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                                  y: u * u * start.y + 2 * u * t * control.y + t * t * end.y))
            }
        case let .curve(to: end, control1: first, control2: second):
            let start = cursor
            for tick in 1...48 {
                let t = CGFloat(tick) / 48, u = 1 - t
                segment(to: .init(x: u * u * u * start.x + 3 * u * u * t * first.x + 3 * u * t * t * second.x + t * t * t * end.x,
                                  y: u * u * u * start.y + 3 * u * u * t * first.y + 3 * u * t * t * second.y + t * t * t * end.y))
            }
        case .closeSubpath: break
        }
    }
    return length
}

@Test @MainActor func gestureStrokeEnvelopeContainsAllPhasesAndWordShapes() {
    let samples: [(String, CGFloat, CGFloat)] = [("光", 19, 18), ("quiet", 74, 31),
                                               ("慢慢靠近", 280, 68), ("unforgettable", 680, 112)]
    for (text, width, font) in samples {
        for id in [0, 1] {
            let piece = gestureFixture(text: text, width: width, font: font, id: id)
            for kind in LyricAccentKind.allCases {
                let envelope = LyricAccentRenderer.markBounds(for: piece, kind: kind)
                for progress in [0.0, 0.08, 0.25, 0.5, 0.75, 0.9, 1.0] {
                    for trail in [0.0, 0.4, 1.0] {
                        let state = LyricAccentState(kind: kind, intensity: 0.9, progress: progress,
                                                    weightBoost: 0.4, trail: trail)
                        let layers = LyricAccentRenderer.markLayers(for: piece, accent: state)
                        #expect(!layers.isEmpty)
                        for layer in layers {
                            #expect(layer.opacity.isFinite && layer.opacity >= 0 && layer.opacity <= 1)
                            #expect(layer.lineWidth.isFinite && layer.lineWidth > 0 && layer.lineWidth <= 10.2)
                            #expect(gesturePoints(layer.path).allSatisfy { $0.x.isFinite && $0.y.isFinite })
                            if layer.path.isEmpty {
                                // The combinatorial sweep deliberately permits
                                // an exit tail to overtake an unfinished head.
                                #expect(trail > 0 || progress == 0)
                                continue
                            }
                            let ink = layer.path.boundingRect.insetBy(dx: -layer.lineWidth / 2, dy: -layer.lineWidth / 2)
                            #expect(envelope.contains(ink))
                        }
                    }
                }
            }
        }
    }
}

@Test @MainActor func shapeAccentsFinishRecognizableContoursBeforeTheirOneWayWithdrawal() {
    let piece = gestureFixture(text: "Complete gesture", width: 240, font: 64)
    for kind in [LyricAccentKind.ring, .box, .triangle] {
        let early = LyricAccentRenderer.markLayers(for: piece, accent: .init(kind: kind, intensity: 1,
                                                                           progress: 0.12, weightBoost: 0))
        let complete = LyricAccentRenderer.markLayers(for: piece, accent: .init(kind: kind, intensity: 1,
                                                                              progress: 1, weightBoost: 0))
        let earlyLength = early.reduce(0.0) { $0 + gestureLength($1.path) }
        let completeLength = complete.reduce(0.0) { $0 + gestureLength($1.path) }
        #expect(completeLength > earlyLength * 3.5)
        #expect(complete.allSatisfy { $0.opacity > 0.9 })
        if kind == .ring {
            #expect(complete[0].path.boundingRect.width > piece.size.width * 0.88)
            #expect(complete[0].path.boundingRect.height > piece.size.height * 0.8)
        } else if kind == .triangle {
            #expect(gestureElements(complete[0].path).count >= 4)
        } else {
            #expect(complete.count == 2)
            #expect(complete.allSatisfy { $0.path.boundingRect.width > piece.size.width * 0.4 })
            #expect(complete.allSatisfy { $0.path.boundingRect.height > piece.size.height * 0.45 })
        }
    }
    for kind in LyricAccentKind.allCases {
        var precedingLength = Double.infinity, precedingOpacity = Double.infinity
        for tick in 0...60 {
            let trail = Double(tick) / 60
            let layers = LyricAccentRenderer.markLayers(for: piece, accent: .init(kind: kind, intensity: 1,
                                                                                progress: 1, weightBoost: 0, trail: trail))
            let length = layers.reduce(0.0) { $0 + gestureLength($1.path) }
            let opacity = layers.map(\.opacity).reduce(0, +)
            #expect(length <= precedingLength + 0.02)
            #expect(opacity <= precedingOpacity)
            precedingLength = length; precedingOpacity = opacity
            if tick == 60 { #expect(length < 0.02 && opacity == 0) }
        }
    }
}

@Test @MainActor func realWordAccentsShowTheCompletePathAfterTheNextWordThenWithdrawOnce() throws {
    let line = LyricLine(id: 61, text: "Light returns", start: 1, end: 7, words: [
        .init(id: 0, text: "Light ", start: 2, end: 2.04),
        .init(id: 1, text: "returns", start: 2.04, end: 5)
    ])
    let piece = gestureFixture(text: "Light", width: 180, font: 64)
    let durations: [LyricAccentKind: Double] = [.ring: 1.08, .box: 1.16, .flash: 0.84, .weight: 1.20, .pulse: 1.28, .triangle: 1.14]
    for kind in LyricAccentKind.allCases {
        let choice = LyricAccentChoice(kind: kind, reason: .wordOnset)
        let finished = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 2.36))
        let presented = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 2.46))
        #expect(finished.progress == 1 && finished.trail == 0)
        #expect(presented.progress == 1 && presented.trail == 0)
        let drawn = LyricAccentRenderer.markLayers(for: piece, accent: finished)
        let held = LyricAccentRenderer.markLayers(for: piece, accent: presented)
        #expect(!drawn.isEmpty && !held.isEmpty)
        #expect(drawn.map { gestureElements($0.path) } == held.map { gestureElements($0.path) })
        #expect(held.contains { $0.opacity > 0.18 })
        let duration = try #require(durations[kind])
        var precedingLength = Double.infinity, precedingOpacity = Double.infinity
        for tick in 0...80 {
            let position = 2 + duration * (0.60 + Double(tick) / 80 * 0.399)
            let state = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: position))
            let layers = LyricAccentRenderer.markLayers(for: piece, accent: state)
            let length = layers.reduce(0.0) { $0 + gestureLength($1.path) }
            let opacity = layers.map(\.opacity).reduce(0, +)
            #expect(length <= precedingLength + 0.02)
            #expect(opacity <= precedingOpacity + 0.000_001)
            precedingLength = length; precedingOpacity = opacity
        }
        #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 2 + duration + 0.001) == nil)
        #expect(finished == LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 2.36))
    }
}

@Test @MainActor func localShapeAccentsHaveBoldBoundedInkAtOrdinaryLyricSizes() {
    let piece = gestureFixture(text: "Original lyric", width: 285, font: 72)
    let universal = LyricAccentRenderer.markBounds(for: piece)
    let triangular = LyricAccentRenderer.markBounds(for: piece, kind: .triangle)
    #expect(universal == triangular)
    for kind in [LyricAccentKind.ring, .box] {
        let reserved = LyricAccentRenderer.markBounds(for: piece, kind: kind)
        #expect(reserved.height < universal.height)
        #expect(universal.contains(reserved))
    }
    for kind in [LyricAccentKind.ring, .box, .triangle] {
        let state = LyricAccentState(kind: kind, intensity: 0.55, progress: 0.62, weightBoost: 0)
        let layers = LyricAccentRenderer.markLayers(for: piece, accent: state)
        #expect(layers.contains { $0.lineWidth >= 4 && $0.lineWidth <= 6 })
        #expect(layers.contains { $0.opacity > 0.65 && $0.opacity <= 1 })
        let weak = LyricAccentRenderer.markLayers(for: piece, accent: .init(kind: kind, intensity: 0.1,
                                                                         progress: 0.62, weightBoost: 0))
        #expect(zip(weak, layers).allSatisfy { $0.0.opacity < $0.1.opacity })
        #expect(LyricAccentRenderer.markLayers(for: piece, accent: .init(kind: kind, intensity: 0,
                                                                       progress: 0.62, weightBoost: 0)).isEmpty)
    }
}

@Test @MainActor func triangularPenFlourishesStayAboveGlyphsThroughoutTheirMotion() {
    for (width, font) in [(CGFloat(19), CGFloat(18)), (176, 52), (680, 112)] {
        for id in [0, 1] {
            let piece = gestureFixture(text: "Visible lyrics", width: width, font: font, id: id)
            var visibleSamples = 0
            for tick in 0...120 {
                let progress = Double(tick) / 120
                for trail in [0.0, 0.4, 1.0] {
                    let state = LyricAccentState(kind: .triangle, intensity: 1, progress: progress,
                                                weightBoost: 0, trail: trail)
                    let layers = LyricAccentRenderer.markLayers(for: piece, accent: state)
                    #expect(layers.count == 1)
                    for layer in layers {
                        let bounds = layer.path.boundingRect
                        if bounds.isNull {
                            // An artificial release may overtake the head.
                            // Empty ink is not a rendered triangle to clear.
                            #expect(layer.path.isEmpty)
                            continue
                        }
                        visibleSamples += 1
                        #expect(bounds.width.isFinite && bounds.height.isFinite)
                        let ink = bounds.insetBy(dx: -layer.lineWidth / 2, dy: -layer.lineWidth / 2)
                        #expect(ink.maxY < -piece.size.height / 2)
                        #expect(LyricAccentRenderer.markBounds(for: piece).contains(ink))
                        #expect(!gestureElements(layer.path).contains(.closeSubpath))
                    }
                }
            }
            #expect(visibleSamples >= 121)
            let complete = LyricAccentRenderer.markLayers(for: piece, accent: .init(kind: .triangle, intensity: 1,
                                                                                  progress: 1, weightBoost: 0))
            #expect(complete.first.map { gestureElements($0.path).count >= 4 } == true)
        }
    }
}

@Test @MainActor func gesturesTravelWithdrawAndRemainOpenRatherThanPersistentBadges() {
    let piece = gestureFixture(text: "return", width: 176, font: 52)
    for kind in LyricAccentKind.allCases {
        let early = LyricAccentState(kind: kind, intensity: 1, progress: 0.12, weightBoost: 0.3)
        let strike = LyricAccentState(kind: kind, intensity: 1, progress: 0.62, weightBoost: 0.3)
        var release = strike
        release.trail = 0.85
        let entrance = LyricAccentRenderer.markLayers(for: piece, accent: early)
        let middle = LyricAccentRenderer.markLayers(for: piece, accent: strike)
        let tail = LyricAccentRenderer.markLayers(for: piece, accent: release)
        #expect(entrance.map { gestureElements($0.path) } != middle.map { gestureElements($0.path) })
        #expect(tail.map(\.opacity).reduce(0, +) < middle.map(\.opacity).reduce(0, +))
        #expect((entrance + middle + tail).allSatisfy { layer in
            !gestureElements(layer.path).contains(.closeSubpath)
        })
        let revisited = LyricAccentRenderer.markLayers(for: piece, accent: strike)
        #expect(middle.map { gestureElements($0.path) } == revisited.map { gestureElements($0.path) })
        #expect(middle.map(\.opacity) == revisited.map(\.opacity))
    }
    let box = LyricAccentRenderer.markLayers(for: piece, accent: .init(kind: .box, intensity: 1, progress: 0.55, weightBoost: 0))
    #expect(box.count == 2)
    #expect(box.allSatisfy { gestureElements($0.path).contains { element in
        // Trimming may express the rounded quadratic as a cubic Bezier.
        switch element { case .quadCurve, .curve: true; default: false }
    } })
    #expect(!box[0].path.boundingRect.intersects(box[1].path.boundingRect))
}

@Test @MainActor func gesturePreflightEnvelopeContainsActualMovedGlyphAndMark() {
    for width in [CGFloat(22), 160, 620] {
        for rotation in [-18.0, 0, 16.0] {
            var base = gestureFixture(text: "Original geometry", width: width, font: 58)
            base.rotation = rotation
            base.scale = 0.63
            let glyphReserve = LyricAccentRenderer.maximumGlyphWorldBounds(for: base)
            let markReserve = LyricAccentRenderer.maximumWorldBounds(for: base)
            for dx in [-0.09, 0.09] {
                for dy in [-0.09, 0.09] {
                    for tilt in [-3.0, 3.0] {
                        for scale in [0.90, 1.08] {
                            var sampled = base
                            sampled.center.x += CGFloat(dx) * base.fontSize * base.scale
                            sampled.center.y += CGFloat(dy) * base.fontSize * base.scale
                            sampled.rotation += tilt
                            sampled.accent = .init(kind: .pulse, intensity: 1, progress: 0.8, weightBoost: 0,
                                                   offsetX: dx, offsetY: dy, scaleX: scale, scaleY: scale,
                                                   rotation: tilt, trail: 0.3)
                            #expect(glyphReserve.contains(LyricAccentRenderer.maximumGlyphWorldBounds(for: sampled)))
                            #expect(markReserve.contains(LyricAccentRenderer.maximumWorldBounds(for: sampled)))
                        }
                    }
                }
            }
        }
    }
}

@Test @MainActor func gestureRendererRejectsNonfiniteOrInvisibleEvents() {
    let piece = gestureFixture(text: "light", width: 100, font: 40)
    for bad in [Double.nan, .infinity, -.infinity] {
        let states = [LyricAccentState(kind: .ring, intensity: bad, progress: 0.4, weightBoost: 0),
                      LyricAccentState(kind: .box, intensity: 1, progress: bad, weightBoost: 0),
                      LyricAccentState(kind: .pulse, intensity: 1, progress: 0.4, weightBoost: 0, trail: bad)]
        #expect(states.allSatisfy { LyricAccentRenderer.markLayers(for: piece, accent: $0).isEmpty })
    }
    #expect(LyricAccentRenderer.markLayers(for: piece, accent: .init(kind: .flash, intensity: 0, progress: 0.5, weightBoost: 0)).isEmpty)
    var badPiece = piece
    badPiece.size.width = .infinity
    #expect(LyricAccentRenderer.markBounds(for: badPiece) == .zero)
    #expect(LyricAccentRenderer.maximumWorldBounds(for: badPiece) == .zero)
}
