import Foundation

enum MusicSource: String, Codable, CaseIterable, Sendable {
    case local, appleMusic, spotify, netease, qq, soda, url, demo
    var title: String { switch self { case .local: L10n.string("本地音乐"); case .appleMusic: "Apple Music"; case .spotify: "Spotify"; case .netease: L10n.string("网易云音乐"); case .qq: L10n.string("QQ 音乐"); case .soda: L10n.string("汽水音乐"); case .url: L10n.string("音频链接"); case .demo: L10n.string("原创试听") } }
    var symbol: String { switch self { case .local: "folder"; case .appleMusic: "music.note"; case .spotify: "dot.radiowaves.left.and.right"; case .netease: "opticaldisc"; case .qq: "headphones"; case .soda: "drop"; case .url: "link"; case .demo: "waveform" } }
    var supportsAudioAnalysis: Bool { self != .appleMusic && self != .spotify }
}
enum AppleMusicResourceKind: String, Codable, Hashable, Sendable { case librarySong, catalogSong }
/// Official share pages may expose only a range of a full song. Retain that
/// identity independently of an expiring media URL and the player's local time.
struct SodaPlaybackRange: Codable, Hashable, Sendable {
    var fullDuration: Double
    var start: Double
    var duration: Double
    var isPreview: Bool
}
struct Track: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var source: MusicSource
    var sourceID: String? = nil
    var appleMusicResourceKind: AppleMusicResourceKind? = nil
    var sodaPlayback: SodaPlaybackRange? = nil
    var url: URL? = nil
    var bookmark: Data? = nil
    var artworkData: Data? = nil
    var artworkURL: URL? = nil
    var format: String? = nil
    var addedAt: Date = Date()
    var unavailable: Bool = false
}
struct MusicPlaylist: Identifiable, Codable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    var trackIDs: [String] = []
}
struct SourceConfiguration: Identifiable, Codable, Equatable, Sendable {
    var kind: MusicSource
    var endpoint: String = ""
    var enabled: Bool = false
    var id: String { kind.rawValue }
    var name: String { kind.title }
    static let defaults: [SourceConfiguration] = [.init(kind: .netease), .init(kind: .qq)]
}
struct SourceSearchResult: Sendable { var source: MusicSource; var tracks: [Track]; var error: String? = nil }
struct ImportResult: Sendable { var tracks: [Track] = []; var errors: [String] = [] }
enum PlaybackStatus: String, Sendable { case idle, loading, playing, paused, failed }
enum RepeatMode: String, Codable, CaseIterable, Sendable { case off, all, one }
struct AudioLevels: Sendable {
    var energy: Float = 0
    var beat: Float = 0
    var spectrum: [Float] = []
    var available: Bool = false
    /// Signed PCM at a fixed amplitude scale; an empty array means no current audio.
    var waveform: [Float] = []
    var amplitude: Float = 0
    var bass: Float = 0
    var mid: Float = 0
    var treble: Float = 0
    /// Time between the first and last waveform sample, in seconds.
    var waveformDuration: Double = 0
    /// Signed, fixed-gain PCM filtered into 20–250 / 250–4000 / 4000–20000 Hz.
    /// All three traces use the same source time interval as `waveform`.
    var bassWaveform: [Float] = []
    var midWaveform: [Float] = []
    var trebleWaveform: [Float] = []
    var sampleRate: Double = 0
    /// Hertz per FFT-bin index; `spectrum[0]` represents DC.
    var spectrumBinWidth: Double = 0
}
struct VisualSettings: Codable, Equatable, Sendable {
    var density: Int = 160
    var pointSize: Float = 1.8
    var depth: Float = 0.35
    var bounce: Float = 0.16
    var speed: Float = 3.5
    var frequency: Float = 4
    var idle: Float = 0.012
    var scheme: Int = 0
    var invert: Bool = false
    var glow: Bool = true
    var beatPop: Bool = true
    var autoOrbit: Bool = false
    var reduceMotion: Bool = false
    var batterySaver: Bool = true
    static let standard = VisualSettings()
    static var presets: [(name: String, settings: VisualSettings)] { [
        (L10n.string("平静"), VisualSettings(pointSize: 1.6, depth: 0.30, bounce: 0.10, speed: 2, idle: 0.015)),
        (L10n.string("跃动"), VisualSettings(pointSize: 1.9, depth: 0.35, bounce: 0.22, speed: 5, idle: 0.010)),
        (L10n.string("深邃"), VisualSettings(pointSize: 1.7, depth: 0.65, bounce: 0.14, speed: 3, idle: 0.012))
    ] }
}
struct VisualPreset: Identifiable, Codable, Sendable { var id: String = UUID().uuidString; var name: String; var settings: VisualSettings }
struct PartialPlaylistImport: Sendable {
    let tracks: [Track]
    let totalCount: Int
    let failedCount: Int
    let issues: [String]
    let message: String
}
enum MusicError: LocalizedError, Sendable {
    case message(String)
    case incompletePlaylist(PartialPlaylistImport)
    var errorDescription: String? {
        switch self {
        case .message(let message): message
        case .incompletePlaylist(let partial): partial.message
        }
    }
}
func formattedTime(_ value: Double) -> String {
    guard value.isFinite, value >= 0 else { return L10n.string("直播") }
    return String(format: "%d:%02d", Int(value) / 60, Int(value) % 60)
}
