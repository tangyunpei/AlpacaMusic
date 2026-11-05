import SwiftUI

/// A few seconds of measured spectra laid out as a landscape that recedes to a
/// horizon. Rows are captured from real FFT data only, at a fixed rate of
/// animation time, so the landscape scrolls only while measured audio keeps
/// arriving. Unavailable audio shows a static waiting horizon and real silence
/// a static silent one; nothing is synthesized from the clock, the beat or the
/// playback state.
struct SpectralHorizonHistory: Equatable, Sendable {
    struct Format: Equatable, Sendable {
        var sampleRate: Double
        var binWidth: Double
        var spectrumCount: Int
    }

    struct Columns: Equatable, Sendable {
        var format: Format
        var levels: [Double]
    }

    static let capacity = 40
    static let columnCount = 96
    static let captureInterval = 1.0 / 10
    static let lowestFrequency = 30.0
    static let highestFrequency = 16_000.0
    /// Largest number of FFT bins inspected per column; keeps huge malformed
    /// spectra from making a capture unbounded.
    private static let binsPerColumnLimit = 256

    /// Newest row first. Every row holds `columnCount` levels in 0...1.
    private(set) var rows: [[Double]] = []
    /// Animation seconds since the newest row was captured.
    private(set) var elapsed: Double = 0
    private(set) var format: Format?

    var state: WaveformGeometry.State {
        guard format != nil, !rows.isEmpty else { return .waiting }
        return rows.contains(where: { row in row.contains(where: { $0 > 0 }) }) ? .signal : .silent
    }

    /// Fraction of the capture interval since the newest row, used for a
    /// smooth recession between captures. Only advances with real audio.
    var phase: Double {
        let value = elapsed / Self.captureInterval
        return value.isFinite ? min(0.999, max(0, value)) : 0
    }

    mutating func reset() {
        rows.removeAll()
        elapsed = 0
        format = nil
    }

    /// Advances by `dt` seconds of animation time. A frozen frame (zero,
    /// negative or non-finite `dt`) never captures or scrolls. Unavailable
    /// audio clears the history to the waiting composition; a changed audio
    /// format starts over from one fresh measured row.
    mutating func advance(dt: Double, audio: VisualizationAudio) {
        let step = dt.isFinite ? min(1, max(0, dt)) : 0
        guard step > 0 else { return }
        guard let measured = Self.measure(audio) else {
            reset()
            return
        }
        if rows.isEmpty || measured.format != format {
            reset()
            format = measured.format
            rows = [measured.levels]
            return
        }
        // Real silence over an already flat landscape is a static composition:
        // nothing scrolls until measured sound returns. Silence still pushes
        // earlier measured rows back towards the horizon.
        let silentInput = !measured.levels.contains(where: { $0 > 0 })
        if silentInput, !rows.contains(where: { row in row.contains(where: { $0 > 0 }) }) { return }
        elapsed += step
        var captures = 0
        while elapsed >= Self.captureInterval, captures < Self.capacity {
            rows.insert(measured.levels, at: 0)
            elapsed -= Self.captureInterval
            captures += 1
        }
        if !(elapsed < Self.captureInterval) { elapsed = 0 }
        if rows.count > Self.capacity { rows.removeLast(rows.count - Self.capacity) }
    }

    /// Reduced motion during playback shows one real static snapshot. An
    /// existing history of the same format is retained exactly as it is.
    mutating func captureSnapshot(audio: VisualizationAudio) {
        guard let measured = Self.measure(audio) else { return }
        guard rows.isEmpty || measured.format != format else { return }
        reset()
        format = measured.format
        rows = [measured.levels]
    }

