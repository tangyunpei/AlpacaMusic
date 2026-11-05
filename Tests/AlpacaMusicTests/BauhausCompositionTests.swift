import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import AlpacaMusic

@Suite struct BauhausCompositionTests {
    private static let seeds: [UInt64] = [0, 1, 7, 42, 0xA17ACA, 0xBA0_4A05, .max]

    private static func loudAudio() -> VisualizationAudio {
        var audio = VisualizationAudio()
        audio.available = true
        audio.energy = 0.8
        audio.beat = 1
        audio.bass = 0.9
        audio.mid = 0.7
        audio.treble = 0.6
        audio.waveform = [0, 0.4, -0.4, 0.2]
        return audio
    }

    /// Scalars set on audio that is not available: they must never be used.
    private static func fabricatedAudio() -> VisualizationAudio {
        var audio = loudAudio()
        audio.available = false
        audio.spectrum = [0.4, 0.9, 0.3]
        return audio
    }

    @Test func sameSeedGivesTheSameOnBrandComposition() {
        for seed in Self.seeds {
            let layout = BauhausLayout(seed: seed)
            #expect(layout == BauhausLayout(seed: seed))
            #expect(layout.seed == seed)
            let shapes = layout.primitives
            #expect((7...BauhausLayout.maximumPrimitives).contains(shapes.count))
            #expect(shapes.filter { $0.kind == .disc && $0.ink == .red && $0.driver == .bass }.count == 1)
            #expect(shapes.filter { $0.kind == .square && $0.ink == .blue && $0.driver == .mid }.count == 1)
            #expect(shapes.filter { $0.kind == .triangle && $0.ink == .yellow }.count == 1)
            #expect(shapes.filter { $0.driver == .beat }.count == 1)
            #expect(shapes.contains { $0.kind == .bar && $0.ink == .ink })
            #expect(shapes.contains { $0.kind == .halfDisc || $0.kind == .quarterCircle })
            #expect(shapes.contains { $0.kind == .lines && $0.driver == .treble })
            #expect(shapes.contains { $0.kind == .dots && $0.driver == .treble })
            #expect(shapes.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 })
            #expect(shapes.allSatisfy { $0.size.isFinite && $0.size > 0 && $0.size < 0.9 })
            #expect(shapes.allSatisfy { $0.driftPeriod >= 28 && $0.driftPeriod <= 64 })
            #expect(layout.grain.count == BauhausLayout.grainCount)
            #expect(layout.grain.allSatisfy { $0.opacity > 0 && $0.opacity < 0.05 })
        }
    }

    @Test func differentSeedsGiveDifferentCompositions() {
        let layouts = (0..<48).map { BauhausLayout(seed: UInt64($0) &* 0x9E37_79B9) }
        for first in layouts.indices {
            for second in layouts.indices where second > first {
                #expect(layouts[first].primitives != layouts[second].primitives)
            }
        }
        // The seed chooses which primitives appear, not only where they sit.
        #expect(Set(layouts.map { $0.primitives.filter { $0.kind == .bar }.count }) == [1, 2])
        #expect(layouts.contains { $0.primitives.contains { $0.kind == .halfDisc } })
        #expect(layouts.contains { $0.primitives.contains { $0.kind == .quarterCircle } })
        #expect(layouts.contains { $0.primitives.contains { $0.kind == .ring } })
        #expect(layouts.contains { !$0.primitives.contains { $0.kind == .ring } })
    }

