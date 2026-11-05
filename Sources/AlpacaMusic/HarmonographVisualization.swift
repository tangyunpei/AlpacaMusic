import SwiftUI

/// Harmonograph: a phase portrait of the measured music. The low band's signed
/// PCM drives x and the mid band's signed PCM drives y, both from the same
/// source interval, at a fixed full scale (loud music draws a larger figure).
/// When the band traces are missing but full-band PCM exists, a short delay
/// embedding of that PCM (x = s[i], y = s[i + d]) is used instead.
///
/// This is a signal display. There is no oscillator, automatic gain, seeded
/// motion or time-driven drift: unavailable audio shows a static waiting
/// reticle, real silence a steady dot, and only a new audio frame changes the
/// curve. Phosphor trails are previous measured curves; they are appended and
/// faded only by elapsed animation time, never on frozen frames.
struct HarmonographCurve: Equatable, Sendable {
    /// Unit-square coordinates in temporal order; each coordinate is in [-1, 1]
    /// and positive y points up.
    var points: [CGPoint]
    var state: WaveformGeometry.State

    static let waiting = HarmonographCurve(points: [], state: .waiting)
}

/// One earlier measured curve and the animation time elapsed since it was the
/// newest frame.
struct HarmonographTrail: Equatable, Sendable {
    var points: [CGPoint]
    var age: Double

    /// 1 for a fresh trail, 0 once it reaches the persistence lifetime.
    var fade: Double {
        guard age.isFinite else { return 0 }
        return max(0, min(1, 1 - age / HarmonographHistory.lifetime))
    }
}

struct HarmonographPresentation: Equatable, Sendable {
    var current: HarmonographCurve
    /// Oldest first; the newest curve is `current`, not part of this list.
    var trails: [HarmonographTrail]

    static let waiting = HarmonographPresentation(current: .waiting, trails: [])
}

/// Bounded phosphor persistence. `step` is pure value logic so history,
/// freezing and expiry are testable without SwiftUI.
struct HarmonographHistory: Sendable {
    static let capacity = 10
    /// Seconds of animation time for a trail to fade out completely.
    static let lifetime = 0.18

    private(set) var trails: [HarmonographTrail] = []
    private(set) var current = HarmonographCurve.waiting

    mutating func reset() {
        trails = []
        current = .waiting
    }

    /// `dt` is the elapsed animation time of this frame. A frozen frame
    /// (dt == 0 or non-finite) neither appends nor ages trails.
    mutating func step(dt rawDT: Double, audio: VisualizationAudio) -> HarmonographPresentation {
        let next = HarmonographRenderer.trace(bass: audio.bassWaveform, mid: audio.midWaveform,
                                              full: audio.waveform, available: audio.available)
        let dt = rawDT.isFinite ? max(0, rawDT) : 0
        if dt > 0 {
            if next.state == .waiting {
                // Audio disappeared while animating: show the static waiting
                // composition instead of fading old curves on time alone.
                trails.removeAll()
            } else {
                for index in trails.indices { trails[index].age += dt }
                if current.state == .signal {
                    trails.append(HarmonographTrail(points: current.points, age: dt))
                }
                trails.removeAll { $0.age >= HarmonographHistory.lifetime }
                if trails.count > HarmonographHistory.capacity {
                    trails.removeFirst(trails.count - HarmonographHistory.capacity)
                }
            }
        }
        current = next
        return presentation
    }

    var presentation: HarmonographPresentation {
        HarmonographPresentation(current: current, trails: current.state == .waiting ? [] : trails)
    }
}

enum HarmonographRenderer {
    /// Per-curve point budget; longer buffers are decimated in temporal order.
    static let maximumPoints = 512
    /// About -80 dBFS, the same floor as the fixed-dB spectrum. Smoothed traces
    /// that have decayed below it are drawn as the steady silence dot.
    static let silenceThreshold = 0.000_1

