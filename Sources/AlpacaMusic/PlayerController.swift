import AVFoundation
import Foundation
import MediaPlayer
import Observation

/// Value-only queue rules are independent of decoding and network timing.
struct PlaybackQueue: Sendable {
    var tracks: [Track] = []
    var currentID: String?
    private(set) var history: [String] = []
    private var remaining: [String] = []
    private var priority: String?
    mutating func select(_ track: Track, context: [Track]? = nil) {
        if let context {
            tracks = []; for item in context + [track] where !tracks.contains(where: { $0.id == item.id }) { tracks.append(item) }
            history = []; remaining = []; priority = nil
        } else if let index = tracks.firstIndex(where: { $0.id == track.id }) { tracks[index] = track }
        else { tracks.append(track) }
        if let currentID, currentID != track.id { history.append(currentID) }
        currentID = track.id
    }
    mutating func next(shuffle: Bool, repeatMode: RepeatMode, randomUnit: Double = Double.random(in: 0..<1)) -> Track? {
        let playable = tracks.filter { !$0.unavailable }
        guard !playable.isEmpty else { return nil }
        var next = playable.first { $0.id == priority }; priority = nil
        if next == nil && shuffle {
            remaining = remaining.filter { id in id != currentID && playable.contains { $0.id == id } }
            if remaining.isEmpty {
                let visited = Set(history + [currentID].compactMap { $0 })
                remaining = playable.filter { !visited.contains($0.id) }.map(\.id)
                if remaining.isEmpty && repeatMode == .all { history = []; remaining = playable.filter { $0.id != currentID }.map(\.id) }
            }
            if !remaining.isEmpty {
                let index = min(remaining.count - 1, max(0, Int((randomUnit.isFinite ? randomUnit : 0) * Double(remaining.count))))
                let id = remaining.remove(at: index); next = playable.first { $0.id == id }
            } else if playable.count == 1 && repeatMode == .all { next = playable.first }
        } else if next == nil {
            let index = playable.firstIndex { $0.id == currentID } ?? -1
            if index + 1 < playable.count { next = playable[index + 1] }
            else if repeatMode == .all { next = playable.first }
        }
        guard let next else { return nil }
        if let currentID { history.append(currentID) }; currentID = next.id
        return next
    }
    mutating func previous(repeatMode: RepeatMode) -> Track? {
        var previous: Track?
        while previous == nil, let id = history.popLast() { previous = tracks.first { $0.id == id && !$0.unavailable } }
        if previous == nil {
            let playable = tracks.filter { !$0.unavailable }
            if let index = playable.firstIndex(where: { $0.id == currentID }), index > 0 { previous = playable[index - 1] }
            else if repeatMode == .all { previous = playable.last }
        }
        if let previous { currentID = previous.id }; return previous
    }
    mutating func enqueue(_ track: Track) { if !tracks.contains(where: { $0.id == track.id }) { tracks.append(track) } }
    mutating func playNext(_ track: Track) {
        guard track.id != currentID else { return }
        tracks.removeAll { $0.id == track.id }; let index = tracks.firstIndex { $0.id == currentID } ?? -1
        tracks.insert(track, at: index + 1); priority = track.id
    }
    mutating func remove(_ id: String) -> Track? {
        let index = tracks.firstIndex { $0.id == id } ?? 0
        tracks.removeAll { $0.id == id }; history.removeAll { $0 == id }; remaining.removeAll { $0 == id }; if priority == id { priority = nil }
        if currentID == id { currentID = tracks.dropFirst(min(index, tracks.count)).first(where: { !$0.unavailable })?.id ?? tracks.first(where: { !$0.unavailable })?.id }
        return tracks.first { $0.id == currentID }
    }
    mutating func move(_ id: String, direction: Int) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        let to = index + (direction < 0 ? -1 : 1); guard tracks.indices.contains(to) else { return }; tracks.swapAt(index, to)
    }
    mutating func resetShuffleHistory() { history = []; remaining = [] }
}

enum PlaybackFailureStage: String, Sendable {
    case preparing = "准备播放"
    case resolving = "获取播放地址"
    case opening = "打开音频"
    case playing = "播放过程中断"
}

struct PlaybackFailure: Sendable {
    let id: UUID
    let track: Track
    let stage: PlaybackFailureStage
    let message: String
    init(id: UUID = UUID(), track: Track, stage: PlaybackFailureStage, message: String) {
        self.id = id; self.track = track; self.stage = stage; self.message = message
    }
}