    /// Resamples a measured spectrum onto log-spaced columns between 30 Hz and
    /// 16 kHz, grounded in the FFT bin spacing. The spectrum is already on a
    /// fixed dB scale; quiet audio is never normalized up to loud audio.
    static func measure(_ audio: VisualizationAudio) -> Columns? {
        let rate = audio.sampleRate, binWidth = audio.spectrumBinWidth
        guard audio.available, rate.isFinite, rate > 40, binWidth.isFinite, binWidth > 0,
              !audio.spectrum.isEmpty else { return nil }
        let top = min(highestFrequency, max(lowestFrequency * 2, rate / 2))
        let relevant = Int(min(Double(audio.spectrum.count), max(1, ceil(top / binWidth) + 2)))
        guard audio.spectrum.prefix(relevant).contains(where: \.isFinite) else { return nil }
        let ratio = top / lowestFrequency
        var raw = [Double](repeating: 0, count: columnCount)
        for index in 0..<columnCount {
            let lower = lowestFrequency * pow(ratio, Double(index) / Double(columnCount))
            let upper = lowestFrequency * pow(ratio, Double(index + 1) / Double(columnCount))
            raw[index] = bandMagnitude(spectrum: audio.spectrum, binWidth: binWidth, lower: lower, upper: upper)
        }
        // Gentle spatial smoothing; zero stays exactly zero.
        var levels = [Double](repeating: 0, count: columnCount)
        for index in 0..<columnCount {
            let left = raw[max(0, index - 1)]
            let right = raw[min(columnCount - 1, index + 1)]
            let blended = left * 0.2 + raw[index] * 0.6 + right * 0.2
            levels[index] = pow(min(1, max(0, blended)), 1.55)
        }
        let format = Format(sampleRate: rate, binWidth: binWidth, spectrumCount: audio.spectrum.count)
        return Columns(format: format, levels: levels)
    }

    private static func bandMagnitude(spectrum: [Double], binWidth: Double, lower: Double, upper: Double) -> Double {
        let count = spectrum.count
        func value(_ index: Int) -> Double {
            let stored = spectrum[index]
            return stored.isFinite ? min(1, max(0, stored)) : 0
        }
        func sample(at frequency: Double) -> Double {
            let position = frequency / binWidth
            guard position.isFinite, position >= 0, position <= Double(count - 1) else { return 0 }
            let lowerIndex = Int(position)
            let upperIndex = min(count - 1, lowerIndex + 1)
            let weight = position - Double(lowerIndex)
            return value(lowerIndex) + (value(upperIndex) - value(lowerIndex)) * weight
        }
        var peak = max(sample(at: lower), sample(at: upper), sample(at: sqrt(lower * upper)))
        // Clamp before converting to Int: tiny bin spacing must not overflow.
        let first = Int(min(Double(count), max(0, ceil(lower / binWidth))))
        let last = Int(min(Double(count - 1), max(-1, floor(upper / binWidth))))
        if first <= last {
            let step = max(1, (last - first) / binsPerColumnLimit + 1)
            for index in stride(from: first, through: last, by: step) { peak = max(peak, value(index)) }
        }
        return peak
    }
}

struct SpectralHorizonRidge: Equatable, Sendable {
    /// Ridge top, left to right.
    var points: [CGPoint]
    var baseY: CGFloat
    var minX: CGFloat
    var maxX: CGFloat
    /// 1 at the viewer, 0 at the horizon.
    var nearness: Double
    /// Stroke emphasis; the newest ridge fades in instead of popping.
    var presence: Double = 1
}

struct SpectralHorizonGeometry: Equatable, Sendable {
    /// Back to front: farther ridges first so nearer ones occlude them.
    var ridges: [SpectralHorizonRidge]
    var horizonY: CGFloat
    var plotRect: CGRect
    var state: WaveformGeometry.State
}

enum SpectralHorizonRenderer {
    static let horizonFraction: CGFloat = 0.38
    static let nearBaseFraction: CGFloat = 0.90
    static let waitingRowCount = 9
    private static let perspective = 2.0
    private static let maximumPointsPerRidge = 512

    /// Perspective scale for a row at `depth` (0 newest, 1 oldest), normalized
    /// so the nearest row is 1 and the oldest reaches the horizon at 0.
    static func nearness(depth: Double) -> Double {
        let clamped = depth.isFinite ? min(1, max(0, depth)) : 1
        let scale = 1 / (1 + perspective * clamped)
        let farScale = 1 / (1 + perspective)
        return min(1, max(0, (scale - farScale) / (1 - farScale)))
    }

