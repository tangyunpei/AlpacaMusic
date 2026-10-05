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
        let barWidth = stride * 0.63
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

    /// The dark cell lattice is a resting instrument face, not simulated data.
    /// Only measured, time-integrated levels light its cells and peak markers.
    static func draw(in context: inout GraphicsContext, size: CGSize,
                     audio: VisualizationAudio, time _: Double, glow: Bool,
                     presentation: SpectrumBarsPresentation? = nil) {
        let geometry = geometry(audio: audio, size: size, presentation: presentation)
        guard !geometry.bars.isEmpty else { return }
        context.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(Color(red: 0.013, green: 0.019, blue: 0.018)))
        let plot = geometry.plotRect
        // One visual cell scale for the instrument; compact cards use fewer
        // rows while retaining the same real frequency columns.
        let rows = Int(min(48, max(20, plot.height / 5.2)))
        let pitch = plot.height / CGFloat(rows)
        let cellHeight = pitch * 0.67
        let corner = min(0.7, cellHeight * 0.18, geometry.bars[0].rect.width * 0.12)
        var unlit = Path()
        var litRows = Array(repeating: Path(), count: rows)
        var topCells = Path()
        var peakCaps = Path()
        var heads: [(path: Path, color: Color, coverage: Double)] = []
        for bar in geometry.bars {
            let filledRows = max(0, min(Double(rows), Double(bar.rect.height / pitch)))
            for row in 0..<rows {
                let rect = CGRect(x: bar.rect.minX, y: plot.maxY - CGFloat(row + 1) * pitch,
                                  width: bar.rect.width, height: cellHeight)
                let cell = Path(roundedRect: rect, cornerRadius: corner)
                unlit.addPath(cell)
                let coverage = min(1, max(0, filledRows - Double(row)))
                if coverage >= 0.999 { litRows[row].addPath(cell) }
                else if coverage > 0.003 {
                    heads.append((cell, color(at: Double(row + 1) / Double(rows)), coverage))
                }
                if coverage > 0.08, filledRows <= Double(row + 1) { topCells.addPath(cell) }
            }
            if !bar.peakRect.isEmpty {
                peakCaps.addPath(Path(roundedRect: bar.peakRect, cornerRadius: min(0.7, bar.peakRect.height / 2)))
            }
        }
        context.fill(unlit, with: .color(Color(red: 0.36, green: 0.43, blue: 0.35).opacity(0.07)))
        for row in 0..<rows {
            guard !litRows[row].isEmpty else { continue }
            let color = color(at: Double(row + 1) / Double(rows))
            let top = plot.maxY - CGFloat(row + 1) * pitch
            context.fill(litRows[row], with: .linearGradient(Gradient(colors: [color.opacity(0.98), color.opacity(0.62)]),
                startPoint: .init(x: 0, y: top), endPoint: .init(x: 0, y: top + cellHeight)))
        }
        // Fade only the final partially lit cell; measured levels stay smooth
        // while the visible segmented structure gives clear, deliberate steps.
        for head in heads { context.fill(head.path, with: .color(head.color.opacity(pow(head.coverage, 0.75) * 0.88))) }
        if glow, !topCells.isEmpty {
            var light = context
            light.addFilter(.blur(radius: min(3, pitch * 0.44)))
            light.stroke(topCells, with: .color(Color(red: 0.85, green: 0.91, blue: 0.61).opacity(0.14)), lineWidth: min(3, pitch * 0.56))
        }
        context.fill(peakCaps, with: .color(Color(red: 0.96, green: 0.88, blue: 0.62).opacity(0.92)))
        // No numeric axes or frequency labels: the lit modules and their held
        // peaks provide the entire reading, with quiet margins around the bank.
    }

    private static func color(at level: Double) -> Color {
        if level < 0.70 { return Color(red: 0.39, green: 0.85, blue: 0.58) }
        if level < 0.89 { return Color(red: 0.98, green: 0.74, blue: 0.34) }
        return Color(red: 1.0, green: 0.43, blue: 0.30)
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
