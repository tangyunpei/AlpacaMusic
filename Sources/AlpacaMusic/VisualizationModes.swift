import Foundation

enum VisualizationMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case pointCloud, spectrumRing, ribbons, starfield, waveform, spectrumBars, artwork

    var id: String { rawValue }
    var title: String {
        switch self {
        case .pointCloud: "点云封面"
        case .spectrumRing: "轨道光场"
        case .ribbons: "流光绸缎"
        case .starfield: "深空航行"
        case .waveform: "音频示波器"
        case .spectrumBars: "竖条频谱"
        case .artwork: "专辑封面"
        }
    }
    var symbol: String {
        switch self {
        case .pointCloud: "square.stack.3d.up"
        case .spectrumRing: "circle.dotted.circle"
        case .ribbons: "water.waves"
        case .starfield: "sparkles"
        case .waveform: "waveform.path"
        case .spectrumBars: "chart.bar.xaxis"
        case .artwork: "square.on.square"
        }
    }
    var isAudioReactive: Bool { self != .artwork }
    var isSignalDisplay: Bool { self == .waveform || self == .spectrumBars }
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
