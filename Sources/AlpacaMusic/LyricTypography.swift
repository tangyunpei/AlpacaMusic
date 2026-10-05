import AppKit
import SwiftUI

/// Eight compositions with different spatial grammars, not eight entrances for
/// the same centered stack. Every pose is a pure function of playback time.
enum LyricScene: Int, CaseIterable, Equatable, Sendable {
    case monument, steps, editorial, diagonal, constellation, hush, orbit, echo
}
enum LyricFragmentRole: String, Sendable { case primary, echo, outgoing, completingAccent }
enum LyricInk: Equatable, Sendable { case solid, outline }
enum LyricMotionProfile: Int, CaseIterable, Equatable, Sendable { case drift, breathe, gather, brisk }
enum LyricDecoration: Int, CaseIterable, Equatable, Sendable { case outline, echoes, driftingOutline, quiet }

/// Arrangement, movement and background typography are separate decisions. The
/// director uses only cue metadata, so audio cannot reshuffle a sentence midway.
struct LyricDirection: Equatable, Sendable {
    var scene: LyricScene
    var motion: LyricMotionProfile
    var decoration: LyricDecoration
}

struct LyricTypeFragment: Identifiable {
    var id: Int
    var text: String
    var center: CGPoint
    var size: CGSize
    var fontSize: CGFloat
    var weight: Font.Weight
    var rotation: Double = 0
    var opacity: Double = 1
    var glyphOpacity: Double = 1
    var scale: CGFloat = 1
    var timedStart: Double?
    var timedEnd: Double?
    var lineID: Int = 0
    var role: LyricFragmentRole = .primary
    var tracking: CGFloat = 0
    var group: Int = 0
    var ink: LyricInk = .solid
    var accent: LyricAccentState? = nil
    // The full text is shaped once; playback only reveals its fixed grapheme
    // regions. Echoes copy this schedule, so future lyrics cannot leak behind it.
    var revealUnits: [LyricRevealUnit] = []
    var reduceRevealMotion = false

    var bounds: CGRect {
        let angle = rotation * .pi / 180
        let width = size.width * CGFloat(accent?.scaleX ?? 1)
        let height = size.height * CGFloat(accent?.scaleY ?? 1)
        let w = abs(width * cos(angle)) + abs(height * sin(angle))
        let h = abs(width * sin(angle)) + abs(height * cos(angle))
        return CGRect(x: center.x - w * scale / 2, y: center.y - h * scale / 2, width: w * scale, height: h * scale)
    }
}
struct LyricStageFrame {
    var activeLineID: Int?
    var fragments: [LyricTypeFragment]
}

@MainActor enum LyricTypography {
    private static let stageCenter = CGPoint(x: 500, y: 300)
    private struct PlanKey: Hashable {
        var text: String
        var words: [String]
        var wordStarts: [Double]
        var wordEnds: [Double?]
        var scene: Int
        var motion: Int
        var duration: Double
        var cueStart: Double?
        var cueEnd: Double?
        var seed: UInt64
        var width: CGFloat
        var height: CGFloat
    }
    private struct StagePlan {
        var pieces: [LyricTypeFragment]
        var groupCenters: [CGPoint]
        var scene: LyricScene
        var motion: LyricMotionProfile
        var duration: Double
        var seed: UInt64
        var hasWordTiming: Bool
        var readingRows: Bool
        var accents: [Int: LyricAccentChoice]
        var fittingScale: CGFloat
        var destination: CGPoint
    }
    private static var plans: [PlanKey: StagePlan] = [:]
    private static var planOrder: [PlanKey] = []
    private struct MeasurementKey: Hashable { var text: String; var size: CGFloat; var weight: CGFloat }
    private static var measurements: [MeasurementKey: CGSize] = [:]
    private static var measurementOrder: [MeasurementKey] = []

    static func scene(for index: Int) -> LyricScene { LyricScene(rawValue: abs(index % LyricScene.allCases.count)) ?? .monument }

    static func director(line: LyricLine, index: Int) -> LyricDirection {
        let seed = stableSeed(line.text, index: index)
        let duration = cueDuration(line)
        let tokens = line.text.split(whereSeparator: \.isWhitespace)
        let units = tokens.count > 1 ? Double(tokens.count) * 1.6 : Double(line.text.filter { !$0.isWhitespace }.count)
        let pressure = units / duration
        let scenes: [LyricScene]
        let motions: [LyricMotionProfile]
        if duration < 3.1 || pressure > 3.2 {
            scenes = [.steps, .diagonal, .editorial, .monument]
            motions = [.brisk, .gather]
        } else if duration >= 7.5 && pressure < 2.0 {
            scenes = [.hush, .orbit, .constellation, .echo, .monument]
            motions = [.breathe, .drift]
        } else {
            scenes = [.editorial, .constellation, .steps, .diagonal, .echo, .orbit]
            motions = [.gather, .drift, .breathe]
        }
        return .init(scene: scenes[Int(seed % UInt64(scenes.count))],
                     motion: motions[Int((seed >> 13) % UInt64(motions.count))],
                     decoration: LyricDecoration(rawValue: Int((seed >> 27) % UInt64(LyricDecoration.allCases.count))) ?? .quiet)
    }

