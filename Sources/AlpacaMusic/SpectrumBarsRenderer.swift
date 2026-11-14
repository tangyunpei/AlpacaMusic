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

/// Where an effect is drawn. The room gives an effect the scene between its
/// top strip and the player bar; the Now stage gives it the stage's right
/// part (or all of it once the text sits below), with the song's text beside.
enum EffectPlace: Equatable, Sendable {
    case room
    /// `stacked` runs from 0 (text beside the visual) to 1 (text below it)
    /// while the stage reshapes, so the layout glides with it.
    case stage(stacked: CGFloat)

    var stacked: CGFloat {
        guard case .stage(let value) = self, value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}

enum SpectrumBarsRenderer {
    /// The palette of the Now stage's bars: the room's pale blue, with a few
    /// yellow and soft-red columns.
    static let paleBlue = Color(red: 0xAA / 255, green: 0xC7 / 255, blue: 0xEE / 255)
    static let yellow = Color(red: 0xE4 / 255, green: 0xBC / 255, blue: 0x35 / 255)
    static let softRed = Color(red: 0xE0 / 255, green: 0x70 / 255, blue: 0x5C / 255)
    /// The disc behind the Harmonograph: lighter in the room, where the darker
    /// stage tone vanished against the room's centre glow.
    static let roomDisc = Color(red: 0x25 / 255, green: 0x2E / 255, blue: 0x3F / 255)
    static let stageDisc = Color(red: 0x17 / 255, green: 0x1E / 255, blue: 0x2B / 255)

    enum Tint: Equatable, Sendable { case blue, yellow, red }

    /// A column's colour belongs to its place in the row, the same for every
    /// song: about one in ten yellow and one in fourteen soft red.
    static func tint(column index: Int) -> Tint {
        let value = sin(Double(index + 500) * 127.1 + 11.7) * 43758.5453
        let random = value - floor(value)
        return random > 0.9 ? .yellow : random < 0.07 ? .red : .blue
    }

    static func color(_ tint: Tint) -> Color {
        switch tint {
        case .blue: paleBlue
        case .yellow: yellow
        case .red: softRed
        }
    }

    /// A column is fainter while it is short and full strength at full height.
    static func opacity(level: Double) -> Double {
        0.35 + 0.65 * (level.isFinite ? min(1, max(0, level)) : 0)
    }

    /// The mirror under the baseline: this share of a column's height, faint.
    static let mirrorShare: CGFloat = 0.38
    static let mirrorOpacity = 0.16

    struct Layout: Equatable, Sendable {
        /// The columns' row: its bottom edge is the baseline, its height a full column.
        var plot: CGRect
        var columnWidth: CGFloat
        var pitch: CGFloat
        /// The gap between the baseline and the top of the mirror.
        var mirrorGap: CGFloat
    }

    /// The height of the largest 1440 x 676 box (the room's scene in the
    /// default window) that fits in `size`: what room effects scale with.
    static func roomUnit(_ size: CGSize) -> CGFloat {
        max(0, min(size.height, size.width * 676 / 1440))
    }

    /// The room: 96 columns, 6 wide with 5 between at the default window,
    /// centred. The Now stage: columns 4 wide with 3 between across the
    /// visual's whole width.
    static func layout(size: CGSize, count: Int, place: EffectPlace) -> Layout {
        let width = max(0, size.width), height = max(0, size.height)
        let count = CGFloat(max(1, count))
        switch place {
        case .room:
            // Measured on the room frame, a 1440 x 676 scene, and scaled to the
            // largest such box that fits, centred: a tall window does not
            // stretch the bars.
            let unit = roomUnit(size)
            let baseline = height / 2 + (0.728 - 0.5) * unit
            let tall = unit * 0.503
            let plotWidth = min(width * 0.73, unit * 1.56)
            let pitch = plotWidth / count
            return Layout(plot: CGRect(x: (width - plotWidth) / 2, y: baseline - tall, width: plotWidth, height: tall),
                          columnWidth: pitch * 6 / 11, pitch: pitch, mirrorGap: 3)
        case .stage:
            let stacked = place.stacked
            // Beside the text the baseline sits at 73% of the stage; below it,
            // 40 pt above the text.
            let baseline = (height * 0.73) * (1 - stacked) + max(0, height - 40) * stacked
            let tall = max(0, min(height * 0.46, baseline - 70))
            let pitch = width / count
            return Layout(plot: CGRect(x: 0, y: baseline - tall, width: width, height: tall),
                          columnWidth: pitch * 4 / 7, pitch: pitch, mirrorGap: 3)
        }
    }

    /// Logarithmic frequency bands are grounded in the FFT bin spacing. The
    /// existing spectrum is already a fixed -80...0 dB scale; this renderer
    /// never normalizes quiet audio to the height of loud audio.
    static func geometry(audio: VisualizationAudio, size: CGSize, barCount requestedCount: Int? = nil,
                         presentation: SpectrumBarsPresentation? = nil, place: EffectPlace = .room) -> SpectrumBarsGeometry {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return .init(bars: [], plotRect: .zero, state: .waiting)
        }
        let count = requestedCount.map { min(128, max(8, $0)) }
            ?? SpectrumBarsPresentation.barCount
        let layout = layout(size: size, count: count, place: place)
        let plot = layout.plot
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
        let stride = layout.pitch
        let barWidth = layout.columnWidth
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

    /// Thin columns with rounded tops, drawn on the room or the
    /// stage with no panel of their own. A column's colour is fixed by its
    /// place in the row; its height and brightness are the measured level.
    /// Below the baseline a faint mirror repeats each column at 38%.
    static func draw(in context: inout GraphicsContext, size: CGSize,
                     audio: VisualizationAudio, time _: Double, glow _: Bool,
                     presentation: SpectrumBarsPresentation? = nil, place: EffectPlace = .room) {
        let geometry = geometry(audio: audio, size: size, presentation: presentation, place: place)
        guard !geometry.bars.isEmpty else { return }
        let layout = layout(size: size, count: geometry.bars.count, place: place)
        let plot = geometry.plotRect
        guard plot.width > 0, plot.height > 0 else { return }
        var mirror = context
        mirror.opacity = mirrorOpacity
        for (index, bar) in geometry.bars.enumerated() where bar.rect.height >= 0.5 {
            let tint = color(tint(column: index))
            let level = Double(bar.rect.height / plot.height)
            let radius = min(bar.rect.width / 2, bar.rect.height)
            let top = UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: 0,
                                             bottomTrailingRadius: 0, topTrailingRadius: radius)
            context.fill(top.path(in: bar.rect), with: .color(tint.opacity(opacity(level: level))))
            let reflection = CGRect(x: bar.rect.minX, y: plot.maxY + layout.mirrorGap,
                                    width: bar.rect.width, height: bar.rect.height * mirrorShare)
            guard reflection.height >= 0.5 else { continue }
            let bottomRadius = min(reflection.width / 2, reflection.height)
            let under = UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: bottomRadius,
                                               bottomTrailingRadius: bottomRadius, topTrailingRadius: 0)
            mirror.fill(under.path(in: reflection), with: .color(tint))
        }
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
