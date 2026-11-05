import Foundation
import Observation

/// The playback facts that decide which lyrics are loaded and how they align.
struct LyricsSyncSnapshot: Equatable, Sendable {
    var trackKey: String?
    var audioSource: LyricAudioSource?
    var position: Double
    var seekRevision: UInt64
}

/// One lyrics controller call that follows a playback change.
enum LyricsSyncAction: Equatable, Sendable {
    case load
    case setAudioSource
    case updatePosition(didSeek: Bool)
}

/// Turns the difference between two playback snapshots into lyric actions.
enum LyricsSyncPlan {
    /// The first snapshot loads lyrics and hands over the audio source. Later
    /// ones reload on a new track, hand over a changed audio source, and
    /// report a seek or a moved position once.
    static func actions(from old: LyricsSyncSnapshot?, to new: LyricsSyncSnapshot) -> [LyricsSyncAction] {
        guard let old else { return [.load, .setAudioSource] }
        var actions: [LyricsSyncAction] = []
        if old.trackKey != new.trackKey { actions.append(.load) }
        if old.audioSource != new.audioSource { actions.append(.setAudioSource) }
        if old.seekRevision != new.seekRevision {
            actions.append(.updatePosition(didSeek: true))
        } else if positionChanged(from: old.position, to: new.position) {
            actions.append(.updatePosition(didSeek: false))
        }
        return actions
    }

    /// A position that stays NaN has not moved.
    private static func positionChanged(from old: Double, to new: Double) -> Bool {
        if old.isNaN && new.isNaN { return false }
        return old != new
    }
}

/// Loads and aligns lyrics for the current track while the app runs, so the
/// mini player and the menu bar lyrics work without the main window.
@MainActor final class LyricsSync {
    private weak var player: PlayerController?
    private weak var lyrics: LyricsController?
    private var running = false
    private var generation: UInt64 = 0
    private var last: LyricsSyncSnapshot?
    private var loadTask: Task<Void, Never>?

    init(player: PlayerController, lyrics: LyricsController) {
        self.player = player
        self.lyrics = lyrics
    }

    /// Starts following playback; calling it again while running does nothing.
    func start() {
        guard !running else { return }
        running = true
        generation &+= 1
        observe(generation)
    }

    /// Stops following playback and cancels a pending lyric load.
    func stop() {
        running = false
        last = nil
        loadTask?.cancel()
        loadTask = nil
    }

    /// Reads playback, re-arms for its next change, then applies the plan.
    /// The token ends an observation chain left over from before a restart.
    private func observe(_ token: UInt64) {
        guard running, token == generation, let player, let lyrics else { return }
        let snapshot: LyricsSyncSnapshot = withObservationTracking {
            Self.makeSnapshot(of: player)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe(token) }
        }
        let actions: [LyricsSyncAction] = LyricsSyncPlan.actions(from: last, to: snapshot)
        last = snapshot
        for action in actions { perform(action, player: player, lyrics: lyrics) }
    }

    private static func makeSnapshot(of player: PlayerController) -> LyricsSyncSnapshot {
        let trackKey: String? = player.current.map { (track: Track) -> String in LyricsIdentity.key(for: track) }
        return LyricsSyncSnapshot(trackKey: trackKey, audioSource: player.lyricAudioSource,
                                  position: player.position, seekRevision: player.lyricSeekRevision)
    }

    private func perform(_ action: LyricsSyncAction, player: PlayerController, lyrics: LyricsController) {
        switch action {
        case .load:
            loadTask?.cancel()
            let track = player.current
            loadTask = Task { [weak lyrics] in
                // A load replaced before it began never runs.
                guard !Task.isCancelled else { return }
                await lyrics?.load(track: track)
            }
        case .setAudioSource:
            lyrics.setAudioSource(player.lyricAudioSource, position: player.position)
        case let .updatePosition(didSeek):
            lyrics.updateAlignmentPosition(player.position, didSeek: didSeek)
        }
    }
}