    private static func cueDuration(_ line: LyricLine) -> Double {
        let raw = (line.end ?? (line.start ?? 0) + 6) - (line.start ?? 0)
        return raw.isFinite ? min(120, max(0.25, raw)) : 6
    }

    private static func stableSeed(_ text: String, index: Int) -> UInt64 {
        // Swift Hasher deliberately changes across launches. FNV retains the
        // same composition after a seek, reopening, or offline QA rendering.
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
        value = (value ^ UInt64(bitPattern: Int64(index))) &* 1_099_511_628_211
        // FNV's upper bits can remain similar for short, nearly identical
        // endings. Avalanche the complete seed before using different bit
        // regions for independent scene, movement and decoration decisions.
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        value ^= value >> 31
        return value
    }

    static func progress(line: LyricLine, position: Double) -> Double {
        guard let start = line.start, start.isFinite, position.isFinite else { return 0.5 }
        let duration = cueDuration(line)
        return min(1, max(0, (position - start) / duration))
    }

    /// Current semantic text only. Decorative echoes and the previous sentence
    /// live in frame(), so content/containment checks need not special-case them.
    static func layout(line: LyricLine, index: Int, in size: CGSize, position: Double, reduceMotion: Bool,
                       audio: VisualizationAudio = .init()) -> [LyricTypeFragment] {
        var direction = director(line: line, index: index)
        direction.scene = scene(for: index)
        return layout(line: line, index: index, direction: direction, in: size, position: position, reduceMotion: reduceMotion, audio: audio)
    }

    private static func layout(line: LyricLine, index: Int, direction: LyricDirection, in size: CGSize, position: Double,
                               reduceMotion: Bool, audio: VisualizationAudio, posePosition: Double? = nil) -> [LyricTypeFragment] {
        guard size.width.isFinite, size.height.isFinite, size.width > 1, size.height > 1, !line.text.isEmpty else { return [] }
        let plan = plan(line: line, direction: direction, index: index, size: size)
        let phase = reduceMotion ? 0.5 : progress(line: line, position: posePosition ?? position)
        var pieces = pose(plan, phase: phase, audio: reduceMotion ? .init() : audio, stationary: reduceMotion)
        for i in pieces.indices {
            pieces[i].lineID = line.id
            pieces[i].reduceRevealMotion = reduceMotion
            if !reduceMotion, plan.hasWordTiming, line.words.indices.contains(i) {
                pieces[i].timedStart = line.words[i].start
                pieces[i].timedEnd = line.words[i].end
            }
            if let choice = plan.accents[i] {
                pieces[i].accent = LyricEmphasis.state(choice: choice, line: line, unitIndex: i, position: position,
                                                      audio: audio, reduceMotion: reduceMotion)
                if let accent = pieces[i].accent {
                    // Size emphasis belongs to this word's event too. Reserve
                    // its maximum advance in the plan, but do not enlarge a
                    // future word before the playback position reaches it.
                    pieces[i].scale *= 1 + CGFloat(accent.intensity) * 0.18
                    // The word and its stroke share one local coordinate space.
                    // Apply translation/tilt here, and axis scale in the renderer;
                    // glyph measurements remain natural throughout the pipeline.
                    let angle = pieces[i].rotation * .pi / 180
                    let x = CGFloat(accent.offsetX) * pieces[i].fontSize
                    let y = CGFloat(accent.offsetY) * pieces[i].fontSize
                    pieces[i].center.x += x * cos(angle) - y * sin(angle)
                    pieces[i].center.y += x * sin(angle) + y * cos(angle)
                    pieces[i].rotation += accent.rotation
                }
            }
        }
        return pieces
    }