    /// Pure layout. There is no time input: only captured rows (and the phase
    /// that advances while measured audio arrives) shape the landscape. The
    /// waiting and silent states use a fixed composition of flat rows.
    static func geometry(history: SpectralHorizonHistory, size: CGSize) -> SpectralHorizonGeometry {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return .init(ridges: [], horizonY: 0, plotRect: .zero, state: .waiting)
        }
        let horizonY = size.height * horizonFraction
        let nearBase = size.height * nearBaseFraction
        let plot = CGRect(x: 0, y: horizonY, width: size.width, height: nearBase - horizonY)
        let state = history.state
        var ridges: [SpectralHorizonRidge] = []
        if state == .waiting || state == .silent {
            ridges.reserveCapacity(waitingRowCount)
            for index in stride(from: waitingRowCount - 1, through: 0, by: -1) {
                let depth = Double(index) / Double(waitingRowCount)
                ridges.append(ridge(levels: [], depth: depth, size: size, horizonY: horizonY, nearBase: nearBase))
            }
        } else {
            let rows = Array(history.rows.prefix(SpectralHorizonHistory.capacity))
            let phase = history.phase
            ridges.reserveCapacity(rows.count)
            for age in stride(from: rows.count - 1, through: 0, by: -1) {
                let depth = (Double(age) + phase) / Double(SpectralHorizonHistory.capacity)
                var shaped = ridge(levels: rows[age], depth: depth, size: size, horizonY: horizonY, nearBase: nearBase)
                if age == 0, rows.count > 1 { shaped.presence = 0.35 + 0.65 * phase }
                ridges.append(shaped)
            }
        }
        return .init(ridges: ridges, horizonY: horizonY, plotRect: plot, state: state)
    }

    private static func ridge(levels: [Double], depth: Double, size: CGSize,
                              horizonY: CGFloat, nearBase: CGFloat) -> SpectralHorizonRidge {
        let near = nearness(depth: depth)
        let t = CGFloat(near)
        let baseY = horizonY + (nearBase - horizonY) * t
        let halfWidth = size.width * (0.17 + 0.29 * t)
        let center = size.width / 2
        let amplitude = size.height * (0.012 + 0.27 * t)
        let minX = center - halfWidth, maxX = center + halfWidth
        let count = min(levels.count, maximumPointsPerRidge)
        guard count >= 2 else {
            return .init(points: [CGPoint(x: minX, y: baseY), CGPoint(x: maxX, y: baseY)],
                         baseY: baseY, minX: minX, maxX: maxX, nearness: near)
        }
        let span = halfWidth * 2 * 0.96
        let start = center - span / 2
        var points: [CGPoint] = []
        points.reserveCapacity(count)
        for index in 0..<count {
            let raw = levels[index]
            let level = raw.isFinite ? min(1, max(0, raw)) : 0
            let x = start + span * CGFloat(index) / CGFloat(count - 1)
            points.append(CGPoint(x: x, y: baseY - CGFloat(level) * amplitude))
        }
        return .init(points: points, baseY: baseY, minX: minX, maxX: maxX, nearness: near)
    }

    static func outline(for ridge: SpectralHorizonRidge) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: ridge.minX, y: ridge.baseY))
        for point in ridge.points { path.addLine(to: point) }
        path.addLine(to: CGPoint(x: ridge.maxX, y: ridge.baseY))
        return path
    }

    /// A static half disc resting on the horizon; its position comes only from
    /// the track seed and never moves with time or audio.
    static func sunCenterX(size: CGSize, seed: UInt64) -> CGFloat {
        let fraction = Double((seed >> 17) % 1_000) / 999
        return size.width * CGFloat(0.22 + 0.56 * fraction)
    }

    private static func sunPath(size: CGSize, horizonY: CGFloat, seed: UInt64) -> Path {
        let radius = min(size.width, size.height) * 0.07
        let centerX = sunCenterX(size: size, seed: seed)
        var path = Path()
        let segments = 40
        for index in 0...segments {
            let angle = Double.pi * Double(index) / Double(segments)
            let point = CGPoint(x: centerX - radius * CGFloat(cos(angle)),
                                y: horizonY - radius * CGFloat(sin(angle)))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    private static func groundColor(_ nearness: Double) -> Color {
        Color(red: 0.047 + 0.020 * nearness, green: 0.060 + 0.024 * nearness, blue: 0.090 + 0.032 * nearness)
    }

    /// Dusk blue at the horizon to warm cream at the viewer.
    private static func depthColor(_ nearness: Double) -> Color {
        let t = pow(min(1, max(0, nearness)), 0.8)
        return Color(red: 0.290 + (0.945 - 0.290) * t,
                     green: 0.400 + (0.922 - 0.400) * t,
                     blue: 0.600 + (0.867 - 0.600) * t)
    }

    /// Shared production/offscreen entry point.
    static func draw(in context: inout GraphicsContext, size: CGSize,
                     history: SpectralHorizonHistory, glow: Bool, seed: UInt64) {
        let geometry = geometry(history: history, size: size)
        guard geometry.plotRect.width > 0, geometry.plotRect.height > 0 else { return }
        let waiting = geometry.state == .waiting
        let horizonY = geometry.horizonY
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(groundColor(0)))
        context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: horizonY)), with: .linearGradient(
            Gradient(colors: [Color(red: 0.030, green: 0.038, blue: 0.060), Color(red: 0.068, green: 0.082, blue: 0.122)]),
            startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: horizonY)))
        if glow {
            let reach = size.height * 0.14
            let strength = waiting ? 0.035 : 0.085
            let warm = Color(red: 0.894, green: 0.737, blue: 0.208)
            context.fill(Path(CGRect(x: 0, y: horizonY - reach, width: size.width, height: reach * 1.3)), with: .linearGradient(
                Gradient(stops: [.init(color: warm.opacity(0), location: 0),
                                 .init(color: warm.opacity(strength), location: 0.77),
                                 .init(color: warm.opacity(0), location: 1)]),
                startPoint: CGPoint(x: 0, y: horizonY - reach),
                endPoint: CGPoint(x: 0, y: horizonY + reach * 0.3)))
        }
        let sun = sunPath(size: size, horizonY: horizonY, seed: seed)
        context.fill(sun, with: .color(Color(red: 0.722, green: 0.196, blue: 0.157).opacity(waiting ? 0.30 : 0.72)))
        var rule = Path()
        rule.move(to: CGPoint(x: 0, y: horizonY))
        rule.addLine(to: CGPoint(x: size.width, y: horizonY))
        context.stroke(rule, with: .color(Color(red: 0.945, green: 0.922, blue: 0.867).opacity(waiting ? 0.10 : 0.16)),
                       lineWidth: 0.6)
        for ridge in geometry.ridges {
            let near = ridge.nearness
            let edge = outline(for: ridge)
            var land = edge
            land.closeSubpath()
            context.fill(land, with: .color(groundColor(near)))
            let tone = depthColor(near)
            let presence = ridge.presence.isFinite ? min(1, max(0, ridge.presence)) : 1
            if glow, !waiting, near > 0.55 {
                context.stroke(edge, with: .color(tone.opacity(0.07 * presence)),
                               style: StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round))
            }
            let opacity = (waiting ? 0.10 + 0.16 * near : 0.12 + 0.80 * near) * presence
            context.stroke(edge, with: .color(tone.opacity(opacity)),
                           style: StrokeStyle(lineWidth: 0.45 + 0.85 * CGFloat(near), lineCap: .round, lineJoin: .round))
        }
    }
}