@MainActor @Observable
final class PlayerController {
    private(set) var current: Track?
    private(set) var queue: [Track] = []
    private(set) var status: PlaybackStatus = .idle
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var volume: Double = 0.75
    private(set) var muted = false
    private(set) var shuffle = false
    private(set) var repeatMode: RepeatMode = .off
    private(set) var failure: PlaybackFailure?
    var error: String? { failure?.message }
    var supportsVolumeControl: Bool { current?.source != .appleMusic && current?.source != .spotify }
    var sourceConfigurations = SourceConfiguration.defaults
    @ObservationIgnored private let sources: SourceService
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let spotify: SpotifyService?
    @ObservationIgnored private var spotifySession: UUID?
    @ObservationIgnored private var spotifyPolicy: SpotifyPlaybackPolicy?
    @ObservationIgnored private var spotifyPoll: Task<Void, Never>?
    @ObservationIgnored private var spotifyStopTask: Task<Void, Error>?
    @ObservationIgnored private var spotifyCommand = UUID()
    @ObservationIgnored private let appleMusic: AppleMusicService
    @ObservationIgnored private var applePrepared = false
    @ObservationIgnored private var appleHasPlayed = false
    @ObservationIgnored private var appleEndPending = false
    @ObservationIgnored private let media = AVPlayer()
    @ObservationIgnored private var analyzer = AudioAnalyzer()
    @ObservationIgnored private var navigation = PlaybackQueue()
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var wantsPlayback = false
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var failedObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var scopedURL: URL?
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var persistedSecond = -1
    @ObservationIgnored private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private struct Preferences: Codable { var volume: Double; var muted: Bool; var shuffle: Bool; var repeatMode: RepeatMode }
    private struct SavedQueue: Codable { var tracks: [Track]; var currentID: String?; var position: Double }
    private static let preferencesKey = "AlpacaMusic.NativePlayer.preferences.v1"
    private static let queueKey = "AlpacaMusic.NativePlayer.queue.v1"