    static func frame(document: LyricDocument, position: Double, in size: CGSize, reduceMotion: Bool,
                      audio: VisualizationAudio = .init()) -> LyricStageFrame {
        guard position.isFinite, document.timing != .plain else { return .init(activeLineID: nil, fragments: []) }
        let active = document.activeIndex(at: position)
        var result: [LyricTypeFragment] = []
        // Finished cues retain only their still-running owner words. The
        // ordinary sentence pose freezes at its end, while the independent
        // accent clock keeps drawing, presenting and releasing exactly once.
        // Looking back beyond one cue also handles rapid 100 ms line changes.
        if !reduceMotion {
            for index in document.lines.indices where index != active {
                let line = document.lines[index]
                guard let end = line.end, end.isFinite, position >= end,
                      position - end < LyricEmphasis.maximumTailDuration else { continue }
                let continuing = layout(line: line, index: index, direction: director(line: line, index: index),
                                        in: size, position: position, reduceMotion: false, audio: .init(), posePosition: end)
                let selectedIDs = plan(line: line, direction: director(line: line, index: index), index: index, size: size).accents.keys.sorted()
                for var piece in continuing where piece.accent != nil {
                    piece.role = .completingAccent
                    piece.id += 3_000_000 + index * 256
                    let priorReadingLevel = piece.timedEnd.map { position >= $0 } == true ? 0.72 : 1.0
                    piece.glyphOpacity = (0.52 + (priorReadingLevel - 0.52) * (1 - smooth(min(1, max(0, (position - end) / 0.18)))))
                        * (1 - smooth(piece.accent?.trail ?? 0))
                    piece.timedStart = nil; piece.timedEnd = nil
                    // Marks retain the event's own opacity; the renderer gives
                    // their prior word a quieter reading level behind new text.
                    piece.opacity = 1
                    // Carry the owner into an upper margin as the next cue
                    // arrives. Its local pen clock never resets, and completed
                    // ink does not sit across the new sentence's reading area.
                    if let accent = piece.accent {
                        var reserved = piece
                        reserved.scale /= 1 + CGFloat(accent.intensity) * 0.18
                        reserved.rotation -= accent.rotation
                        reserved.accent = nil
                        let envelope = LyricAccentRenderer.maximumWorldBounds(for: reserved, kind: accent.kind)
                        let dockScale = min(0.68, size.width * 0.42 / max(1, envelope.width),
                                            size.height * 0.30 / max(1, envelope.height))
                        let halfWidth = envelope.width * dockScale / 2
                        let halfHeight = envelope.height * dockScale / 2
                        let margin = min(18, min(size.width, size.height) * 0.04)
                        let side: CGFloat = selectedIDs.first == piece.id - 3_000_000 - index * 256 ? 0.25 : 0.75
                        let target = CGPoint(x: min(size.width - halfWidth - margin, max(halfWidth + margin, size.width * side)),
                                             y: halfHeight + margin)
                        let transfer = CGFloat(smooth(min(1, max(0, (position - end) / 0.20))))
                        piece.center.x += (target.x - piece.center.x) * transfer
                        piece.center.y += (target.y - piece.center.y) * transfer
                        piece.scale *= 1 + (dockScale - 1) * transfer
                    }
                    result.append(piece)
                }
            }
        }
        // A preceding sentence keeps its actual end pose for a short tail. No
        // history/state is retained: backward seeks reconstruct the same tail.
        if !reduceMotion, let preceding = precedingLine(document: document, active: active, position: position) {
            let line = document.lines[preceding]
            let end = line.end ?? document.lines.dropFirst(preceding + 1).first?.start ?? .infinity
            let age = position - end
            if age >= 0, age < 0.42 {
                let phase = age / 0.42
                var outgoing = layout(line: line, index: preceding, direction: director(line: line, index: preceding),
                                      in: size, position: end, reduceMotion: false, audio: .init())
                let retainedIDs = Set(result.filter { $0.lineID == line.id && $0.role == .completingAccent }
                    .map { $0.id - 3_000_000 - preceding * 256 })
                outgoing.removeAll { retainedIDs.contains($0.id) }
                for i in outgoing.indices {
                    outgoing[i].role = .outgoing
                    outgoing[i].id += 2_000_000
                    outgoing[i].opacity = 0.23 * (1 - smooth(phase))
                    outgoing[i].center.y -= CGFloat(phase) * size.height * 0.07
                    outgoing[i].center.x += CGFloat(phase) * size.width * (preceding.isMultiple(of: 2) ? -0.035 : 0.035)
                    outgoing[i].timedStart = nil; outgoing[i].timedEnd = nil; outgoing[i].accent = nil
                }
                result += outgoing
            }
        }
        if let active {
            let line = document.lines[active]
            let direction = director(line: line, index: active)
            let primary = layout(line: line, index: active, direction: direction, in: size, position: position,
                                 reduceMotion: reduceMotion, audio: audio)
            if !reduceMotion {
                result += decorations(primary: primary, direction: direction, phase: progress(line: line, position: position), in: size, audio: audio)
            }
            result += primary
        }
        return .init(activeLineID: active.map { document.lines[$0].id }, fragments: result)
    }

    private static func precedingLine(document: LyricDocument, active: Int?, position: Double) -> Int? {
        if let active { return active > 0 ? active - 1 : nil }
        return document.lines.lastIndex { line in line.end.map { $0 <= position } ?? false }
    }

    private static func decorations(primary: [LyricTypeFragment], direction: LyricDirection, phase: Double, in size: CGSize,
                                    audio: VisualizationAudio) -> [LyricTypeFragment] {
        guard direction.decoration != .quiet, !primary.isEmpty else { return [] }
        let emphasizedGroup = primary.max(by: { $0.fontSize < $1.fontSize })?.group ?? 0
        let selected = direction.decoration == .echoes ? primary : primary.filter { $0.group == emphasizedGroup }
        let copies = direction.decoration == .echoes ? 2 : 1
        let flow = CGFloat(smooth(phase)), breathe = CGFloat(sin(phase * .pi))
        let treble = audio.available && audio.treble.isFinite ? min(1, max(0, audio.treble)) : 0
        var result: [LyricTypeFragment] = []
        for layer in (0..<copies).reversed() {
            let multiplier: CGFloat = direction.decoration == .echoes ? 1.13 + CGFloat(layer) * 0.16 : 1.78 + breathe * 0.16
            for piece in selected {
                var echo = piece
                echo.id += 100_000 * (layer + 1); echo.role = .echo
                echo.ink = direction.decoration == .echoes && layer == 0 ? .solid : .outline
                echo.center.x = size.width * 0.5 + (piece.center.x - size.width * 0.5) * multiplier
                echo.center.y = size.height * 0.5 + (piece.center.y - size.height * 0.5) * multiplier
                if direction.decoration == .echoes {
                    echo.center.x += CGFloat(layer + 1) * size.width * (0.018 + flow * 0.012)
                    echo.center.y -= CGFloat(layer + 1) * size.height * (0.032 + flow * 0.035)
                    echo.opacity = layer == 0 ? 0.075 : 0.12
                } else {
                    echo.center.x += (flow - 0.5) * size.width * (direction.decoration == .driftingOutline ? 0.16 : -0.08)
                    echo.center.y -= size.height * (0.12 + breathe * 0.045)
                    echo.rotation += direction.decoration == .driftingOutline ? Double(flow - 0.5) * -7 : 0
                    echo.opacity = direction.decoration == .driftingOutline ? 0.13 : 0.16
                }
                echo.fontSize *= multiplier; echo.size.width *= multiplier; echo.size.height *= multiplier; echo.tracking *= multiplier
                echo.center.x += CGFloat(treble) * size.width * 0.008 * (layer.isMultiple(of: 2) ? 1 : -1)
                echo.opacity += treble * 0.022
                echo.timedStart = nil; echo.timedEnd = nil; echo.accent = nil
                result.append(echo)
            }
        }
        return result
    }

