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

enum WaveformRenderer {
    /// A fixed +/-1 PCM scale leaves room for full-scale peaks and their stroke.
    /// Linear segments cannot overshoot the measured signal between samples.
    static func geometry(samples: [Double], available: Bool, size: CGSize) -> WaveformGeometry {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return .init(points: [], plotRect: .zero, state: .waiting)
        }
        let inset = min(size.width * 0.15, max(12, min(64, size.width * 0.055)))
        let plot = CGRect(x: inset, y: size.height * 0.16,
                          width: size.width - inset * 2, height: size.height * 0.68)
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

    /// Shared production/offscreen entry point. Time is accepted for renderer
    /// integration, but only a new PCM buffer can change the displayed trace.
    static func draw(in context: inout GraphicsContext, size: CGSize,
                     audio: VisualizationAudio, time _: Double, glow: Bool) {
        let geometry = geometry(samples: audio.waveform, available: audio.available, size: size)
        guard !geometry.points.isEmpty else { return }
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.009, green: 0.017, blue: 0.021)))

        // Three quiet horizontal references, with no animated grid or scale
        // labels competing with the signal or the enclosing player's metadata.
        for level in [-0.5, 0, 0.5] {
            let y = geometry.centerY - CGFloat(level) * geometry.plotRect.height / 2
            var rule = Path()
            rule.move(to: .init(x: geometry.plotRect.minX, y: y))
            rule.addLine(to: .init(x: geometry.plotRect.maxX, y: y))
            context.stroke(rule, with: .color(Color(red: 0.50, green: 0.69, blue: 0.72).opacity(level == 0 ? 0.065 : 0.028)),
                           style: StrokeStyle(lineWidth: 0.5))
        }
        let trace = path(for: geometry)
        let waiting = geometry.state == .waiting
        // A narrow low-opacity halo supplies separation without a blur surface
        // or a bright envelope that would turn dense PCM into a solid ribbon.
        if glow, geometry.state == .signal {
            context.stroke(trace, with: .color(Color(red: 0.34, green: 0.82, blue: 0.85).opacity(0.055)),
                           style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round))
        }
        context.stroke(trace, with: .color(Color(red: 0.76, green: 0.94, blue: 0.95).opacity(waiting ? 0.30 : 0.92)),
                       style: StrokeStyle(lineWidth: waiting ? 0.8 : 1.05, lineCap: .round, lineJoin: .round))
    }
}