    /// Pure unit-square curve from measured PCM. Unavailable or absent PCM is
    /// `.waiting`; nothing is synthesized from scalars or time.
    static func trace(bass: [Double], mid: [Double], full: [Double], available: Bool) -> HarmonographCurve {
        guard available else { return .waiting }
        let usesBands = !bass.isEmpty && !mid.isEmpty
        let pairCount: Int
        let delay: Int
        if usesBands {
            pairCount = min(bass.count, mid.count)
            delay = 0
        } else if !full.isEmpty {
            delay = full.count >= 2 ? max(1, full.count / 24) : 0
            pairCount = full.count - delay
        } else {
            return .waiting
        }
        guard pairCount > 0 else { return .waiting }

        let count = min(pairCount, maximumPoints)
        var points: [CGPoint] = []
        points.reserveCapacity(count)
        var peak = 0.0
        var anyFinite = false
        for step in 0..<count {
            let index = count > 1 ? step * (pairCount - 1) / (count - 1) : 0
            let rawX = usesBands ? bass[index] : full[index]
            let rawY = usesBands ? mid[index] : full[index + delay]
            if rawX.isFinite || rawY.isFinite { anyFinite = true }
            let x = rawX.isFinite ? min(1, max(-1, rawX)) : 0
            let y = rawY.isFinite ? min(1, max(-1, rawY)) : 0
            peak = max(peak, abs(x), abs(y))
            points.append(CGPoint(x: x, y: y))
        }
        guard anyFinite else { return .waiting }
        guard peak >= silenceThreshold else { return HarmonographCurve(points: [.zero], state: .silent) }
        return HarmonographCurve(points: points, state: .signal)
    }

