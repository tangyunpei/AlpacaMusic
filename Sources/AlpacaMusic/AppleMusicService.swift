import Foundation
import MusicKit
import Observation
import Security

/// MusicKit is an App ID service, not a custom entitlement. The build flag is
/// only an opt-in; a real matching signing team is also required at runtime.
struct AppleMusicConfiguration: Sendable {
    var enabledInBuild: Bool
    var expectedTeam: String
    var signedTeam: String?
    var isAdHoc: Bool
    var hasUsageDescription: Bool
    var isConfigured: Bool {
        enabledInBuild && hasUsageDescription && !isAdHoc && !expectedTeam.isEmpty && signedTeam == expectedTeam
    }
    static var current: Self {
        let bundle = Bundle.main
        var code: SecCode?, staticCode: SecStaticCode?, information: CFDictionary?
        var team: String?, adHoc = true
        if SecCodeCopySelf([], &code) == errSecSuccess, let code,
           SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
           SecStaticCodeCheckValidity(staticCode, [], nil) == errSecSuccess,
           SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
           let info = information as? [String: Any] {
            team = info[kSecCodeInfoTeamIdentifier as String] as? String
            let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
            adHoc = flags & 0x2 != 0 // CS_ADHOC, also reject missing Team ID above.
        }
        let usage = bundle.object(forInfoDictionaryKey: "NSAppleMusicUsageDescription") as? String ?? ""
        return Self(enabledInBuild: bundle.object(forInfoDictionaryKey: "AlpacaMusicMusicKitConfigured") as? Bool ?? false,
                    expectedTeam: bundle.object(forInfoDictionaryKey: "AlpacaMusicMusicKitTeamIdentifier") as? String ?? "",
                    signedTeam: team, isAdHoc: adHoc, hasUsageDescription: !usage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
struct AppleMusicCapabilities: Sendable {
    var canPlayCatalog: Bool
    var hasCloudLibrary: Bool
}
struct AppleMusicPlaybackSnapshot: Sendable {
    enum State: Sendable { case stopped, playing, paused, interrupted, seeking }
    var state: State
    var position: Double
    var hasCurrentEntry: Bool
}

/// The adapter is main-actor isolated so MusicKit player objects never cross
/// executors. Tests substitute it without requesting access to a real account.
@MainActor protocol AppleMusicAdapter: AnyObject {
    var authorization: MusicAuthorization.Status { get }
    func requestAuthorization() async -> MusicAuthorization.Status
    func subscription() async throws -> AppleMusicCapabilities
    func search(_ query: String) async throws -> [Track]
    func librarySongs(validate: @MainActor () throws -> Void) async throws -> [Track]
    func libraryPlaylists(validate: @MainActor () throws -> Void) async throws -> [AppleMusicLibraryPlaylist]
    func libraryTracks(in playlist: AppleMusicLibraryPlaylist, validate: @MainActor () throws -> Void) async throws -> [Track]
    func setSession(_ id: UUID?)
    func prepare(_ track: Track, session: UUID) async throws -> Double
    func play(session: UUID) async throws
    func pause()
    func seek(to seconds: Double)
    func snapshot() -> AppleMusicPlaybackSnapshot
}

@MainActor @Observable
final class AppleMusicService {
    private(set) var isEnabled: Bool
    let isConfigured: Bool
    private(set) var isBusy = false
    private(set) var error: String?
    private var authorizationCaption: String.LocalizationValue = "未连接"
    private var subscriptionCaption: String.LocalizationValue = "连接后检查订阅"
    var authorizationDescription: String { L10n.string(authorizationCaption) }
    var subscriptionDescription: String { L10n.string(subscriptionCaption) }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let adapter: any AppleMusicAdapter
    @ObservationIgnored private var capabilities: AppleMusicCapabilities?
    private var generation = UUID()
    @ObservationIgnored private var playbackSession: UUID?
    private static let enabledKey = "AlpacaMusic.AppleMusic.enabled.v1"
    var librarySessionID: UUID { generation }

    init(defaults: UserDefaults = .standard, configuration: AppleMusicConfiguration = .current, adapter: (any AppleMusicAdapter)? = nil) {
        self.defaults = defaults; self.adapter = adapter ?? SystemAppleMusicAdapter()
        isConfigured = configuration.isConfigured; isEnabled = configuration.isConfigured && defaults.bool(forKey: Self.enabledKey)
        if !isConfigured { authorizationCaption = "需要开发者签名配置" }
        else if isEnabled { authorizationCaption = "等待检查授权" }
    }
    func connect() async {
        guard !isBusy else { return }
        guard isConfigured else { error = L10n.string("此构建尚未配置 Apple Music。请先启用 App ID 的 MusicKit 服务并使用匹配的开发者团队签名。"); return }
        generation = UUID(); let token = generation
        isEnabled = true; defaults.set(true, forKey: Self.enabledKey); isBusy = true; error = nil
        let authorization = await adapter.requestAuthorization()
        guard generation == token, isEnabled else { return }
        updateAuthorization(authorization)
        guard authorization == .authorized else {
            isBusy = false; isEnabled = false; defaults.set(false, forKey: Self.enabledKey)
            error = L10n.string("尚未获得 Apple Music 访问权限。可在系统设置中管理授权。"); return
        }
        await refreshSubscription(token: token)
        if generation == token { isBusy = false }
    }
    /// Does not prompt. Disabled/unconfigured installations never contact MusicKit.
    func refresh() async {
        guard isConfigured, isEnabled, !isBusy else { return }
        let token = generation; isBusy = true; error = nil
        let authorization = adapter.authorization; updateAuthorization(authorization)
        if authorization == .authorized { await refreshSubscription(token: token) }
        else { capabilities = nil; subscriptionCaption = "需要授权" }
        if generation == token { isBusy = false }
    }
    func disconnect() {
        generation = UUID(); stopPlayback(); isEnabled = false; defaults.set(false, forKey: Self.enabledKey)
        capabilities = nil; isBusy = false; error = nil
        authorizationCaption = "已在本应用停用"; subscriptionCaption = "连接后检查订阅"
    }
    private func updateAuthorization(_ status: MusicAuthorization.Status) {
        switch status {
        case .authorized: authorizationCaption = "已授权"
        case .notDetermined: authorizationCaption = "尚未授权"
        case .denied: authorizationCaption = "授权被拒绝"
        case .restricted: authorizationCaption = "访问受系统限制"
        @unknown default: authorizationCaption = "授权状态未知"
        }
    }
    private func refreshSubscription(token: UUID) async {
        do {
            let value = try await adapter.subscription()
            guard generation == token, isEnabled else { return }
            capabilities = value
            subscriptionCaption = value.canPlayCatalog ? "可播放 Apple Music 曲库" : "当前账户无法播放订阅曲库"
        } catch {
            guard generation == token, isEnabled else { return }
            capabilities = nil; subscriptionCaption = "订阅检查失败"; self.error = error.localizedDescription
        }
    }
    private func requireAccess() throws {
        guard isConfigured else { throw MusicError.message(L10n.string("请先完成 Apple Music 开发者签名配置。")) }
        guard isEnabled else { throw MusicError.message(L10n.string("请先在设置中连接 Apple Music。")) }
        guard adapter.authorization == .authorized else { throw MusicError.message(L10n.string("Apple Music 尚未授权。请在设置中连接。")) }
    }
    func search(_ query: String) async throws -> [Track] {
        try requireAccess()
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines); guard !term.isEmpty else { return [] }
        let token = generation
        let tracks = try await adapter.search(term)
        try Task.checkCancellation(); try requireAccess()
        guard generation == token else { throw CancellationError() }
        return tracks
    }
    func validateLibrarySession(_ id: UUID) throws {
        try Task.checkCancellation()
        guard generation == id else { throw CancellationError() }
        try requireAccess()
    }
    func librarySongs() async throws -> [Track] {
        try requireAccess(); let token = generation
        let result = try await adapter.librarySongs { try self.validateLibrarySession(token) }
        try validateLibrarySession(token)
        return result
    }
    func libraryPlaylists() async throws -> [AppleMusicLibraryPlaylist] {
        try requireAccess(); let token = generation
        let result = try await adapter.libraryPlaylists { try self.validateLibrarySession(token) }
        try validateLibrarySession(token)
        return result
    }
    func libraryTracks(in playlist: AppleMusicLibraryPlaylist) async throws -> [Track] {
        try requireAccess(); let token = generation
        let result = try await adapter.libraryTracks(in: playlist) { try self.validateLibrarySession(token) }
        try validateLibrarySession(token)
        return result
    }
    func preparePlayback(_ track: Track, session: UUID) async throws -> Double {
        try requireAccess()
        // Refresh at each activation so an expired subscription is not cached as playable.
        let token = generation
        let latest = try await adapter.subscription()
        try Task.checkCancellation(); try requireAccess()
        guard generation == token else { throw CancellationError() }
        capabilities = latest
        subscriptionCaption = latest.canPlayCatalog ? "可播放 Apple Music 曲库" : "当前账户无法播放订阅曲库"
        guard latest.canPlayCatalog else { throw MusicError.message(L10n.string("当前 Apple Music 账户不能播放订阅曲库，请检查订阅。")) }
        playbackSession = session; adapter.setSession(session)
        let duration = try await adapter.prepare(track, session: session)
        try Task.checkCancellation(); try requireAccess()
        guard playbackSession == session else { throw CancellationError() }
        return duration
    }
    func resumePlayback(session: UUID) async throws {
        try requireAccess(); guard playbackSession == session else { throw CancellationError() }
        do { try await adapter.play(session: session) }
        catch { if playbackSession == nil { adapter.setSession(nil) }; throw error }
        if playbackSession == nil { adapter.setSession(nil) }
        try Task.checkCancellation(); try requireAccess()
        guard playbackSession == session else { throw CancellationError() }
    }
    func pausePlayback() { if playbackSession != nil { adapter.pause() } }
    func stopPlayback() { if playbackSession != nil { playbackSession = nil; adapter.setSession(nil) } }
    func seekPlayback(to seconds: Double) { if playbackSession != nil, seconds.isFinite { adapter.seek(to: seconds) } }
    func playbackSnapshot(session: UUID) throws -> AppleMusicPlaybackSnapshot {
        try requireAccess(); guard playbackSession == session else { throw MusicError.message(L10n.string("Apple Music 播放已停止。")) }
        return adapter.snapshot()
    }
}

@MainActor private final class SystemAppleMusicAdapter: AppleMusicAdapter {
    private let library = AppleMusicLibraryClient()
    private var session: UUID?
    private var player: ApplicationMusicPlayer?
    private var wantsPlayback = false
    var authorization: MusicAuthorization.Status { MusicAuthorization.currentStatus }
    func requestAuthorization() async -> MusicAuthorization.Status { await MusicAuthorization.request() }
    func subscription() async throws -> AppleMusicCapabilities {
        let value = try await MusicSubscription.current
        return AppleMusicCapabilities(canPlayCatalog: value.canPlayCatalogContent, hasCloudLibrary: value.hasCloudLibraryEnabled)
    }
    func search(_ query: String) async throws -> [Track] {
        var request = MusicCatalogSearchRequest(term: query, types: [Song.self]); request.limit = 40
        let result = try await request.response()
        return result.songs.map { song in
            Track(id: "appleMusic:\(song.id.rawValue)", title: song.title, artist: song.artistName, album: song.albumTitle ?? "",
                  duration: song.duration ?? 0, source: .appleMusic, sourceID: song.id.rawValue,
                  appleMusicResourceKind: .catalogSong,
                  artworkURL: song.artwork?.url(width: 640, height: 640), format: "Apple Music", unavailable: song.playParameters == nil)
        }
    }
    func librarySongs(validate: @MainActor () throws -> Void) async throws -> [Track] { try await library.songs(validate: validate) }
    func libraryPlaylists(validate: @MainActor () throws -> Void) async throws -> [AppleMusicLibraryPlaylist] { try await library.playlists(validate: validate) }
    func libraryTracks(in playlist: AppleMusicLibraryPlaylist, validate: @MainActor () throws -> Void) async throws -> [Track] {
        try await library.tracks(in: playlist, validate: validate)
    }
    func setSession(_ id: UUID?) { session = id; wantsPlayback = false; player?.stop(); if id == nil { player?.queue = [] } }
    func prepare(_ track: Track, session request: UUID) async throws -> Double {
        guard let id = track.sourceID, !id.isEmpty else { throw MusicError.message(L10n.string("这首歌曲缺少 Apple Music 标识，请重新搜索。")) }
        let song: Song
        switch try AppleMusicLibraryClient.playbackResource(for: track) {
        case .librarySong:
            song = try await library.playbackSong(libraryID: id)
        case .catalogSong:
            let requestValue = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
            let response = try await requestValue.response()
            guard let value = response.items.first, value.id.rawValue == id else { throw MusicError.message(L10n.string("Apple Music 未找到这首歌曲。")) }
            song = value
        }
        try Task.checkCancellation(); guard session == request else { throw CancellationError() }
        guard song.playParameters != nil else { throw MusicError.message(L10n.string("这首歌曲当前无法在 Apple Music 播放。")) }
        let instance = ApplicationMusicPlayer.shared; player = instance
        instance.state.repeatMode = MusicPlayer.RepeatMode.none; instance.state.shuffleMode = .off
        instance.queue = ApplicationMusicPlayer.Queue(for: [song])
        return song.duration ?? track.duration
    }
    func play(session request: UUID) async throws {
        guard session == request, let player else { throw CancellationError() }
        wantsPlayback = true
        do { try await ApplicationMusicPlayer.shared.play() }
        catch { if session == nil { player.stop() }; throw error }
        // A late play completion after switching to AVPlayer must never resume audio.
        if session == nil { player.stop() }
        else if !wantsPlayback { player.pause() }
        guard session == request else { throw CancellationError() }
    }
    func pause() { wantsPlayback = false; player?.pause() }
    func seek(to seconds: Double) { player?.playbackTime = seconds }
    func snapshot() -> AppleMusicPlaybackSnapshot {
        guard let player else { return .init(state: .stopped, position: 0, hasCurrentEntry: false) }
        let state: AppleMusicPlaybackSnapshot.State
        switch player.state.playbackStatus {
        case .stopped: state = .stopped
        case .playing: state = .playing
        case .paused: state = .paused
        case .interrupted: state = .interrupted
        case .seekingForward, .seekingBackward: state = .seeking
        @unknown default: state = .interrupted
        }
        return .init(state: state, position: player.playbackTime, hasCurrentEntry: player.queue.currentEntry != nil)
    }
}