    private static func plan(line: LyricLine, direction: LyricDirection, index: Int, size: CGSize) -> StagePlan {
        let scene = direction.scene, duration = cueDuration(line), seed = stableSeed(line.text, index: index)
        let key = PlanKey(text: line.text, words: line.words.map(\.text), wordStarts: line.words.map(\.start), wordEnds: line.words.map(\.end), scene: scene.rawValue, motion: direction.motion.rawValue,
                          duration: duration, cueStart: line.start, cueEnd: line.end, seed: seed, width: size.width, height: size.height)
        if let cached = plans[key] { return cached }
        let timed = compatibleWords(line)
        let rawGroups = textGroups(line: line, count: scene == .monument || scene == .hush || scene == .echo ? 2 : 3,
                                   maximumUnits: phraseBudget(in: size))
        // Untimed phrases gain lexical fragments for local typography, while
        // supplied timed words keep their exact one-to-one timing contract.
        let groups = timed ? rawGroups : lexicalGroups(line.text, phrases: rawGroups.map { $0.joined() })
        let texts = groups.flatMap { $0 }
        let accents = LyricEmphasis.choices(texts: texts, line: line, suppliedWordTiming: timed, seed: seed)
        let reveal = LyricReveal.timeline(for: line)
        let revealedFragments = reveal.isTimed ? reveal.fragments(texts) : []
        func makePieces(readingRows: Bool) -> (pieces: [LyricTypeFragment], centers: [CGPoint]) {
            var pieces: [LyricTypeFragment] = [], centers: [CGPoint] = []
            for (groupIndex, units) in groups.enumerated() {
                let configuration = groupConfiguration(scene: scene, index: groupIndex, count: groups.count, readingRows: readingRows)
                let firstID = pieces.count
                let weights = units.indices.map { offset in
                    accents[firstID + offset] == nil ? configuration.nsWeight : NSFont.Weight(rawValue: max(configuration.nsWeight.rawValue, NSFont.Weight.heavy.rawValue))
                }
                let hierarchy = units.indices.map { accents[firstID + $0] == nil ? CGFloat(1) : 1.18 }
                func advance(_ measured: CGSize, font: CGFloat, selected: Bool, text: String) -> CGFloat {
                    guard !text.allSatisfy(\.isWhitespace) else { return measured.width }
                    // Stable advances reserve the complete word gesture. A
                    // focal word can expand or lean without pushing its neighbor
                    // around every frame or touching the next glyph.
                    let tilt = (selected ? 4.8 : 1.8) * Double.pi / 180
                    return measured.width * (selected ? 1.08 : 1) + measured.height * CGFloat(sin(tilt)) + font * (selected ? 0.12 : 0.025)
                }
                let targetWidth = units.indices.reduce(CGFloat.zero) { value, offset in
                    let font = configuration.font * hierarchy[offset]
                    return value + advance(measure(units[offset], size: font, weight: weights[offset]), font: font,
                                           selected: accents[firstID + offset] != nil, text: units[offset])
                } + CGFloat(max(0, units.count - 1)) * 0.6
                let fittedFont = min(configuration.font, configuration.font * configuration.maxWidth / max(1, targetWidth))
                let reserved = units.indices.map { measure(units[$0], size: fittedFont * hierarchy[$0], weight: weights[$0]) }
                let measured = units.indices.map { measure(units[$0], size: fittedFont, weight: weights[$0]) }
                let advances = units.indices.map { advance(reserved[$0], font: fittedFont * hierarchy[$0], selected: accents[firstID + $0] != nil, text: units[$0]) }
                let gap = 0.6 * fittedFont / configuration.font
                let totalWidth = advances.reduce(CGFloat.zero, +) + CGFloat(max(0, units.count - 1)) * gap
                let centerX = configuration.alignment == -1 ? configuration.point.x + totalWidth / 2 : (configuration.alignment == 1 ? configuration.point.x - totalWidth / 2 : configuration.point.x)
                let groupCenter = CGPoint(x: centerX, y: configuration.point.y)
                centers.append(groupCenter)
                var cursor = centerX - totalWidth / 2
                for (unitIndex, unit) in units.enumerated() {
                    let unitSize = measured[unitIndex]
                    let font = fittedFont
                    pieces.append(.init(id: pieces.count, text: unit, center: CGPoint(x: cursor + advances[unitIndex] / 2, y: groupCenter.y), size: unitSize,
                                        fontSize: font, weight: configuration.weight, tracking: -font * 0.025, group: groupIndex,
                                        revealUnits: revealedFragments.indices.contains(pieces.count) ? revealedFragments[pieces.count] : []))
                    cursor += advances[unitIndex] + gap
                }
            }
            return (pieces, centers)
        }
        var composition = makePieces(readingRows: false)
        // Fit a whole trajectory once, not every individual frame. This keeps
        // intentional negative space and movement rather than recentering it.
        var plan = StagePlan(pieces: composition.pieces, groupCenters: composition.centers, scene: scene, motion: direction.motion, duration: duration,
                             seed: seed, hasWordTiming: timed, readingRows: false, accents: accents, fittingScale: 1, destination: stageCenter)
        // Wider lexical ink can expose collisions in a compact composition.
        // Choose a separated-row composition once per cue, never midway through
        // an animation, if its complete reading trajectory would cross rows.
        if hasCrossingGroups(plan) {
            composition = makePieces(readingRows: true)
            plan.pieces = composition.pieces; plan.groupCenters = composition.centers; plan.readingRows = true
        }
        var envelope = CGRect.null
        for step in 0...64 {
            for piece in pose(plan, phase: Double(step) / 64) {
                envelope = envelope.union(piece.bounds)
                if accents[piece.id] != nil {
                    var reserved = piece
                    reserved.scale *= 1.18
                    envelope = envelope.union(LyricAccentRenderer.maximumWorldBounds(for: reserved, kind: accents[piece.id]?.kind))
                }
            }
        }
        // Reserve the complete, clamped audio envelope rather than fitting to a
        // particular sample. Silence or beat peaks cannot resize the layout.
        envelope = envelope.insetBy(dx: -12, dy: -12)
        let margin = max(14, min(48, min(size.width, size.height) * 0.065))
        let horizontalExtent = max(abs(envelope.minX - 500), abs(envelope.maxX - 500), 1)
        let verticalExtent = max(abs(envelope.minY - 300), abs(envelope.maxY - 300), 1)
        plan.fittingScale = max(0.001, min((size.width - margin * 2) / (horizontalExtent * 2), (size.height - margin * 2) / (verticalExtent * 2))) * 0.94
        plan.destination = CGPoint(x: size.width / 2, y: size.height / 2)
        if planOrder.count >= 24 { plans.removeValue(forKey: planOrder.removeFirst()) }
        planOrder.append(key); plans[key] = plan
        return plan
    }