    /// Centered square plot with a margin for strokes and reticle ticks.
    static func plotRect(size: CGSize) -> CGRect {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return .zero }
        let side = min(size.width, size.height) * 0.76
        return CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
    }

    static func canvasPoint(_ unit: CGPoint, in plot: CGRect) -> CGPoint {
        let x = unit.x.isFinite ? min(1, max(-1, unit.x)) : 0
        let y = unit.y.isFinite ? min(1, max(-1, unit.y)) : 0
        return CGPoint(x: plot.midX + x * plot.width / 2, y: plot.midY - y * plot.height / 2)
    }

    static func canvasPoints(_ unit: [CGPoint], in plot: CGRect) -> [CGPoint] {
        guard !plot.isEmpty else { return [] }
        return unit.prefix(maximumPoints).map { canvasPoint($0, in: plot) }
    }

    static func points(for curve: HarmonographCurve, size: CGSize) -> [CGPoint] {
        canvasPoints(curve.points, in: plotRect(size: size))
    }

    /// Canvas points for available PCM, for tests and exports.
    static func curve(bass: [Double], mid: [Double], full: [Double], size: CGSize) -> [CGPoint] {
        points(for: trace(bass: bass, mid: mid, full: full, available: true), size: size)
    }

    /// Smooth path through the points: line to the first midpoint, quadratic
    /// pieces between midpoints with each sample as control, line to the last
    /// point. It stays inside the points' convex hull, so inside the plot.
    /// `pieces` selects a contiguous run of the same curve (n points, n pieces).
    static func path(_ points: [CGPoint], pieces: Range<Int>? = nil) -> Path {
        var path = Path()
        let count = points.count
        guard count >= 2 else { return path }
        let range = (pieces ?? (0..<count)).clamped(to: 0..<count)
        guard !range.isEmpty else { return path }
        func midpoint(_ first: Int, _ second: Int) -> CGPoint {
            CGPoint(x: (points[first].x + points[second].x) / 2, y: (points[first].y + points[second].y) / 2)
        }
        path.move(to: range.lowerBound == 0 ? points[0] : midpoint(range.lowerBound - 1, range.lowerBound))
        for piece in range {
            if piece == count - 1 {
                path.addLine(to: points[count - 1])
            } else if piece == 0 {
                path.addLine(to: midpoint(0, 1))
            } else {
                path.addQuadCurve(to: midpoint(piece, piece + 1), control: points[piece])
            }
        }
        return path
    }

    static func draw(in context: inout GraphicsContext, size: CGSize, presentation: HarmonographPresentation, glow: Bool) {
        draw(in: &context, size: size, trails: presentation.trails, current: presentation.current, glow: glow)
    }

    /// Shared production/offscreen entry point. There is no time parameter:
    /// only measured curves can change the picture.
    static func draw(in context: inout GraphicsContext, size: CGSize,
                     trails: [HarmonographTrail], current: HarmonographCurve, glow: Bool) {
        let plot = plotRect(size: size)
        guard !plot.isEmpty else { return }
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.009, green: 0.017, blue: 0.021)))
        let waiting = current.state == .waiting
        drawReticle(in: &context, plot: plot, waiting: waiting)
        let center = CGPoint(x: plot.midX, y: plot.midY)
        if waiting {
            fillDot(in: &context, at: center, radius: 1.6, color: cream.opacity(0.26))
            return
        }

        // Phosphor persistence, oldest first: dimmer and thinner with age.
        for trail in trails.suffix(HarmonographHistory.capacity) {
            let fade = trail.fade
            guard fade > 0 else { continue }
            let trailPoints = canvasPoints(trail.points, in: plot)
            guard trailPoints.count >= 2 else { continue }
            context.stroke(path(trailPoints), with: .color(warm(0).opacity(0.5 * fade * fade)),
                           style: StrokeStyle(lineWidth: 0.5 + 0.55 * CGFloat(fade), lineCap: .round, lineJoin: .round))
        }

        let newest = canvasPoints(current.points, in: plot)
        if current.state == .silent || newest.count < 2 {
            let dot = newest.first ?? center
            if glow { fillDot(in: &context, at: dot, radius: 4.5, color: warm(0).opacity(0.08)) }
            fillDot(in: &context, at: dot, radius: 2.0, color: cream.opacity(current.state == .silent ? 0.72 : 0.92))
            return
        }
        // A nearly silent figure settles into the same steady silence dot, so
        // fades below the threshold are continuous rather than a size jump.
        let figure: CGFloat = extent(of: newest)
        let settle = Double(max(CGFloat(0), 1 - figure / 6))
        if settle > 0 {
            if glow { fillDot(in: &context, at: center, radius: 4.5, color: warm(0).opacity(0.08 * settle)) }
            fillDot(in: &context, at: center, radius: 2.0, color: cream.opacity(0.72 * settle))
        }
        if glow {
            context.stroke(path(newest), with: .color(warm(0).opacity(0.10)),
                           style: StrokeStyle(lineWidth: 3.6, lineCap: .round, lineJoin: .round))
        }
        // Earlier samples of the buffer are amber, the latest ones cream.
        let chunks = min(8, newest.count)
        for chunk in 0..<chunks {
            let lower = chunk * newest.count / chunks
            let upper = (chunk + 1) * newest.count / chunks
            guard lower < upper else { continue }
            let position = chunks > 1 ? Double(chunk) / Double(chunks - 1) : 1
            context.stroke(path(newest, pieces: lower..<upper), with: .color(warm(position).opacity(0.94)),
                           style: StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round))
        }
    }

    /// Bounding-box diagonal of canvas points, in points; 0 for an empty list.
    static func extent(of points: [CGPoint]) -> CGFloat {
        guard let first = points.first else { return 0 }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        let width = maxX - minX
        let height = maxY - minY
        let diagonal = (width * width + height * height).squareRoot()
        return diagonal.isFinite ? diagonal : 0
    }

    private static var cream: Color { Color(red: 0.97, green: 0.93, blue: 0.85) }

    /// Amber (0) to cream (1).
    private static func warm(_ position: Double) -> Color {
        let t = position.isFinite ? min(1, max(0, position)) : 1
        return Color(red: 0.89 + (0.97 - 0.89) * t, green: 0.60 + (0.93 - 0.60) * t, blue: 0.25 + (0.85 - 0.25) * t)
    }

    private static func fillDot(in context: inout GraphicsContext, at center: CGPoint, radius: CGFloat, color: Color) {
        context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                     with: .color(color))
    }

    /// Static full-scale ring with four short cardinal ticks.
    private static func drawReticle(in context: inout GraphicsContext, plot: CGRect, waiting: Bool) {
        let tone = Color(red: 0.86, green: 0.80, blue: 0.70)
        context.stroke(Path(ellipseIn: plot), with: .color(tone.opacity(waiting ? 0.075 : 0.045)),
                       style: StrokeStyle(lineWidth: 0.6))
        let radius = plot.width / 2
        let tick = max(3, radius * 0.05)
        let center = CGPoint(x: plot.midX, y: plot.midY)
        var ticks = Path()
        for direction in [CGPoint(x: 1, y: 0), CGPoint(x: -1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 0, y: -1)] {
            ticks.move(to: CGPoint(x: center.x + direction.x * (radius + 2), y: center.y + direction.y * (radius + 2)))
            ticks.addLine(to: CGPoint(x: center.x + direction.x * (radius + 2 + tick), y: center.y + direction.y * (radius + 2 + tick)))
        }
        context.stroke(ticks, with: .color(tone.opacity(waiting ? 0.10 : 0.07)), style: StrokeStyle(lineWidth: 0.6))
    }
}

