/// Product visibility is separate from decoding, credential validation, and
/// playback support so temporarily hidden sources keep their existing data.
enum MusicSourceAvailability {
    static let sodaEnabled = false

    static func isVisible(_ source: MusicSource) -> Bool {
        source != .soda || sodaEnabled
    }
}