    private static func hasCrossingGroups(_ plan: StagePlan) -> Bool {
        guard plan.groupCenters.count > 1 else { return false }
        let maximumAudio = VisualizationAudio(AudioLevels(energy: 1, beat: 1, available: true, bass: 1, treble: 1))
        for step in 0...64 {
            let pieces = pose(plan, phase: Double(step) / 64, audio: maximumAudio)
            var rows = Array(repeating: CGRect.null, count: plan.groupCenters.count)
            for piece in pieces {
                var reserved = piece
                if plan.accents[piece.id] != nil { reserved.scale *= 1.18 }
                let glyph = plan.accents[piece.id] == nil ? piece.bounds : LyricAccentRenderer.maximumGlyphWorldBounds(for: reserved)
                rows[piece.group] = rows[piece.group].union(glyph)
            }
            for first in rows.indices {
                for second in rows.indices where second > first {
                    if rows[first].intersects(rows[second]) { return true }
                }
            }
        }
        return false
    }

    private struct GroupConfiguration {
        var point: CGPoint
        var font: CGFloat
        var maxWidth: CGFloat
        var alignment: Int = 0
        var weight: Font.Weight = .bold
        var nsWeight: NSFont.Weight = .bold
    }
    private static func needsExtendedComposition(scene: LyricScene, count: Int) -> Bool {
        let capacity = scene == .monument || scene == .hush || scene == .echo ? 2 : 3
        return count > capacity
    }
    private static func groupConfiguration(scene: LyricScene, index: Int, count: Int, readingRows: Bool = false) -> GroupConfiguration {
        let last = max(1, count - 1)
        let fraction = CGFloat(index) / CGFloat(last)
        if readingRows || needsExtendedComposition(scene: scene, count: count) {
            // Longer cues need their own reading order. Reusing the original
            // two/three-group anchors would stack extra phrases on one point.
            let gap = 380 / CGFloat(last)
            let emphasis = scene == .constellation ? index == count / 2 : index == 0
            let font = min(92, gap * 0.62) * (emphasis ? 1.08 : 1)
            let offset: CGFloat = scene == .hush ? -85 : (index.isMultiple(of: 2) ? -45 : 45)
            return .init(point: CGPoint(x: 500 + offset, y: 110 + fraction * 380), font: font, maxWidth: 720,
                         weight: emphasis ? .heavy : .regular, nsWeight: emphasis ? .heavy : .regular)
        }
        switch scene {
        case .monument:
            return index == 0 ? .init(point: CGPoint(x: 500, y: count == 1 ? 310 : 225), font: 176, maxWidth: 850, weight: .black, nsWeight: .black)
                : .init(point: CGPoint(x: 875, y: 430), font: 69, maxWidth: 660, alignment: 1, weight: .light, nsWeight: .light)
        case .steps:
            let x: CGFloat = index.isMultiple(of: 2) ? 390 : 610
            return .init(point: CGPoint(x: x, y: count == 1 ? 300 : 160 + fraction * 295), font: index == 1 ? 78 : 106, maxWidth: 660, weight: index == 1 ? .medium : .heavy, nsWeight: index == 1 ? .medium : .heavy)
        case .editorial:
            if index == 0 { return .init(point: CGPoint(x: 110, y: count == 1 ? 285 : 165), font: 156, maxWidth: 780, alignment: -1, weight: .black, nsWeight: .black) }
            if index == 1 { return .init(point: CGPoint(x: 840, y: 360), font: 92, maxWidth: 685, alignment: 1, weight: .semibold, nsWeight: .semibold) }
            return .init(point: CGPoint(x: 165, y: 495), font: 45, maxWidth: 675, alignment: -1, weight: .light, nsWeight: .light)
        case .diagonal:
            return .init(point: CGPoint(x: 500, y: count == 1 ? 300 : 170 + fraction * 270), font: index == 1 ? 74 : 109, maxWidth: 730, weight: index == 1 ? .regular : .heavy, nsWeight: index == 1 ? .regular : .heavy)
        case .constellation:
            if count == 1 { return .init(point: CGPoint(x: 440, y: 310), font: 120, maxWidth: 680, weight: .heavy, nsWeight: .heavy) }
            let points = count == 2 ? [CGPoint(x: 370, y: 225), CGPoint(x: 675, y: 420)] : [CGPoint(x: 340, y: 145), CGPoint(x: 700, y: 325), CGPoint(x: 390, y: 490)]
            return .init(point: points[min(index, points.count - 1)], font: index == 1 ? 93 : 74, maxWidth: 520, weight: index == 1 ? .heavy : .medium, nsWeight: index == 1 ? .heavy : .medium)
        case .hush:
            return .init(point: CGPoint(x: 130, y: count == 1 ? 370 : 330 + fraction * 112), font: index == 0 ? 70 : 46, maxWidth: 665, alignment: -1, weight: index == 0 ? .medium : .light, nsWeight: index == 0 ? .medium : .light)
        case .orbit:
            let angle = count == 1 ? 0 : -0.85 + Double(fraction) * 1.7
            return .init(point: CGPoint(x: 500 + 395 * sin(angle), y: 390 - 175 * cos(angle)), font: 77, maxWidth: count == 1 ? 700 : 285, weight: index == 1 ? .heavy : .medium, nsWeight: index == 1 ? .heavy : .medium)
        case .echo:
            return .init(point: CGPoint(x: 500, y: count == 1 ? 320 : 240 + fraction * 190), font: index == 0 ? 136 : 81, maxWidth: 790, weight: index == 0 ? .black : .light, nsWeight: index == 0 ? .black : .light)
        }
    }