/// Per-stage frame state: the shared signal clock plus the phosphor history,
/// advanced by the clock's animation-time delta only.
@MainActor final class HarmonographStageModel {
    private let clock = VisualizationClock()
    private var history = HarmonographHistory()
    private var lastTime: Double?
    private var started = false
    private var trackID: String?

    func resetFrameDate() { clock.resetFrameDate() }

    func reset() {
        clock.resetSignal()
        history.reset()
        lastTime = nil
    }

    /// Resets inline on a track change so a paused or frozen stage never keeps
    /// drawing the previous track's figure (`onChange` runs after the frame).
    func presentation(at date: Date, trackID: String?, animated: Bool, levels: AudioLevels, playing: Bool,
                      captureStaticSignal: Bool) -> HarmonographPresentation {
        if !started || trackID != self.trackID {
            started = true
            self.trackID = trackID
            reset()
        }
        return presentation(at: date, animated: animated, levels: levels, playing: playing,
                            captureStaticSignal: captureStaticSignal)
    }

    func presentation(at date: Date, animated: Bool, levels: AudioLevels, playing: Bool,
                      captureStaticSignal: Bool) -> HarmonographPresentation {
        let frame = clock.frame(at: date, animated: animated, levels: levels, playing: playing,
                                captureStaticSignal: captureStaticSignal)
        let dt = animated ? max(0, frame.time - (lastTime ?? frame.time)) : 0
        lastTime = frame.time
        return history.step(dt: dt, audio: frame.audio)
    }
}

struct HarmonographStage: View {
    let isPlaying: Bool
    let isActive: Bool
    let reduceMotion: Bool
    let lowPower: Bool
    let glow: Bool
    let seed: UInt64
    let trackID: String?
    let signal: @MainActor () -> AudioLevels
    @State private var model = HarmonographStageModel()

    private var animate: Bool { isPlaying && isActive && !reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: lowPower ? 1.0 / 30 : 1.0 / 60, paused: !animate)) { timeline in
            let levels = isPlaying && isActive ? signal() : AudioLevels()
            let presentation = model.presentation(at: timeline.date, trackID: trackID, animated: animate,
                                                  levels: levels, playing: isPlaying,
                                                  captureStaticSignal: reduceMotion && isPlaying && isActive)
            Canvas(opaque: true, rendersAsynchronously: false) { context, size in
                HarmonographRenderer.draw(in: &context, size: size, presentation: presentation, glow: glow)
            }
            .allowsHitTesting(false)
        }
        .onChange(of: animate) { _, _ in model.resetFrameDate() }
    }
}