    @Test func posesStayFiniteInsideTheCanvasForMalformedInput() {
        let sizes = [CGSize(width: 1, height: 1), .init(width: 72, height: 44), .init(width: 320, height: 180),
                     .init(width: 1_280, height: 720), .init(width: 3_000, height: 400), .init(width: 400, height: 3_000),
                     .init(width: 1_000_000, height: 1_000_000)]
        let times: [Double] = [0, 12.5, -40, 1e12, .nan, .infinity, -.infinity]
        let drives = [BauhausDrive.zero,
                      BauhausDrive(bass: 1, mid: 1, treble: 1, energy: 1, kick: 1),
                      BauhausDrive(bass: 1e9, mid: -1e9, treble: .nan, energy: .infinity, kick: -.infinity)]
        for seed in Self.seeds {
            let layout = BauhausLayout(seed: seed)
            for size in sizes {
                let tolerance = 0.000_001 * max(1, size.width, size.height)
                for time in times {
                    for drive in drives {
                        let poses = BauhausCompositionRenderer.poses(layout: layout, size: size, time: time, drive: drive)
                        #expect(poses.count == layout.primitives.count)
                        let finite = poses.allSatisfy { pose in
                            pose.center.x.isFinite && pose.center.y.isFinite && pose.radius.isFinite && pose.size.isFinite
                                && pose.spacing.isFinite && pose.thickness.isFinite && pose.rotation.isFinite && pose.opacity.isFinite
                        }
                        #expect(finite)
                        let inside = poses.allSatisfy { pose in
                            pose.bounds.minX >= -tolerance && pose.bounds.minY >= -tolerance
                                && pose.bounds.maxX <= size.width + tolerance && pose.bounds.maxY <= size.height + tolerance
                        }
                        #expect(inside)
                        #expect(poses.allSatisfy { $0.opacity >= 0 && $0.opacity <= 1 && $0.count >= 1 && $0.count <= 8 })
                    }
                }
            }
        }
        let layout = BauhausLayout(seed: 3)
        for size in [CGSize.zero, .init(width: -10, height: 50), .init(width: CGFloat.nan, height: 100),
                     .init(width: CGFloat.infinity, height: 100)] {
            #expect(BauhausCompositionRenderer.poses(layout: layout, size: size, time: 1, drive: .zero).isEmpty)
        }
    }

    @Test func unavailableAudioAndSilenceNeverInventEnergy() {
        var unavailable = BauhausMotion()
        var silent = BauhausMotion()
        var silence = VisualizationAudio()
        silence.available = true
        silence.waveform = Array(repeating: 0, count: 1_024)
        for _ in 0..<120 {
            unavailable.step(dt: 1.0 / 60, audio: Self.fabricatedAudio())
            silent.step(dt: 1.0 / 60, audio: silence)
        }
        #expect(unavailable.drive == .zero)
        #expect(!unavailable.holdsSignal)
        #expect(silent.drive == .zero)

        // AudioLevels that are not available never reach the motion at all.
        var levels = AudioLevels()
        levels.energy = 1
        levels.beat = 1
        levels.bass = 1
        #expect(!VisualizationAudio(levels).available)
        #expect(VisualizationAudio(levels).energy == 0)

        // Audio that disappears returns straight to the ambient composition.
        var interrupted = BauhausMotion()
        for _ in 0..<30 { interrupted.step(dt: 1.0 / 60, audio: Self.loudAudio()) }
        #expect(interrupted.drive.bass > 0.3)
        interrupted.step(dt: 1.0 / 60, audio: Self.fabricatedAudio())
        #expect(interrupted.drive == .zero)

        let layout = BauhausLayout(seed: 0xA17ACA)
        let size = CGSize(width: 960, height: 540)
        let times: [Double] = [0, 3.5, 41]
        for time in times {
            let ambient = BauhausCompositionRenderer.poses(layout: layout, size: size, time: time, drive: .zero)
            #expect(BauhausCompositionRenderer.poses(layout: layout, size: size, time: time, drive: unavailable.drive) == ambient)
            #expect(BauhausCompositionRenderer.poses(layout: layout, size: size, time: time, drive: silent.drive) == ambient)
        }
    }

