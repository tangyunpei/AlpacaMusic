import SwiftUI

/// The geometry is derived only from signed PCM. There is no oscillation clock,
/// automatic gain, spectral reconstruction, or synthetic signal in this mode.
struct WaveformGeometry: Equatable, Sendable {
    enum State: Equatable, Sendable { case waiting, silent, signal }

    var points: [CGPoint]
    var plotRect: CGRect
    var state: State

    var centerY: CGFloat { plotRect.midY }
}

/// The widest swing of the last second or so, for the oscilloscope's
/// soft-red ticks: it rises with the trace at once and falls by e every 1.2 s
/// of animation time. A frozen frame neither raises nor lowers it.
struct OscilloscopePeakHold: Equatable, Sendable {
    static let fall = 1.2
    private(set) var peak = 0.0

    mutating func reset() { peak = 0 }

    mutating func step(dt: Double, audio: VisualizationAudio) -> Double {
        guard audio.available else { peak = 0; return peak }
        let swing = audio.waveform.lazy.filter(\.isFinite).map { min(1, abs($0)) }.max() ?? 0
        let elapsed = dt.isFinite ? max(0, dt) : 0
        guard elapsed > 0 || swing > peak else { return peak }
        peak = max(swing, peak * exp(-elapsed / Self.fall))
        return peak
    }
}

enum WaveformRenderer {
    static let paleBlue = SpectrumBarsRenderer.paleBlue
    static let yellow = SpectrumBarsRenderer.yellow
    static let softRed = SpectrumBarsRenderer.softRed
    static let cream = Color(red: 0xF1 / 255, green: 0xEB / 255, blue: 0xDD / 255)
    /// The trace's width in points.
    static let stroke: CGFloat = 1.6

    struct Layout: Equatable, Sendable {
        /// The trace runs across this rect: its middle is the centre line and
        /// its top and bottom are full scale.
        var plot: CGRect
    }

    /// Centred on the scene, on the scale of the Harmonograph's disc: full
    /// scale is 82% of a radius of 40% of the height (at most 24% of the
    /// width), and the trace runs about 1.95 radii to each side.
    static func layout(size: CGSize) -> Layout {
        let width = max(0, size.width), height = max(0, size.height)
        let centre = CGPoint(x: width / 2, y: height / 2)
        let radius = min(height * 0.40, width * 0.24)
        let half = min(width * 0.365, radius * 1.95), full = radius * 0.82
        return Layout(plot: CGRect(x: centre.x - half, y: centre.y - full, width: half * 2, height: full * 2))
    }

    /// A fixed +/-1 PCM scale leaves room for full-scale peaks and their stroke.
    /// Linear segments cannot overshoot the measured signal between samples.
    static func geometry(samples: [Double], available: Bool, size: CGSize) -> WaveformGeometry {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return .init(points: [], plotRect: .zero, state: .waiting)
        }
        let plot = layout(size: size).plot
        let resting = [CGPoint(x: plot.minX, y: plot.midY), CGPoint(x: plot.maxX, y: plot.midY)]
        guard available, !samples.isEmpty, samples.contains(where: \.isFinite) else {
            return .init(points: resting, plotRect: plot, state: .waiting)
        }
        // The upstream PCM contract is [-1, 1]. Invalid inputs never produce
        // NaN geometry, and malformed values cannot draw over the player chrome.
        let signal = samples.map { $0.isFinite ? min(1, max(-1, $0)) : 0 }
        guard signal.contains(where: { $0 != 0 }) else {
            return .init(points: resting, plotRect: plot, state: .silent)
        }
        if signal.count == 1 {
            let y = plot.midY - CGFloat(signal[0]) * plot.height / 2
            return .init(points: [.init(x: plot.minX, y: y), .init(x: plot.maxX, y: y)], plotRect: plot, state: .signal)
        }