    init(sources: SourceService, defaults: UserDefaults = .standard, appleMusic: AppleMusicService? = nil, spotify: SpotifyService? = nil) {
        self.sources = sources; self.defaults = defaults; self.appleMusic = appleMusic ?? AppleMusicService(defaults: defaults); self.spotify = spotify
        if let data = defaults.data(forKey: Self.preferencesKey), let prefs = try? JSONDecoder().decode(Preferences.self, from: data) {
            volume = prefs.volume.isFinite ? min(1, max(0, prefs.volume)) : 0.75; muted = prefs.muted; shuffle = prefs.shuffle; repeatMode = prefs.repeatMode
        }
        media.volume = Float(volume); media.isMuted = muted; media.automaticallyWaitsToMinimizeStalling = true
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, self != nil else { return }; self?.refreshTime()
            }
        }
        configureRemoteCommands()
    }
    // Explicit teardown keeps notification/remote command observers paired without
    // relying on nonisolated deinit access to AVFoundation objects.
    func shutdown() {
        persistQueue()
        stopSpotifyPlayback()
        preparation?.cancel(); ticker?.cancel(); ticker = nil
        generation = UUID(); wantsPlayback = false; detachItem()
        for (command, target) in remoteTargets { command.removeTarget(target) }; remoteTargets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    private func detachItem() {
        appleMusic.stopPlayback(); applePrepared = false; appleHasPlayed = false; appleEndPending = false
        observations.forEach { $0.invalidate() }; observations = []
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }; endObserver = nil
        if let failedObserver { NotificationCenter.default.removeObserver(failedObserver) }; failedObserver = nil
        media.pause(); media.replaceCurrentItem(with: nil)
        scopedURL?.stopAccessingSecurityScopedResource(); scopedURL = nil
        analyzer.reset()
    }
    func play(_ track: Track, context: [Track]? = nil) async {
        guard !track.unavailable else {
            let message = track.source == .local || track.source == .demo
                ? "这个文件暂时不可用，请重新导入。"
                : "\(track.source.title)当前未提供这首歌曲的可播放资源，请在平台确认歌曲是否仍可播放。"
            recordFailure(MusicError.message(message), track: track, stage: .preparing, fallback: message)
            return
        }
        navigation.select(track, context: context); queue = navigation.tracks
        await activate(track)
    }
    private func activate(_ track: Track, at start: Double = 0) async {
        preparation?.cancel()
        let stoppingSpotify = stopSpotifyPlayback()
        generation = UUID(); let token = generation
        wantsPlayback = true; detachItem(); analyzer = AudioAnalyzer()
        current = track; position = start.isFinite ? max(0, start) : 0; duration = track.duration; status = .loading; failure = nil
        persistQueue(); publishNowPlaying()
        let task = Task { [weak self] in
            guard let self else { return }
            var stage: PlaybackFailureStage = [.appleMusic, .spotify, .soda].contains(track.source) ? .preparing : .resolving
            var playbackTrack = track
            do {
                if let stoppingSpotify {
                    do { try await stoppingSpotify.value }
                    catch { if generation == token { spotifyStopTask = nil }; throw error }
                }
                try Task.checkCancellation(); guard generation == token else { return }
                spotifyStopTask = nil
                if track.source == .spotify {
                    guard let spotify, let trackID = track.sourceID else { throw MusicError.message("请先在音源页配置并连接 Spotify。") }
                    spotifySession = token
                    spotifyPolicy = SpotifyPlaybackPolicy(expectedTrackID: trackID)
                    stage = .opening
                    try await spotify.startPlayback(track, at: position, session: token)
                    try Task.checkCancellation(); guard generation == token else { return }
                    if !wantsPlayback { try await spotify.pausePlayback(session: token) }
                    try Task.checkCancellation(); guard generation == token else { return }
                    startSpotifyPolling(session: token)
                    return
                }
                if track.source == .appleMusic {
                    let seconds = try await appleMusic.preparePlayback(track, session: token)
                    try Task.checkCancellation(); guard generation == token else { return }
                    duration = seconds.isFinite ? max(0, seconds) : 0; applePrepared = true
                    if start.isFinite && start > 0 && duration > 0 { appleMusic.seekPlayback(to: min(start, duration)) }
                    stage = .opening
                    if wantsPlayback { try await appleMusic.resumePlayback(session: token) }
                    guard generation == token, !Task.isCancelled else { return }
                    if !wantsPlayback { appleMusic.pausePlayback(); status = .paused }
                    refreshAppleMusic(); return
                }
                playbackTrack = try await sources.preparePlayback(track)
                try Task.checkCancellation(); guard generation == token else { return }
                current = playbackTrack; duration = playbackTrack.duration
                navigation.select(playbackTrack); queue = navigation.tracks
                if playbackTrack.source == .soda, duration.isFinite, duration > 0 {
                    // A fresh official share may expose a shorter clip than the
                    // previous session. Retain seconds, never a guessed ratio.
                    position = min(duration, position)
                }
                persistQueue(); publishNowPlaying(); stage = .resolving
                let playbackStart = playbackTrack.source == .soda ? position : start
                let url = try await sources.resolve(playbackTrack, configurations: sourceConfigurations)
                try Task.checkCancellation(); guard generation == token else { return }
                stage = .opening
                if url.isFileURL, url.startAccessingSecurityScopedResource() { scopedURL = url }
                let asset = AVURLAsset(url: url)
                let item = AVPlayerItem(asset: asset)
                // Failure to analyze must never silence otherwise playable media.
                if let mix = try? await analyzer.audioMix(for: asset) { item.audioMix = mix }
                try Task.checkCancellation(); guard generation == token else { return }
                observe(item, token: token)
                media.replaceCurrentItem(with: item)
                if playbackStart.isFinite && playbackStart > 0 { await media.seek(to: CMTime(seconds: playbackStart, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
                guard generation == token, !Task.isCancelled else { return }
                if wantsPlayback { media.play() } else { status = .paused }
            } catch is CancellationError {
                // Cancellation of this activation is expected. A dependency can
                // also throw cancellation after its own account changed while
                // this activation is still live; that must leave loading state.
                guard generation == token, !Task.isCancelled else { return }
                wantsPlayback = false; spotifyStopTask = nil; relinquishSpotifyPlayback(); detachItem(); status = .failed
                let message = stoppingSpotify != nil
                    ? "Spotify 连接已变更，无法确认上一首已暂停。请在官方播放器确认后重试。"
                    : "播放连接已变更，请重新连接音源后重试。"
                recordFailure(MusicError.message(message), track: playbackTrack, stage: stage, fallback: message)
                publishNowPlaying()
            }
            catch {
                guard generation == token else { return }
                wantsPlayback = false; spotifyStopTask = nil; relinquishSpotifyPlayback(); detachItem(); status = .failed
                recordFailure(error, track: playbackTrack, stage: stage, fallback: "这首歌曲未能开始播放，请重试。")
                publishNowPlaying()
            }
        }
        preparation = task; await task.value
    }
    private func observe(_ item: AVPlayerItem, token: UUID) {
        observations.append(item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, generation == token, media.currentItem === item else { return }
                switch item.status {
                case .failed:
                    let stage: PlaybackFailureStage = status == .playing ? .playing : .opening
                    wantsPlayback = false; status = .failed
                    if let current { recordFailure(item.error, track: current, stage: stage, fallback: "音频无法播放，请检查文件或音源配置。", item: item) }
                case .readyToPlay:
                    let seconds = item.duration.seconds
                    if seconds.isFinite && seconds >= 0 { duration = seconds }
                    else if item.duration.isIndefinite { duration = .infinity }
                case .unknown: break
                @unknown default: break
                }
                publishNowPlaying()
            }
        })
        observations.append(media.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, generation == token, status != .failed else { return }
                switch media.timeControlStatus {
                case .playing: if wantsPlayback { status = .playing } else { media.pause(); status = .paused }
                case .waitingToPlayAtSpecifiedRate: status = wantsPlayback ? .loading : .paused
                case .paused: if !wantsPlayback { status = .paused }
                @unknown default: break
                }
                publishNowPlaying()
            }
        })
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, generation == token, wantsPlayback else { return }
                if repeatMode == .one, let current { await activate(current) } else { await next() }
            }
        }
        failedObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] notification in
            let underlyingError = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? any Error
            Task { @MainActor [weak self] in
                guard let self, generation == token else { return }
                wantsPlayback = false; status = .failed
                if let current { recordFailure(underlyingError, track: current, stage: .playing, fallback: "音频连接中断，请重试。", item: item) }
                publishNowPlaying()
            }
        }
    }
    private func refreshTime() {
        if current?.source == .appleMusic { refreshAppleMusic(); return }
        if current?.source == .spotify { return }
        guard current != nil, media.currentItem != nil else { return }
        let seconds = media.currentTime().seconds
        if seconds.isFinite && seconds >= 0 { position = seconds }
        if let item = media.currentItem, item.status == .readyToPlay {
            // Unknown/failed items have no measured duration yet. Preserve the
            // prepared audition range instead of presenting it as a live stream.
            let seconds = item.duration.seconds
            if seconds.isFinite && seconds >= 0 { duration = seconds } else if item.duration.isIndefinite { duration = .infinity }
            if item.status == .failed, status != .failed {
                let stage: PlaybackFailureStage = status == .playing ? .playing : .opening
                wantsPlayback = false; status = .failed
                if let current { recordFailure(item.error, track: current, stage: stage, fallback: "音频播放失败。", item: item) }
            }
        }
        let second = Int(position)
        if persistedSecond != second { persistedSecond = second; persistQueue(); publishNowPlaying() }
    }
    private func refreshAppleMusic() {
        guard applePrepared, !appleEndPending, status != .failed else { return }
        do {
            let snapshot = try appleMusic.playbackSnapshot(session: generation)
            let oldPosition = position, oldStatus = status
            if snapshot.position.isFinite && snapshot.position >= 0 { position = snapshot.position }
            let reachedEnd = duration > 0 && max(oldPosition, position) >= duration - 0.8
            // The single-entry MusicKit queue can reset playbackTime when it ends.
            // Only a real observed playback followed by completion advances our queue;
            // pauses, preparation and interruptions do not become fabricated endings.
            if wantsPlayback && appleHasPlayed &&
                ((!snapshot.hasCurrentEntry && snapshot.state == .stopped) ||
                 (reachedEnd && snapshot.state == .stopped)) {
                appleEndPending = true; position = duration; let token = generation
                Task { [weak self] in
                    guard let self, generation == token else { return }
                    if repeatMode == .one, let current { await activate(current) }
                    else { await next(); if generation == token { appleEndPending = false } }
                }
                return
            }
            switch snapshot.state {
            case .playing:
                appleHasPlayed = true
                if wantsPlayback { status = .playing } else { appleMusic.pausePlayback(); status = .paused }
            case .paused, .stopped:
                if !wantsPlayback || appleHasPlayed { status = .paused; wantsPlayback = false }
            case .interrupted: status = .paused; wantsPlayback = false
            case .seeking: status = wantsPlayback ? .loading : .paused
            }
            let second = Int(position)
            if persistedSecond != second { persistedSecond = second; persistQueue(); publishNowPlaying() }
            else if oldStatus != status { publishNowPlaying() }
        } catch {
            wantsPlayback = false; appleMusic.stopPlayback(); applePrepared = false
            status = .failed
            if let current { recordFailure(error, track: current, stage: .playing, fallback: "Apple Music 播放中断，请重试。") }
            publishNowPlaying()
        }
    }
    /// A source transition waits for this task before starting another player.
    /// Clear/remove/shutdown can enqueue it without blocking the main thread.
    @discardableResult private func stopSpotifyPlayback() -> Task<Void, Error>? {
        spotifyPoll?.cancel(); spotifyPoll = nil; spotifyCommand = UUID()
        guard let session = spotifySession, let spotify else { return spotifyStopTask }
        spotifySession = nil; spotifyPolicy = nil
        let previous = spotifyStopTask
        let task = Task {
            if let previous { _ = await previous.result }
            defer { spotify.releasePlayback() }
            try await spotify.pausePlayback(session: session)
        }
        spotifyStopTask = task
        return task
    }

    private func relinquishSpotifyPlayback() {
        spotifyPoll?.cancel(); spotifyPoll = nil; spotifyCommand = UUID()
        if spotifySession != nil { spotify?.releasePlayback() }
        spotifySession = nil; spotifyPolicy = nil
    }

    private func failSpotifyPlayback(_ error: any Error, fallback: String) {
        wantsPlayback = false; relinquishSpotifyPlayback(); status = .failed
        if let current { recordFailure(error, track: current, stage: .playing, fallback: fallback) }
        persistQueue(); publishNowPlaying()
    }

    private func startSpotifyPolling(session: UUID) {
        spotifyPoll?.cancel()
        guard let spotify, spotifySession == session, generation == session else { return }
        spotifyPoll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, generation == session, spotifySession == session else { return }
                do {
                    let snapshot = try await spotify.playbackSnapshot(session: session)
                    try Task.checkCancellation()
                    guard generation == session, spotifySession == session, var policy = spotifyPolicy else { return }
                    let observation: SpotifyPlaybackPolicy.Observation
                    if let snapshot {
                        observation = policy.observe(trackID: snapshot.trackID, deviceID: snapshot.deviceID,
                                                     progress: snapshot.progress, duration: snapshot.duration,
                                                     isPlaying: snapshot.isPlaying, wantsPlayback: wantsPlayback)
                    } else { observation = policy.missing() }
                    spotifyPolicy = policy
                    switch observation {
                    case .waiting: break
                    case .matched:
                        guard let snapshot else { return }
                        if snapshot.progress.isFinite { position = max(0, snapshot.progress) }
                        if snapshot.duration.isFinite, snapshot.duration > 0 { duration = snapshot.duration }
                        status = snapshot.isPlaying ? .playing : .paused
                        if !snapshot.isPlaying { wantsPlayback = false }
                        persistQueue(); publishNowPlaying()
                    case .ended:
                        position = duration; persistQueue()
                        // Advance from a separate task: activate cancels this polling task.
                        Task { [weak self] in
                            guard let self, generation == session, spotifySession == session else { return }
                            if repeatMode == .one, let current { await activate(current) }
                            else { await next() }
                        }
                        return
                    case .changedTrack:
                        failSpotifyPlayback(MusicError.message("Spotify 官方播放器已切换歌曲，AlpacaMusic 已停止控制。请在这里重新选歌以继续。"), fallback: "Spotify 已切换歌曲。")
                        return
                    case .changedDevice:
                        failSpotifyPlayback(MusicError.message("Spotify 已切换播放设备，AlpacaMusic 已停止控制。请确认音源页中的设备后重新播放。"), fallback: "Spotify 已切换设备。")
                        return
                    case .unavailable:
                        failSpotifyPlayback(MusicError.message("未能确认 Spotify 的播放状态，请检查官方播放器和所选设备后重试。"), fallback: "Spotify 播放状态不可用。")
                        return
                    }
                } catch is CancellationError {
                    if generation == session, spotifySession == session, !Task.isCancelled {
                        failSpotifyPlayback(MusicError.message("Spotify 连接已变更，请重新连接后播放。"), fallback: "Spotify 连接已变更。")
                    }
                    return
                }
                catch {
                    guard generation == session, spotifySession == session, !Task.isCancelled else { return }
                    failSpotifyPlayback(error, fallback: "Spotify 播放连接中断，请重试。")
                    return
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    func toggle() async {
        if wantsPlayback && (status == .playing || status == .loading) { pause(); return }
        guard let current else { if let first = queue.first(where: { !$0.unavailable }) { await play(first) }; return }
        if current.source == .spotify {
            let resumePosition = duration.isFinite && duration > 0 && position >= duration - 0.05 ? 0 : position
            await activate(current, at: resumePosition); return
        }
        if current.source == .appleMusic {
            if !applePrepared || status == .failed { await activate(current, at: position); return }
            wantsPlayback = true; appleHasPlayed = false; failure = nil; status = .loading; let token = generation
            if duration.isFinite && duration > 0 && position >= duration - 0.05 { appleMusic.seekPlayback(to: 0); position = 0 }
            do {
                try await appleMusic.resumePlayback(session: token)
                guard generation == token else { return }
                if !wantsPlayback { appleMusic.pausePlayback() }
                refreshAppleMusic()
            } catch is CancellationError { }
            catch {
                guard generation == token else { return }; wantsPlayback = false; status = .failed
                recordFailure(error, track: current, stage: .opening, fallback: "Apple Music 未能恢复播放，请重试。")
            }
            publishNowPlaying(); return
        }
        if media.currentItem == nil || status == .failed { await activate(current, at: position); return }
        wantsPlayback = true; failure = nil; status = .loading
        if duration.isFinite && duration > 0 && position >= duration - 0.05 { await media.seek(to: .zero) }
        media.play(); publishNowPlaying()
    }
    /// Disconnect waits for owned remote playback to stop before clearing tokens.
    /// Other sources and externally selected Spotify playback are left alone.
    func pauseAndWaitForSpotify() async {
        let isSpotifyCurrent = current?.source == .spotify
        // activate updates current before awaiting the old remote stop. Account
        // disconnect must await that dependency even when current is now local.
        guard isSpotifyCurrent || spotifyStopTask != nil else { return }
        let token = generation
        if isSpotifyCurrent { wantsPlayback = false }
        let stopping = isSpotifyCurrent ? stopSpotifyPlayback() : spotifyStopTask
        do {
            if let stopping { try await stopping.value }
            guard generation == token else { return }
            spotifyStopTask = nil
            if isSpotifyCurrent { status = .paused; persistQueue(); publishNowPlaying() }
        } catch {
            guard generation == token else { return }
            spotifyStopTask = nil
            // A transition owns its dependency error; do not overwrite the
            // newer source's status or failure while waiting for disconnect.
            if isSpotifyCurrent {
                failSpotifyPlayback(error, fallback: "Spotify 暂停失败，请在官方播放器确认播放状态。")
            }
        }
    }

    func pause() {
        wantsPlayback = false
        if current?.source == .spotify, let spotify, let session = spotifySession {
            spotifyPoll?.cancel(); spotifyPoll = nil; spotifyPolicy?.expectCommand()
            let command = UUID(); spotifyCommand = command
            status = .loading
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await spotify.pausePlayback(session: session)
                    guard generation == session, spotifySession == session, spotifyCommand == command else { return }
                    status = .paused; persistQueue(); publishNowPlaying()
                    startSpotifyPolling(session: session)
                } catch is CancellationError {
                    if generation == session, spotifySession == session, spotifyCommand == command, !Task.isCancelled {
                        failSpotifyPlayback(MusicError.message("Spotify 连接已变更，请重新连接后播放。"), fallback: "Spotify 连接已变更。")
                    }
                }
                catch {
                    guard generation == session, spotifySession == session, spotifyCommand == command else { return }
                    failSpotifyPlayback(error, fallback: "Spotify 暂停失败，请在官方播放器确认播放状态。")
                }
            }
            publishNowPlaying(); return
        }
        media.pause(); appleMusic.pausePlayback(); if current != nil { status = .paused }
        persistQueue(); publishNowPlaying()
    }
    func next() async {
        guard let track = navigation.next(shuffle: shuffle, repeatMode: repeatMode) else { pause(); return }
        await activate(track)
    }
    func previous() async {
        if position > 3 && duration.isFinite { seek(to: 0); return }
        if let track = navigation.previous(repeatMode: repeatMode) { await activate(track) } else { seek(to: 0) }
    }
    func seek(to seconds: Double) {
        guard seconds.isFinite, duration.isFinite, duration > 0 else { return }
        if current?.source == .spotify {
            guard let spotify, let session = spotifySession else { return }
            let target = min(duration, max(0, seconds)), command = UUID()
            spotifyCommand = command; spotifyPoll?.cancel(); spotifyPoll = nil
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await spotify.seekPlayback(to: target, session: session)
                    guard generation == session, spotifySession == session, spotifyCommand == command else { return }
                    position = target; persistQueue(); publishNowPlaying()
                    startSpotifyPolling(session: session)
                } catch is CancellationError {
                    if generation == session, spotifySession == session, spotifyCommand == command, !Task.isCancelled {
                        failSpotifyPlayback(MusicError.message("Spotify 连接已变更，请重新连接后播放。"), fallback: "Spotify 连接已变更。")
                    }
                }
                catch {
                    guard generation == session, spotifySession == session, spotifyCommand == command else { return }
                    failSpotifyPlayback(error, fallback: "Spotify 未能跳转，请重试。")
                }
            }
            return
        }
        if current?.source == .appleMusic {
            guard applePrepared else { return }
            position = min(duration, max(0, seconds)); appleMusic.seekPlayback(to: position); persistQueue(); publishNowPlaying(); return
        }
        guard media.currentItem?.status == .readyToPlay else { return }
        position = min(duration, max(0, seconds)); media.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        analyzer.reset(); persistQueue(); publishNowPlaying()
    }
    func setVolume(_ value: Double) {
        guard supportsVolumeControl, value.isFinite else { return }
        volume = min(1, max(0, value)); media.volume = Float(volume)
        if volume > 0 { muted = false; media.isMuted = false }
        persistPreferences()
    }
    func toggleMute() { guard supportsVolumeControl else { return }; muted.toggle(); media.isMuted = muted; persistPreferences() }
    func toggleShuffle() { shuffle.toggle(); navigation.resetShuffleHistory(); persistPreferences() }
    func cycleRepeat() { repeatMode = repeatMode == .off ? .all : repeatMode == .all ? .one : .off; persistPreferences() }
    func enqueue(_ track: Track) { navigation.enqueue(track); queue = navigation.tracks; persistQueue() }
    func playNext(_ track: Track) { navigation.playNext(track); queue = navigation.tracks; persistQueue() }
    func removeFromQueue(_ id: String) {
        let isCurrent = current?.id == id, wasPlaying = wantsPlayback
        let replacement = navigation.remove(id); queue = navigation.tracks
        if isCurrent {
            stopSpotifyPlayback()
            preparation?.cancel(); generation = UUID(); wantsPlayback = false; detachItem()
            current = replacement; position = 0; duration = replacement?.duration ?? 0; status = replacement == nil ? .idle : .paused; failure = nil
            if let replacement, wasPlaying { let token = generation; Task { guard generation == token else { return }; await activate(replacement) } }
        }
        persistQueue(); publishNowPlaying()
    }
    func moveInQueue(_ id: String, direction: Int) { navigation.move(id, direction: direction); queue = navigation.tracks; persistQueue() }
    func clearQueue() {
        stopSpotifyPlayback()
        preparation?.cancel(); generation = UUID(); wantsPlayback = false; detachItem(); navigation = PlaybackQueue()
        queue = []; current = nil; position = 0; duration = 0; status = .idle; failure = nil; persistQueue(); publishNowPlaying()
    }
    func retry() async {
        guard let target = failure?.track ?? current else { return }
        if target.id == current?.id, !target.unavailable { await activate(target, at: position) }
        else { await play(target) }
    }
    private func recordFailure(_ error: (any Error)?, track: Track, stage: PlaybackFailureStage,
                               fallback: String, item: AVPlayerItem? = nil) {
        let reported = PlaybackFailure(track: track, stage: stage,
                                       message: PlaybackErrorMessage.describe(error, source: track.source, fallback: fallback))
        failure = reported
        // macOS 26 reports the item's NSError chain immediately. On macOS 27,
        // enrich it with the nonblocking log API without reviving an old failure.
        if #available(macOS 27.0, *), let item {
            let token = generation
            Task { [weak self] in
                let log = await item.errorLog
                guard let self, generation == token, media.currentItem === item,
                      failure?.id == reported.id else { return }
                let facts = log?.events.suffix(3).map {
                    PlaybackErrorLogFact(domain: $0.errorDomain, code: $0.errorStatusCode)
                } ?? []
                guard !facts.isEmpty else { return }
                // This is more detail for the same failure, not a new event.
                // A notice the user dismissed must stay dismissed.
                failure = PlaybackFailure(id: reported.id, track: track, stage: stage,
                                          message: PlaybackErrorMessage.describe(error, source: track.source, fallback: fallback, logEvents: facts))
            }
        }
    }
    func restoreQueue(_ tracks: [Track]) {
        guard !restored, queue.isEmpty else { return }; restored = true
        guard let data = defaults.data(forKey: Self.queueKey), let saved = try? JSONDecoder().decode(SavedQueue.self, from: data) else { return }
        queue = saved.tracks.map { old in
            if let refreshed = tracks.first(where: { $0.id == old.id }) { return refreshed }
            var track = old
            if old.source == .local || old.source == .demo { track.unavailable = true; track.url = nil }
            return track
        }
        navigation = PlaybackQueue(tracks: queue, currentID: saved.currentID)
        current = queue.first { $0.id == saved.currentID }; status = current == nil ? .idle : .paused; duration = current?.duration ?? 0
        position = saved.position.isFinite ? max(0, saved.position) : 0
        publishNowPlaying()
    }
    func readLevels() -> AudioLevels {
        guard current?.source != .appleMusic, current?.source != .spotify, status == .playing, !muted, volume > 0 else { return AudioLevels() }
        var levels = analyzer.levels(); levels.energy *= Float(volume); levels.beat *= Float(volume)
        return levels
    }
    private func persistPreferences() {
        if let data = try? JSONEncoder().encode(Preferences(volume: volume, muted: muted, shuffle: shuffle, repeatMode: repeatMode)) { defaults.set(data, forKey: Self.preferencesKey) }
    }
    private func persistQueue() {
        let tracks = queue.map { value in
            var track = value; if !track.duration.isFinite { track.duration = 0 }
            if track.source == .netease || track.source == .qq || track.source == .soda || track.source == .appleMusic || track.source == .spotify { track.url = nil }
            return track
        }
        if let data = try? JSONEncoder().encode(SavedQueue(tracks: tracks, currentID: current?.id, position: position.isFinite ? position : 0)) { defaults.set(data, forKey: Self.queueKey) }
    }
    private func publishNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let current else { center.nowPlayingInfo = nil; center.playbackState = .stopped; return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: current.title, MPMediaItemPropertyArtist: current.artist, MPMediaItemPropertyAlbumTitle: current.album, MPNowPlayingInfoPropertyElapsedPlaybackTime: position, MPNowPlayingInfoPropertyPlaybackRate: status == .playing ? 1.0 : 0.0, MPNowPlayingInfoPropertyIsLiveStream: !duration.isFinite]
        if duration.isFinite && duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        center.nowPlayingInfo = info; center.playbackState = status == .playing ? .playing : .paused
    }
    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        func bind(_ command: MPRemoteCommand, _ action: @escaping @MainActor @Sendable (PlayerController) async -> Void) {
            command.isEnabled = true
            let target = command.addTarget { [weak self] _ in Task { @MainActor [weak self] in if let self { await action(self) } }; return .success }
            remoteTargets.append((command, target))
        }
        bind(commands.playCommand) { player in if player.status != .playing && player.status != .loading { await player.toggle() } }
        bind(commands.pauseCommand) { $0.pause() }
        bind(commands.togglePlayPauseCommand) { await $0.toggle() }
        bind(commands.nextTrackCommand) { await $0.next() }
        bind(commands.previousTrackCommand) { await $0.previous() }
        commands.changePlaybackPositionCommand.isEnabled = true
        let target = commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime; Task { @MainActor [weak self] in self?.seek(to: position) }; return .success
        }
        remoteTargets.append((commands.changePlaybackPositionCommand, target))
    }
}