/// Per-scene state: the shared visualization clock plus the captured history.
/// Frozen frames (paused, reduced motion, inactive scene) never capture.
@MainActor final class SpectralHorizonEngine {
    private let clock = VisualizationClock()
    private(set) var history = SpectralHorizonHistory()
    private var lastTime: Double?
    private var started = false
    private var trackID: String?

    func resetFrameDate() { clock.resetFrameDate() }

    func frame(at date: Date, trackID: String?, animated: Bool, levels: AudioLevels,
               playing: Bool, captureStaticSignal: Bool) -> SpectralHorizonHistory {
        if !started || trackID != self.trackID {
            started = true
            self.trackID = trackID
            clock.resetSignal()
            history.reset()
            lastTime = nil
        }
        let frame = clock.frame(at: date, animated: animated, levels: levels, playing: playing,
                                captureStaticSignal: captureStaticSignal)
        guard animated else {
            lastTime = nil
            if captureStaticSignal { history.captureSnapshot(audio: frame.audio) }
            return history
        }
        let dt = lastTime.map { max(0, frame.time - $0) } ?? 0
        lastTime = frame.time
        history.advance(dt: dt, audio: frame.audio)
        return history
    }
}

struct SpectralHorizonStage: View {
    let isPlaying: Bool
    let isActive: Bool
    let reduceMotion: Bool
    let lowPower: Bool
    let glow: Bool
    let seed: UInt64
    let trackID: String?
    let signal: @MainActor () -> AudioLevels
    @State private var engine = SpectralHorizonEngine()

    private var animate: Bool { isPlaying && isActive && !reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: lowPower ? 1.0 / 30 : 1.0 / 60, paused: !animate)) { timeline in
            let levels = isPlaying && isActive ? signal() : AudioLevels()
            let history = engine.frame(at: timeline.date, trackID: trackID, animated: animate, levels: levels,
                                       playing: isPlaying, captureStaticSignal: reduceMotion && isPlaying && isActive)
            Canvas(opaque: true, rendersAsynchronously: false) { context, size in
                SpectralHorizonRenderer.draw(in: &context, size: size, history: history, glow: glow, seed: seed)
            }
            .allowsHitTesting(false)
        }
        .onChange(of: animate) { _, _ in engine.resetFrameDate() }
    }
}