        // At most one min/max pair per two logical pixels. Keep the original
        // temporal order and exact x positions: narrow impulses must survive
        // even when they fall between the samples a stride would have selected.
        let bucketCount = max(1, Int(min(2_048, floor(plot.width / 2))))
        var indices: [Int] = []
        if signal.count <= bucketCount * 2 + 2 {
            indices = Array(signal.indices)
        } else {
            indices.reserveCapacity(bucketCount * 2 + 2)
            indices.append(0)
            let interiorCount = signal.count - 2
            for bucket in 0..<bucketCount {
                let start = 1 + bucket * interiorCount / bucketCount
                let end = 1 + (bucket + 1) * interiorCount / bucketCount
                guard start < end else { continue }
                var low = start, high = start
                for index in start..<end {
                    if signal[index] < signal[low] { low = index }
                    if signal[index] > signal[high] { high = index }
                }
                indices.append(min(low, high))
                if low != high { indices.append(max(low, high)) }
            }
            indices.append(signal.count - 1)
        }
        let divisor = CGFloat(signal.count - 1)
        let points = indices.map { index in
            CGPoint(x: plot.minX + CGFloat(index) / divisor * plot.width,
                    y: plot.midY - CGFloat(signal[index]) * plot.height / 2)
        }
        return .init(points: points, plotRect: plot, state: .signal)
    }

    static func path(for geometry: WaveformGeometry) -> Path {
        var path = Path()
        if let first = geometry.points.first {
            path.move(to: first)
            for point in geometry.points.dropFirst() { path.addLine(to: point) }
        }
        return path
    }

    /// One trace of the measured samples (about 23 ms) at a fixed scale,
    /// drawn on the room with no screen of its own. Small ticks mark half and full scale and each quarter of
    /// the window, with no labels. The yellow dot marks where every trace
    /// starts: a rising crossing of the centre line. Soft-red ticks hold the
    /// widest swing of the last second or so. Before samples arrive, or in
    /// silence, the trace rests on its centre line.
    static func draw(in context: inout GraphicsContext, size: CGSize,
                     audio: VisualizationAudio, time _: Double, glow _: Bool,
                     peak: Double = 0, place _: EffectPlace = .room) {
        let geometry = geometry(samples: audio.waveform, available: audio.available, size: size)
        guard !geometry.points.isEmpty else { return }
        let plot = geometry.plotRect

        var rule = Path()
        rule.move(to: CGPoint(x: plot.minX, y: plot.midY)); rule.addLine(to: CGPoint(x: plot.maxX, y: plot.midY))
        context.stroke(rule, with: .color(cream.opacity(0.10)), lineWidth: 1)
        var ticks = Path()
        for level in [-1.0, -0.5, 0.5, 1.0] {
            let y = plot.midY - CGFloat(level) * plot.height / 2
            ticks.move(to: CGPoint(x: plot.midX - 5, y: y)); ticks.addLine(to: CGPoint(x: plot.midX + 5, y: y))
        }
        for quarter in 1...3 {
            let x = plot.minX + plot.width * CGFloat(quarter) / 4
            ticks.move(to: CGPoint(x: x, y: plot.midY - 3)); ticks.addLine(to: CGPoint(x: x, y: plot.midY + 3))
        }
        context.stroke(ticks, with: .color(cream.opacity(0.22)), lineWidth: 1)

        guard geometry.state == .signal else {
            // Waiting or silent: one resting line, dimmer while no samples arrive at all.
            context.stroke(rule, with: .color(paleBlue.opacity(geometry.state == .silent ? 0.55 : 0.30)),
                           style: StrokeStyle(lineWidth: stroke, lineCap: .round))
            return
        }
        let style = StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round)
        let trace = path(for: geometry)
        context.stroke(trace, with: .color(paleBlue.opacity(0.92)), style: style)
        context.fill(Path(ellipseIn: CGRect(x: plot.minX - 3.5, y: plot.midY - 3.5, width: 7, height: 7)), with: .color(yellow))
        let held = peak.isFinite ? min(1, max(0, peak)) : 0
        if held > 0.02 {
            for sign in [-1.0, 1.0] {
                let y = plot.midY - CGFloat(sign * held) * plot.height / 2
                context.fill(Path(roundedRect: CGRect(x: plot.maxX + 8, y: y - 1, width: 14, height: 2), cornerRadius: 1),
                             with: .color(softRed.opacity(0.9)))
            }
        }
    }
}