    private static func pose(_ plan: StagePlan, phase: Double, audio: VisualizationAudio = .init(), stationary: Bool = false) -> [LyricTypeFragment] {
        let normalized = min(1, max(0, phase)), eased = CGFloat(smooth(normalized))
        let u: CGFloat = switch plan.motion {
        case .drift, .breathe: eased
        case .gather: 0.13 + eased * 0.74
        case .brisk: 0.08 + eased * 0.84
        }
        let drift = u - 0.5
        let elapsed = normalized * plan.duration
        let arrivalLength: Double = switch plan.motion {
        case .brisk: max(0.09, min(0.28, plan.duration * 0.18))
        case .gather: max(0.18, min(0.65, plan.duration * 0.16))
        case .drift: max(0.24, min(0.9, plan.duration * 0.17))
        case .breathe: max(0.28, min(1.05, plan.duration * 0.17))
        }
        func finiteUnit(_ value: Double) -> CGFloat { value.isFinite ? CGFloat(min(1, max(0, value))) : 0 }
        let energy = !stationary && audio.available ? finiteUnit(audio.energy) : 0
        let beat = !stationary && audio.available ? finiteUnit(audio.beat) : 0
        let bass = !stationary && audio.available ? finiteUnit(audio.bass) : 0
        let treble = !stationary && audio.available ? finiteUnit(audio.treble) : 0
        let emphasizedGroup = plan.pieces.max(by: { $0.fontSize < $1.fontSize })?.group ?? 0
        var result = plan.pieces
        for i in result.indices {
            let group = result[i].group
            let origin = plan.groupCenters[group]
            // Phrase groups settle a few milliseconds apart. This is spatial
            // choreography only; their fixed glyph positions reveal on singing time.
            let delay = Double(group) * min(0.07, plan.duration * 0.022)
            let arrival = stationary ? 1 : smooth(min(1, max(0, (elapsed - delay) / arrivalLength)))
            let entrance = CGFloat(1 - arrival)
            let direction: CGFloat = (plan.seed >> UInt64(group + 1)) & 1 == 0 ? -1 : 1
            var center = origin, scale: CGFloat = 1, rotation: Double = 0
            let extended = plan.readingRows || needsExtendedComposition(scene: plan.scene, count: plan.groupCenters.count)
            if extended {
                // Common vertical movement preserves row spacing. Horizontal
                // offsets and audio accents retain life without crossing rows.
                center.x += drift * (group.isMultiple(of: 2) ? -48 : 48)
                center.y -= u * 12
                scale = 0.98 + u * 0.045
            } else { switch plan.scene {
            case .monument:
                scale = group == 0 ? 0.84 + u * 0.30 : 0.94 + u * 0.10
                center.y -= group == 0 ? u * 65 : u * 15
                center.x += group == 0 ? drift * 30 : drift * 115
            case .steps:
                center.x += drift * (group.isMultiple(of: 2) ? -130 : 125)
                center.y -= u * 26
                scale = group == 1 ? 1.04 - u * 0.10 : 0.94 + u * 0.12
            case .editorial:
                if group == 0 { scale = 0.84 + u * 0.26; center.x += u * 22; center.y -= u * 15 }
                else { center.x -= drift * 145; center.y -= u * 25; scale = 1.02 - u * 0.06 }
            case .diagonal:
                rotation = -7 + Double(u) * 6
                let a = rotation * .pi / 180
                let x = origin.x - 500, y = origin.y - 300
                center = CGPoint(x: 500 + x * cos(a) - y * sin(a) + drift * 125, y: 300 + x * sin(a) + y * cos(a) - drift * 55)
                scale = 0.94 + u * 0.12
            case .constellation:
                center.x += drift * (group.isMultiple(of: 2) ? -145 : 120)
                center.y += CGFloat(sin(Double(u) * .pi)) * (group == 1 ? -25 : 25)
                scale = group == 1 ? 0.88 + u * 0.22 : 1.06 - u * 0.14
                rotation = group.isMultiple(of: 2) ? -4 + Double(u) * 7 : 3 - Double(u) * 6
            case .hush:
                center.x += u * 155
                center.y -= u * 92
                scale = 0.86 + u * 0.22
            case .orbit:
                let count = plan.groupCenters.count
                let initial = count == 1 ? 0 : -0.85 + Double(group) / Double(max(1, count - 1)) * 1.7
                let angle = initial + Double(u - 0.5) * 0.42
                center = CGPoint(x: 500 + 395 * sin(angle), y: 390 - 175 * cos(angle))
                rotation = angle * 7
                scale = 0.93 + u * 0.14
            case .echo:
                scale = 0.79 + u * 0.34
                center.y -= u * 62
                center.x += drift * 35
            } }
            if !stationary {
                // A brief arrival gives way to a clear, unhurried reading pose.
                // Breathing and arc drift stay small compared with letter size.
                let breath = CGFloat(sin(normalized * .pi))
                switch plan.motion {
                case .drift:
                    center.x += direction * entrance * 30
                    center.y += entrance * 22 + breath * direction * (extended ? 3 : 7)
                case .breathe:
                    let wave = CGFloat(sin(normalized * .pi * 2 + Double(group) * 0.6)) * breath
                    center.x += direction * entrance * 22 + wave * 11
                    center.y += entrance * 30 - breath * 10
                    scale *= 1 + wave * 0.018
                case .gather:
                    center.x += direction * entrance * 48
                    center.y += entrance * (group.isMultiple(of: 2) ? (extended ? 8 : 24) : (extended ? -6 : -18))
                    scale *= 0.975 + CGFloat(arrival) * 0.025 + CGFloat(sin(arrival * .pi)) * 0.012
                case .brisk:
                    center.x += direction * entrance * 52
                    center.y += entrance * 12
                    scale *= 0.98 + CGFloat(arrival) * 0.02
                }
                // Only real, available audio contributes these restrained
                // accents. They never select a scene or fabricate a tempo.
                let emphasis: CGFloat = group == emphasizedGroup ? 1 : 0.38
                scale *= 1 + energy * 0.007 + bass * 0.012 * emphasis + beat * 0.017 * emphasis
                center.x += direction * (beat * (group == emphasizedGroup ? 2 : 5) + treble * (group == emphasizedGroup ? 0 : 3))
                center.y -= energy * 2 + bass * emphasis * 2 + beat * (group == emphasizedGroup ? 4 : 2)
            }
            let a = rotation * .pi / 180
            let x = (result[i].center.x - origin.x) * scale, y = (result[i].center.y - origin.y) * scale
            result[i].center = CGPoint(x: center.x + x * cos(a) - y * sin(a), y: center.y + x * sin(a) + y * cos(a))
            result[i].rotation = rotation
            result[i].fontSize *= scale; result[i].size.width *= scale; result[i].size.height *= scale; result[i].tracking *= scale
            if !stationary, !result[i].text.allSatisfy(\.isWhitespace) {
                // A small stagger and damped return let neighboring words arrive
                // with different momentum. This is cue-entry choreography, not
                // inferred singing time; visibility follows the independent reveal clock.
                let firstID = plan.pieces.first { $0.group == group }?.id ?? i
                let ordinal = i - firstID
                let stagger = min(0.16, Double(ordinal) * 0.024)
                let q = min(1, max(0, (elapsed - delay - stagger) / min(0.72, max(0.3, plan.duration * 0.22))))
                let lift = (1 - smooth(q)) * 0.16 - sin(q * .pi) * exp(-q * 4) * 0.055
                let tilt = Double(direction) * ((1 - smooth(q)) * 1.8 - sin(q * .pi) * exp(-q * 4) * 0.65)
                result[i].center.x -= CGFloat(lift) * result[i].fontSize * sin(a)
                result[i].center.y += CGFloat(lift) * result[i].fontSize * cos(a)
                result[i].rotation += tilt
            }
            result[i].center.x = (result[i].center.x - 500) * plan.fittingScale + plan.destination.x
            result[i].center.y = (result[i].center.y - 300) * plan.fittingScale + plan.destination.y
            result[i].fontSize *= plan.fittingScale; result[i].size.width *= plan.fittingScale; result[i].size.height *= plan.fittingScale; result[i].tracking *= plan.fittingScale
            result[i].opacity = stationary ? 1 : 0.72 + arrival * 0.28
        }
        return result
    }

