import SwiftUI

struct SpectrumBar: Equatable, Sendable {
    var lowerFrequency: Double
    var upperFrequency: Double
    var magnitude: Double
    var rect: CGRect
    var peakRect: CGRect = .zero

    var centerFrequency: Double { sqrt(lowerFrequency * upperFrequency) }
}

struct SpectrumBarsGeometry: Equatable, Sendable {
    var bars: [SpectrumBar]
    var plotRect: CGRect
    var state: WaveformGeometry.State
}

enum SpectrumBarsRenderer {
    /// Logarithmic frequency bands are grounded in the FFT bin spacing. The
    /// existing spectrum is already a fixed -80...0 dB scale; this renderer
    /// never normalizes quiet audio to the height of loud audio.
    static func geometry(audio: VisualizationAudio, size: CGSize, barCount requestedCount: Int? = nil,
                         presentation: SpectrumBarsPresentation? = nil) -> SpectrumBarsGeometry {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return .init(bars: [], plotRect: .zero, state: .waiting)
        }
        let inset = size.width * 0.085
        let plot = CGRect(x: inset, y: size.height * 0.29, width: size.width - inset * 2, height: size.height * 0.43)
        let count = requestedCount.map { min(96, max(8, $0)) }
            ?? SpectrumBarsPresentation.barCount
        let hasMetadata = audio.sampleRate.isFinite && audio.sampleRate > 40
            && audio.spectrumBinWidth.isFinite && audio.spectrumBinWidth > 0
        let available = audio.available && hasMetadata && !audio.spectrum.isEmpty
            && audio.spectrum.contains(where: \.isFinite)
        let maximumFrequency = hasMetadata ? min(20_000, audio.sampleRate / 2) : 20_000
        let spectrum = available ? audio.spectrum.map { $0.isFinite ? min(1, max(0, $0)) : 0 } : []
        let measuredState: WaveformGeometry.State = !available ? .waiting
            : spectrum.contains(where: { $0 > 0 }) ? .signal : .silent
        let hasPresentation = available && presentation?.levels.count == count && presentation?.peaks.count == count
        let state = hasPresentation ? presentation!.state : measuredState
        let frequencyRatio = maximumFrequency / 20
        let stride = plot.width / CGFloat(count)
        let barWidth = stride * 0.52
        func unit(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
        let bars = (0..<count).map { index in
            let lower = 20 * pow(frequencyRatio, Double(index) / Double(count))
            let upper = 20 * pow(frequencyRatio, Double(index + 1) / Double(count))
            let magnitude = available ? bandMagnitude(spectrum: spectrum, binWidth: audio.spectrumBinWidth,
                                                       lower: lower, upper: upper) : 0
            // A fixed response curve keeps the very bottom of the dB scale
            // discreet. Heights remain monotonic and independent of time.
            let level = hasPresentation ? unit(presentation!.levels[index]) : pow(magnitude, 1.55)
            let peak = hasPresentation ? max(level, unit(presentation!.peaks[index])) : level
            let height = CGFloat(level) * plot.height
            let rect = CGRect(x: plot.minX + CGFloat(index) * stride + (stride - barWidth) / 2,
                              y: plot.maxY - height, width: barWidth, height: height)
            let peakHeight = min(1.4, size.height * 0.006)
            let cap = peak > 0.001 ? CGRect(x: rect.minX, y: max(plot.minY, plot.maxY - CGFloat(peak) * plot.height),
                                          width: barWidth, height: peakHeight) : .zero
            return SpectrumBar(lowerFrequency: lower, upperFrequency: upper, magnitude: magnitude, rect: rect, peakRect: cap)
        }
        return .init(bars: bars, plotRect: plot, state: state)
    }

