import Foundation

/// The effects, in menu order. A saved choice of an effect that no longer
/// exists is restored as the default, because the choice is stored by name.
enum VisualizationMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case artwork, pointCloud, bauhaus, spectrumBars, waveform, spectralHorizon, harmonograph

    /// Where an effect sits in the menu.
    enum Group: CaseIterable, Identifiable, Sendable {
        case cover, shapes, liveAudio
        var id: Self { self }
        var title: String {
            switch self {
            case .cover: L10n.string("来自封面")
            case .shapes: L10n.string("图形")
            case .liveAudio: L10n.string("需要实时音频")
            }
        }
        var modes: [VisualizationMode] { VisualizationMode.allCases.filter { $0.group == self } }
    }

    static let standard = VisualizationMode.artwork

    var id: String { rawValue }
    var title: String {
        switch self {
        case .pointCloud: L10n.string("点云封面")
        case .waveform: L10n.string("音频示波器")
        case .spectrumBars: L10n.string("竖条频谱")
        case .harmonograph: L10n.string("谐波图")
        case .spectralHorizon: L10n.string("声谱地平线")
        case .bauhaus: L10n.string("包豪斯构成")
        case .artwork: L10n.string("专辑封面")
        }
    }
    var symbol: String {
        switch self {
        case .pointCloud: "square.stack.3d.up"
        case .waveform: "waveform.path"
        case .spectrumBars: "chart.bar.xaxis"
        case .harmonograph: "infinity"
        case .spectralHorizon: "mountain.2"
        case .bauhaus: "square.on.circle"
        case .artwork: "square.on.square"
        }
    }
    var group: Group {
        switch self {
        case .artwork, .pointCloud: .cover
        case .bauhaus: .shapes
        case .spectrumBars, .waveform, .spectralHorizon, .harmonograph: .liveAudio
        }
    }
    var isAudioReactive: Bool { self != .artwork }
    /// Signal displays plot measured audio and have nothing to draw without it.
    var isSignalDisplay: Bool { group == .liveAudio }
}

/// Unavailable audio never becomes synthesized energy or a fabricated spectrum.
struct VisualizationAudio: Sendable {
    var energy: Double = 0
    var beat: Double = 0
    var spectrum: [Double] = []
    var waveform: [Double] = []
    var waveformDuration: Double = 0
    var bassWaveform: [Double] = []
    var midWaveform: [Double] = []
    var trebleWaveform: [Double] = []
    var sampleRate: Double = 0
    var spectrumBinWidth: Double = 0
    var amplitude: Double = 0
    var bass: Double = 0
    var mid: Double = 0
    var treble: Double = 0
    var available = false

    init(_ levels: AudioLevels = AudioLevels(), playing: Bool = true) {
        guard playing, levels.available else { return }
        available = true
        func finite(_ value: Float) -> Double { value.isFinite ? min(1, max(0, Double(value))) : 0 }
        energy = finite(levels.energy); beat = finite(levels.beat)
        spectrum = levels.spectrum.map(finite)
        func signed(_ value: Float) -> Double { value.isFinite ? min(1, max(-1, Double(value))) : 0 }
        waveform = levels.waveform.map(signed)
        bassWaveform = levels.bassWaveform.map(signed)
        midWaveform = levels.midWaveform.map(signed)
        trebleWaveform = levels.trebleWaveform.map(signed)
        sampleRate = levels.sampleRate.isFinite ? max(0, levels.sampleRate) : 0
        spectrumBinWidth = levels.spectrumBinWidth.isFinite ? max(0, levels.spectrumBinWidth) : 0
        waveformDuration = levels.waveformDuration.isFinite ? max(0, levels.waveformDuration) : 0
        amplitude = finite(levels.amplitude)
        bass = finite(levels.bass); mid = finite(levels.mid); treble = finite(levels.treble)
    }

    func band(_ position: Double) -> Double {
        guard available, !spectrum.isEmpty, position.isFinite else { return 0 }
        let index = min(Double(spectrum.count - 1), max(0, position) * Double(spectrum.count - 1))
        let lower = Int(index), upper = min(spectrum.count - 1, lower + 1)
        return spectrum[lower] + (spectrum[upper] - spectrum[lower]) * (index - Double(lower))
    }
}