    @Test func eachDriverMovesOnlyItsOwnPrimitive() throws {
        let layout = BauhausLayout(seed: 0xBA0)
        let size = CGSize(width: 960, height: 540)
        let time = 10.0
        let rest = BauhausCompositionRenderer.poses(layout: layout, size: size, time: time, drive: .zero)
        func changed(_ drive: BauhausDrive) -> [Int] {
            let moved = BauhausCompositionRenderer.poses(layout: layout, size: size, time: time, drive: drive)
            return rest.indices.filter { rest[$0] != moved[$0] }
        }
        func poses(_ drive: BauhausDrive) -> [BauhausPose] {
            BauhausCompositionRenderer.poses(layout: layout, size: size, time: time, drive: drive)
        }
        let disc = try #require(layout.primitives.firstIndex { $0.kind == .disc })
        let square = try #require(layout.primitives.firstIndex { $0.kind == .square })
        let lines = try #require(layout.primitives.firstIndex { $0.kind == .lines })
        let dots = try #require(layout.primitives.firstIndex { $0.kind == .dots })
        let kicked = try #require(layout.primitives.firstIndex { $0.driver == .beat })

        #expect(changed(BauhausDrive(bass: 1)) == [disc])
        #expect(abs(Double(poses(BauhausDrive(bass: 1))[disc].size / rest[disc].size) - 1.12) < 0.000_001)

        #expect(changed(BauhausDrive(mid: 1)) == [square])
        #expect(abs(poses(BauhausDrive(mid: 1))[square].rotation - rest[square].rotation - 0.14) < 0.000_001)

        #expect(changed(BauhausDrive(treble: 1)) == [lines, dots].sorted())
        #expect(poses(BauhausDrive(treble: 1))[lines].spacing > rest[lines].spacing * 1.4)
        #expect(poses(BauhausDrive(treble: 1))[dots].opacity > rest[dots].opacity)

        #expect(changed(BauhausDrive(kick: 1)) == [kicked])
        let offset = poses(BauhausDrive(kick: 1))[kicked].center
        let distance = hypot(offset.x - rest[kicked].center.x, offset.y - rest[kicked].center.y)
        #expect(distance > 0 && distance < 0.04 * size.height)

        // Energy is a gentle breath of the whole composition.
        let breathing = poses(BauhausDrive(energy: 1))
        #expect(abs(Double(breathing[disc].size / rest[disc].size) - 1.02) < 0.000_001)
        #expect(zip(rest, breathing).allSatisfy { pair in
            hypot(pair.0.center.x - pair.1.center.x, pair.0.center.y - pair.1.center.y) < 0.02 * size.width
        })
    }

    @Test func beatKickRelaxesInAQuarterSecondAndNeedsANewBeat() {
        var audio = Self.loudAudio()
        var motion = BauhausMotion()
        let dt = 1.0 / 60
        var peak = motion.step(dt: dt, audio: audio).kick
        audio.beat = 0
        for _ in 0..<4 { peak = max(peak, motion.step(dt: dt, audio: audio).kick) }
        #expect(peak > 0.5 && peak <= 1)
        for _ in 0..<16 { motion.step(dt: dt, audio: audio) }
        #expect(motion.drive.kick < 0.1)

        // A sustained beat value is one kick, not a stream of kicks.
        var sustained = BauhausMotion()
        audio.beat = 1
        for _ in 0..<60 { sustained.step(dt: dt, audio: audio) }
        #expect(sustained.drive.kick < 0.05)
        audio.beat = 0
        sustained.step(dt: dt, audio: audio)
        audio.beat = 1
        sustained.step(dt: dt, audio: audio)
        #expect(sustained.drive.kick > 0.4)
    }

    /// The beat that reaches the stage is scaled by the player volume and
    /// eased by the clock, so a fixed level would miss quiet playback. Every
    /// rising beat must still kick, and relax before the next one.
    @Test @MainActor func everyBeatKicksAtModerateVolume() {
        let model = BauhausCompositionStageModel()
        let start = Date(timeIntervalSinceReferenceDate: 3_000)
        let period = 0.43
        let beats = 8
        var peaks = Array(repeating: 0.0, count: beats)
        var troughs = Array(repeating: 1.0, count: beats)
        let frames = Int(Double(beats) * period * 60)
        for index in 0..<frames {
            let time = Double(index) / 60
            var levels = AudioLevels()
            levels.available = true
            levels.waveform = [0, 0.1, -0.1]
            let since = time.truncatingRemainder(dividingBy: period)
            levels.beat = Float(0.5 * max(0, 1 - since / 0.35))
            let frame = model.frame(at: start.addingTimeInterval(time), trackID: "beat", animated: true, levels: levels,
                                    playing: true, captureStaticSignal: false)
            let window = min(beats - 1, Int(time / period))
            peaks[window] = max(peaks[window], frame.drive.kick)
            troughs[window] = min(troughs[window], frame.drive.kick)
        }
        #expect(peaks.allSatisfy { $0 > 0.3 })
        #expect(troughs[1..<(beats - 1)].allSatisfy { $0 < 0.1 })
    }

    @Test func frozenFramesNeitherEaseNorDecay() {
        var motion = BauhausMotion()
        for _ in 0..<10 { motion.step(dt: 1.0 / 60, audio: Self.loudAudio()) }
        let held = motion.drive
        #expect(held.kick > 0.1)
        let frozenDeltas: [Double] = [0, -1, .nan, .infinity]
        for dt in frozenDeltas {
            let withFabricated = motion.step(dt: dt, audio: Self.fabricatedAudio())
            let withEmpty = motion.step(dt: dt, audio: VisualizationAudio())
            #expect(withFabricated == held)
            #expect(withEmpty == held)
        }
        #expect(motion.drive == held)
    }

    @Test func ambientDriftIsSlowSmallAndDeterministic() {
        let layout = BauhausLayout(seed: 0xA17ACA)
        let size = CGSize(width: 1_280, height: 720)
        let origin = BauhausCompositionRenderer.poses(layout: layout, size: size, time: 0, drive: .zero)
        var previous = origin
        var moved = false
        for step in 1...240 {
            let time = Double(step) * 0.5
            let poses = BauhausCompositionRenderer.poses(layout: layout, size: size, time: time, drive: .zero)
            #expect(poses == BauhausCompositionRenderer.poses(layout: layout, size: size, time: time, drive: .zero))
            for index in poses.indices {
                let fromOrigin = hypot(poses[index].center.x - origin[index].center.x, poses[index].center.y - origin[index].center.y)
                let perStep = hypot(poses[index].center.x - previous[index].center.x, poses[index].center.y - previous[index].center.y)
                #expect(fromOrigin <= 2 * BauhausCompositionRenderer.maximumDrift + 0.001)
                // At most about 1.5 pt per second of ambient motion.
                #expect(perStep < 0.75)
                if fromOrigin > 0.5 { moved = true }
            }
            previous = poses
        }
        #expect(moved)
    }

    @Test @MainActor func stageModelCapturesOneSnapshotAndFreezes() {
        var levels = AudioLevels()
        levels.available = true
        levels.bass = 0.8
        levels.mid = 0.4
        levels.energy = 0.5
        levels.waveform = [0, 0.2, -0.2]
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        // Reduced motion during playback: one real static snapshot.
        let reduced = BauhausCompositionStageModel()
        let snapshot = reduced.frame(at: start, trackID: "a", animated: false, levels: levels, playing: true,
                                     captureStaticSignal: true)
        #expect(abs(snapshot.drive.bass - 0.8) < 0.000_01)
        #expect(snapshot.drive.kick == 0)
        var louder = levels
        louder.bass = 1
        let later = reduced.frame(at: start.addingTimeInterval(5), trackID: "a", animated: false, levels: louder,
                                  playing: true, captureStaticSignal: true)
        #expect(later == snapshot)
        // A new track captures its own real snapshot on the very next frame.
        let nextTrack = reduced.frame(at: start.addingTimeInterval(6), trackID: "b", animated: false, levels: louder,
                                      playing: true, captureStaticSignal: true)
        #expect(abs(nextTrack.drive.bass - 1) < 0.000_01)

        // Playing, then paused: the paused frames hold the last animated frame.
        let model = BauhausCompositionStageModel()
        var date = start
        var last = BauhausFrame(time: 0, drive: .zero)
        for _ in 0..<30 {
            last = model.frame(at: date, trackID: "a", animated: true, levels: levels, playing: true,
                               captureStaticSignal: false)
            date = date.addingTimeInterval(1.0 / 60)
        }
        #expect(last.time > 0.4)
        #expect(last.drive.bass > 0.3)
        model.resetFrameDate()
        let paused = model.frame(at: date.addingTimeInterval(30), trackID: "a", animated: false, levels: AudioLevels(),
                                 playing: false, captureStaticSignal: false)
        let stillPaused = model.frame(at: date.addingTimeInterval(90), trackID: "a", animated: false, levels: AudioLevels(),
                                      playing: false, captureStaticSignal: false)
        #expect(paused == last)
        #expect(stillPaused == last)

        // A new track clears the eased audio terms on the same frozen frame
        // that first shows its layout, without waiting for animation.
        let cleared = model.frame(at: date.addingTimeInterval(91), trackID: "b", animated: false, levels: AudioLevels(),
                                  playing: false, captureStaticSignal: false)
        #expect(cleared.drive == .zero)
        let nilTrack = BauhausCompositionStageModel()
        for _ in 0..<10 {
            _ = nilTrack.frame(at: date, trackID: nil, animated: true, levels: levels, playing: true,
                               captureStaticSignal: false)
            date = date.addingTimeInterval(1.0 / 60)
        }
        let toTrack = nilTrack.frame(at: date, trackID: "c", animated: false, levels: AudioLevels(), playing: false,
                                     captureStaticSignal: false)
        #expect(toTrack.drive == .zero)
        let first = model.layout(seed: 5)
        let second = model.layout(seed: 6)
        #expect(first == BauhausLayout(seed: 5))
        #expect(second == BauhausLayout(seed: 6))
    }

    @Test @MainActor func unavailablePlaybackOnlyDriftsWithTime() {
        var fabricated = AudioLevels()
        fabricated.energy = 1
        fabricated.beat = 1
        fabricated.bass = 1
        fabricated.mid = 1
        fabricated.treble = 1
        fabricated.spectrum = [0.5, 1]
        let model = BauhausCompositionStageModel()
        var date = Date(timeIntervalSinceReferenceDate: 2_000)
        var last = BauhausFrame(time: 0, drive: .zero)
        var invented = false
        for _ in 0..<45 {
            last = model.frame(at: date, trackID: "a", animated: true, levels: fabricated, playing: true,
                               captureStaticSignal: false)
            if last.drive != .zero { invented = true }
            date = date.addingTimeInterval(1.0 / 60)
        }
        #expect(!invented)
        #expect(last.time > 0.5)
    }

    /// The production renderer: real audio terms change pixels, a frozen frame
    /// renders identically, and scalars on unavailable audio change nothing.
    @Test @MainActor func renderedCompositionIgnoresFabricatedAudio() throws {
        let size = CGSize(width: 320, height: 180)
        @MainActor func pixels(_ layout: BauhausLayout, time: Double, drive: BauhausDrive, glow: Bool = true) throws -> [UInt8] {
            let view = Canvas { context, canvasSize in
                BauhausCompositionRenderer.draw(in: &context, size: canvasSize, layout: layout, time: time,
                                                drive: drive, glow: glow)
            }
            return try TemporalDesignExport.rgba(TemporalDesignExport.image(view, size: size))
        }
        let layout = BauhausLayout(seed: 0xA17ACA)
        var unavailable = BauhausMotion()
        for _ in 0..<60 { unavailable.step(dt: 1.0 / 60, audio: Self.fabricatedAudio()) }

        let ambient = try pixels(layout, time: 7, drive: .zero)
        #expect(Self.samePixels(try pixels(layout, time: 7, drive: .zero), ambient))
        #expect(Self.samePixels(try pixels(layout, time: 7, drive: unavailable.drive), ambient))

        var real = BauhausMotion()
        for _ in 0..<30 { real.step(dt: 1.0 / 60, audio: Self.loudAudio()) }
        #expect(!Self.samePixels(try pixels(layout, time: 7, drive: real.drive), ambient))
        #expect(!Self.samePixels(try pixels(layout, time: 7, drive: .zero, glow: false), ambient))
        #expect(!Self.samePixels(try pixels(BauhausLayout(seed: 0xBA0), time: 7, drive: .zero), ambient))
    }

    /// Two renders of the same frame agree to within one step per channel.
    /// After a few renders, SwiftUI's blur in the glow layer can round a
    /// handful of channels one step differently (macOS 27.2 SDK). Any real
    /// change in the frame moves thousands of channels by more than that.
    private static func samePixels(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { (x: UInt8, y: UInt8) -> Bool in abs(Int(x) - Int(y)) <= 1 }
    }
}