    private static func compatibleWords(_ line: LyricLine) -> Bool {
        // Enhanced LRC can contain simultaneous onsets and zero-duration
        // prefixes. Preserve the existing supplied-fragment display contract;
        // the accent selector validates timing separately before using gaps.
        !line.words.isEmpty && line.words.count <= 48 &&
        line.words.map(\.text).joined().filter { !$0.isWhitespace } == line.text.filter { !$0.isWhitespace }
    }

    /// Tokenize in complete sentence context before assigning spatial rows.
    /// Changing the viewport can move a lexical unit to a different row, but
    /// cannot change its estimate, positional identity or selection seed.
    private static func lexicalGroups(_ text: String, phrases: [String]) -> [[String]] {
        let units = LyricEmphasis.split(text)
        guard phrases.count > 1, !units.isEmpty else { return [units] }
        var boundaries: [Int] = [], end = 0
        for phrase in phrases { end += phrase.count; boundaries.append(end) }
        var rows: [[String]] = [], current: [String] = [], offset = 0, row = 0
        for unit in units {
            current.append(unit); offset += unit.count
            if row < boundaries.count - 1, offset >= boundaries[row] {
                rows.append(current); current = []
                while row < boundaries.count - 1, offset >= boundaries[row] { row += 1 }
            }
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    private static func phraseBudget(in size: CGSize) -> Double {
        let ratio = size.width / max(1, size.height)
        // Keep enough room for a complete short phrase even in a narrow view;
        // fitting and the reading fallback handle physical font constraints.
        return Double(min(10, max(8.5, ratio * 5.5)))
    }

    static func needsReadingLayout(line: LyricLine, in size: CGSize) -> Bool {
        textGroups(line: line, count: 3, maximumUnits: phraseBudget(in: size)).count > 6
    }

    private static func textGroups(line: LyricLine, count: Int, maximumUnits: Double) -> [[String]] {
        guard compatibleWords(line) else {
            return LyricPhrasing.phrases(line.text, targetCount: count, maximumUnits: maximumUnits).map { [$0] }
        }
        // A supplied timed word is an atomic fragment. Grouping changes only
        // its spatial row, leaving the original text, order and timing intact.
        let units = line.words.map(\.text)
        let total = units.reduce(0.0) { $0 + LyricPhrasing.widthUnits($1) }
        let desired = max(1, max(min(count, max(1, Int(total / 3))), Int(ceil(total / maximumUnits))))
        let target = min(maximumUnits, max(1, total / Double(desired)))
        var groups: [[String]] = [], current: [String] = [], length = 0.0
        for unit in units {
            let width = LyricPhrasing.widthUnits(unit)
            if !current.isEmpty, length + width > maximumUnits || (length >= target && length + width > target * 1.12) {
                groups.append(current); current = []; length = 0
            }
            current.append(unit); length += width
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    static func phrases(_ text: String, targetCount: Int) -> [String] {
        LyricPhrasing.phrases(text, targetCount: targetCount)
    }

    static func readingText(_ text: String, width: CGFloat, fontSize: CGFloat) -> String {
        let budget = Double(min(20, max(8, (width - 40) / max(1, fontSize))))
        return LyricPhrasing.phrases(text, targetCount: 1, maximumUnits: budget).reduce("") { previous, row in
            previous + (previous.isEmpty || previous.hasSuffix("\n") || previous.hasSuffix("\r") ? "" : "\n") + row
        }
    }

    static func measure(_ text: String, size: CGFloat, weight: NSFont.Weight) -> CGSize {
        let key = MeasurementKey(text: text, size: size, weight: weight.rawValue)
        if let cached = measurements[key] { return cached }
        let font = NSFont.systemFont(ofSize: max(1, size), weight: weight)
        let bounds = (text as NSString).size(withAttributes: [.font: font, .kern: -size * 0.025])
        let result = CGSize(width: ceil(bounds.width), height: ceil(max(bounds.height, font.ascender - font.descender)))
        if measurementOrder.count >= 128 { measurements.removeValue(forKey: measurementOrder.removeFirst()) }
        measurementOrder.append(key); measurements[key] = result
        return result
    }
    private static func smooth(_ value: Double) -> Double { value * value * (3 - 2 * value) }
}