    /// Continuous columns keep the frequency silhouette legible at both card
    /// and room scale. The only visible motion is the measured envelope and
    /// its held peaks; the backdrop never substitutes a decorative signal.
    static func draw(in context: inout GraphicsContext, size: CGSize,
                     audio: VisualizationAudio, time _: Double, glow: Bool,
                     presentation: SpectrumBarsPresentation? = nil) {
        let geometry = geometry(audio: audio, size: size, presentation: presentation)
        guard !geometry.bars.isEmpty else { return }
        context.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(Color(red: 0.022, green: 0.031, blue: 0.049)))
        let plot = geometry.plotRect
        guard plot.width > 0, plot.height > 0 else { return }
        let baseline = Path(CGRect(x: plot.minX, y: plot.maxY + 2,
                                   width: plot.width, height: min(0.65, size.height * 0.002)))
        context.fill(baseline, with: .linearGradient(
            Gradient(stops: [.init(color: .clear, location: 0),
                             .init(color: Color(red: 0.49, green: 0.63, blue: 0.77).opacity(0.15), location: 0.2),
                             .init(color: Color(red: 0.49, green: 0.63, blue: 0.77).opacity(0.15), location: 0.8),
                             .init(color: .clear, location: 1)]),
            startPoint: .init(x: plot.minX, y: plot.maxY),
            endPoint: .init(x: plot.maxX, y: plot.maxY)))
        var activeColumns = Path()
        for bar in geometry.bars {
            guard bar.rect.height > 0 else { continue }
            activeColumns.addPath(Path(roundedRect: bar.rect,
                cornerRadius: min(bar.rect.width / 2, bar.rect.height / 2)))
        }
        if glow, !activeColumns.isEmpty {
            var light = context
            light.addFilter(.blur(radius: min(4, max(0.4, plot.width / 210))))
            light.fill(activeColumns, with: .color(Color(red: 0.31, green: 0.70, blue: 0.91).opacity(0.10)))
        }
        for bar in geometry.bars {
            let level = Double(bar.rect.height / plot.height)
            if bar.rect.height > 0 {
                let frequency = Double((bar.rect.midX - plot.minX) / plot.width)
                let corner = min(bar.rect.width / 2, bar.rect.height / 2)
                let column = Path(roundedRect: bar.rect, cornerRadius: corner)
                // A single solid column replaces hundreds of idle cells. The
                // gradient follows its real top, so quiet audio stays small.
                let top = Color(red: 0.68 + frequency * 0.06,
                                green: 0.83 + frequency * 0.10, blue: 0.96)
                let body = Color(red: 0.24 + frequency * 0.06,
                                 green: 0.51 + frequency * 0.20, blue: 0.80 + frequency * 0.09)
                context.fill(column, with: .linearGradient(
                    Gradient(stops: [.init(color: top.opacity(0.85 + level * 0.15), location: 0),
                                     .init(color: body.opacity(0.88), location: 0.35),
                                     .init(color: body.opacity(0.28), location: 1)]),
                    startPoint: .init(x: bar.rect.midX, y: bar.rect.minY),
                    endPoint: .init(x: bar.rect.midX, y: bar.rect.maxY)))
            }
            guard !bar.peakRect.isEmpty else { continue }
            let peak = min(1, max(0, Double((plot.maxY - bar.peakRect.minY) / plot.height)))
            // Warm color is reserved for genuinely tall measured peaks, not
            // every attack. Held caps can remain after a column has decayed.
            let warmth = smoothstep(0.70, 0.93, peak)
            let peakColor = Color(red: 0.76 + warmth * 0.22,
                                  green: 0.90 - warmth * 0.17,
                                  blue: 0.99 - warmth * 0.53)
            let cap = Path(roundedRect: bar.peakRect, cornerRadius: bar.peakRect.height / 2)
            context.fill(cap, with: .color(peakColor.opacity(0.32 + sqrt(peak) * 0.62)))
        }
    }

    private static func smoothstep(_ lower: Double, _ upper: Double, _ value: Double) -> Double {
        let fraction = min(1, max(0, (value - lower) / (upper - lower)))
        return fraction * fraction * (3 - 2 * fraction)
    }

    private static func bandMagnitude(spectrum: [Double], binWidth: Double, lower: Double, upper: Double) -> Double {
        func sample(at frequency: Double) -> Double {
            let position = frequency / binWidth
            guard position >= 0, position <= Double(spectrum.count - 1) else { return 0 }
            let lowerIndex = Int(position)
            let upperIndex = min(spectrum.count - 1, lowerIndex + 1)
            let weight = position - Double(lowerIndex)
            return spectrum[lowerIndex] + (spectrum[upperIndex] - spectrum[lowerIndex]) * weight
        }
        var peak = max(sample(at: lower), sample(at: upper), sample(at: sqrt(lower * upper)))
        // Clamp before converting to Int: malformed but finite metadata must
        // not overflow when dividing Hz by an extremely small bin spacing.
        let first = Int(min(Double(spectrum.count), max(0, ceil(lower / binWidth))))
        let last = Int(min(Double(spectrum.count - 1), max(-1, floor(upper / binWidth))))
        if first <= last {
            for index in first...last { peak = max(peak, spectrum[index]) }
        }
        return peak
    }
}
