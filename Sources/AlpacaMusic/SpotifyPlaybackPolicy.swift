import Foundation

/// Polling a remote player can briefly return the previous playback after a
/// command. Only matching observations may drive local state or queue advance.
struct SpotifyPlaybackPolicy {
    enum Observation: Equatable {
        case waiting
        case matched
        case ended
        case unavailable
        case changedTrack
        case changedDevice
    }

    let expectedTrackID: String
    private(set) var deviceID: String?
    private(set) var hasPlayed = false
    private var hasMatched = false
    private var pendingPolls = 3
    private var missingPolls = 0

    mutating func observe(trackID: String?, deviceID: String?, progress: Double,
                          duration: Double, isPlaying: Bool, wantsPlayback: Bool) -> Observation {
        guard trackID == expectedTrackID else {
            if !hasMatched, pendingPolls > 0 { pendingPolls -= 1; return .waiting }
            return .changedTrack
        }
        guard let deviceID, !deviceID.isEmpty else { return missing() }
        missingPolls = 0
        if let expectedDevice = self.deviceID, expectedDevice != deviceID { return .changedDevice }
        self.deviceID = deviceID
        hasMatched = true
        if isPlaying { hasPlayed = true }
        if isPlaying, !wantsPlayback {
            if pendingPolls > 0 { pendingPolls -= 1; return .waiting }
            return .unavailable
        }
        if !isPlaying, wantsPlayback, !hasPlayed {
            if pendingPolls > 0 { pendingPolls -= 1; return .waiting }
            return .unavailable
        }
        if wantsPlayback, hasPlayed, !isPlaying, duration.isFinite, duration > 0,
           progress.isFinite, progress >= duration - 0.8 { return .ended }
        return .matched
    }

    mutating func expectCommand() { pendingPolls = 3; missingPolls = 0 }

    mutating func missing() -> Observation {
        missingPolls += 1
        return missingPolls <= 3 ? .waiting : .unavailable
    }
}
