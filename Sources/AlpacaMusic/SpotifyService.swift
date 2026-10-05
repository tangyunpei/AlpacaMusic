import Foundation
import Observation

/// OAuth credentials belong to this provider alone, never a custom music server.
@MainActor @Observable
final class SpotifyService {
    private(set) var clientID: String
    private(set) var profile: MusicAccountProfile?
    private(set) var isBusy = false
    private(set) var error: String?
    private(set) var devices: [SpotifyDevice] = []
    var selectedDeviceID: String = ""
    private(set) var sessionID = UUID()
    var isEnabled: Bool { profile != nil && token != nil }
    var isConfigured: Bool { Self.validClientID(clientID) }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let api: SpotifyAPIClient
    @ObservationIgnored private let authorization: any SpotifyAuthorizing
    @ObservationIgnored private let credentials: any SpotifyCredentialStoring
    @ObservationIgnored private var token: SpotifyToken?
    @ObservationIgnored private var refreshTask: Task<SpotifyToken, Error>?
    @ObservationIgnored private var refreshID = UUID()
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var playbackSession: UUID?
    @ObservationIgnored private var playbackDevice: String?
    @ObservationIgnored private var playbackTrack: String?
    @ObservationIgnored private var commandTail: Task<Void, Error>?
    private static let clientKey = "spotify-client-id"
    private static let enabledKey = "spotify-connected"

    init(defaults: UserDefaults = .standard, api: SpotifyAPIClient = SpotifyAPIClient(),
         authorization: any SpotifyAuthorizing = SpotifyAuthorization(),
         credentials: any SpotifyCredentialStoring = SpotifyCredentialStore()) {
        self.defaults = defaults; self.api = api
        self.authorization = authorization; self.credentials = credentials
        clientID = defaults.string(forKey: Self.clientKey) ?? ""
    }

    static func validClientID(_ value: String) -> Bool {
        value.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
    func configure(_ value: String) throws {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validClientID(clean) else { throw MusicError.message("Client ID 应为 Spotify 提供的 32 位标识，请勿填写 Client Secret。") }
        guard !isBusy, profile == nil else { throw MusicError.message("请先断开 Spotify，再更换应用配置。") }
        sessionID = UUID(); token = nil; error = nil
        clientID = clean; defaults.set(clean, forKey: Self.clientKey)
        defaults.set(false, forKey: Self.enabledKey)
    }
    func restore() async {
        guard !isBusy, profile == nil, isConfigured, defaults.bool(forKey: Self.enabledKey) else { return }
        let generation = sessionID; isBusy = true
        defer { if generation == sessionID { isBusy = false } }
        do {
            let value = try await credentials.load(clientID: clientID)
            try validateSession(generation)
            guard let value else { defaults.set(false, forKey: Self.enabledKey); return }
            token = value
            let api = self.api
            let account = try await authorized { try await api.profile(accessToken: $0) }
            try validateSession(generation)
            profile = account; error = nil
        } catch is CancellationError { }
        catch { if generation == sessionID { self.error = Self.message(error) } }
    }
    func connect() {
        guard isConfigured, !isBusy else { return }
        sessionID = UUID(); let generation = sessionID; let configuredID = clientID
        isBusy = true; error = nil
        connectionTask = Task { [weak self] in
            guard let self else { return }
            defer { if sessionID == generation { isBusy = false; connectionTask = nil } }
            do {
                let candidate = try await authorization.authorize(clientID: configuredID)
                try validateSession(generation)
                let account = try await api.profile(accessToken: candidate.accessToken)
                try validateSession(generation)
                try await credentials.save(candidate, clientID: configuredID)
                try validateSession(generation)
                token = candidate; profile = account; error = nil
                defaults.set(true, forKey: Self.enabledKey)
            } catch is CancellationError { }
            catch { if generation == sessionID { self.error = Self.message(error) } }
        }
    }
    func cancelConnection() {
        guard isBusy else { return }
        sessionID = UUID(); connectionTask?.cancel(); connectionTask = nil
        refreshTask?.cancel(); refreshTask = nil; isBusy = false
    }
    func disconnect() async {
        sessionID = UUID(); let generation = sessionID
        connectionTask?.cancel(); connectionTask = nil; refreshTask?.cancel(); refreshTask = nil
        releasePlayback(); token = nil; profile = nil; devices = []; selectedDeviceID = ""
        defaults.set(false, forKey: Self.enabledKey); isBusy = true
        defer { if sessionID == generation { isBusy = false } }
        do { try await credentials.delete(clientID: clientID); if sessionID == generation { error = nil } }
        catch { if sessionID == generation { self.error = Self.message(error) } }
    }
    func validateSession(_ value: UUID) throws {
        try Task.checkCancellation()
        guard value == sessionID else { throw CancellationError() }
    }
    func search(_ query: String) async throws -> [Track] {
        let api = self.api
        return try await authorized { try await api.search(query, accessToken: $0) }
    }
    func playlists() async throws -> [RemoteMusicPlaylist] {
        let api = self.api
        return try await authorized { try await api.playlists(accessToken: $0) }
    }
    func tracks(in playlist: RemoteMusicPlaylist) async throws -> [Track] {
        let api = self.api
        return try await authorized { try await api.tracks(in: playlist, accessToken: $0) }
    }
    func savedTracks() async throws -> [Track] {
        let api = self.api
        return try await authorized { try await api.savedTracks(accessToken: $0) }
    }
    func refreshDevices() async {
        let api = self.api
        do { devices = try await authorized { try await api.devices(accessToken: $0) }; error = nil }
        catch is CancellationError { }
        catch { self.error = Self.message(error) }
    }

    // Serialize controls so a slow pause/seek cannot overtake a newer play.
    private func command(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        let previous = commandTail
        let task = Task { @MainActor in
            if let previous { _ = await previous.result }
            try Task.checkCancellation()
            try await operation()
        }
        commandTail = task
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    func startPlayback(_ track: Track, at position: Double, session: UUID) async throws {
        guard track.source == .spotify, let id = track.sourceID, !id.isEmpty else { throw MusicError.message("Spotify 歌曲标识无效。") }
        let accountSession = sessionID
        playbackSession = session; playbackTrack = id
        try await command { [self] in
            try validatePlayback(session, account: accountSession)
            let api = self.api
            let candidates = try await authorized { try await api.devices(accessToken: $0) }
            try validatePlayback(session, account: accountSession)
            devices = candidates
            let device = selectedDeviceID.isEmpty
                ? candidates.first(where: { $0.isActive && !$0.isRestricted && $0.id != nil })
                : candidates.first(where: { $0.id == selectedDeviceID && !$0.isRestricted })
            guard let device, let deviceID = device.id else {
                throw MusicError.message("请先在 Spotify 官方 App 或网页播放器播放一次，或在音源页选择可用设备，然后重试。")
            }
            playbackDevice = deviceID
            try await authorized { try await api.play(trackID: id, deviceID: deviceID, position: position, accessToken: $0) }
            try validatePlayback(session, account: accountSession)
        }
    }
    func pausePlayback(session: UUID) async throws {
        let account = sessionID; let api = self.api
        try await command { [self] in
            try validatePlayback(session, account: account)
            guard let device = playbackDevice else { return }
            let expectedTrack = playbackTrack
            let snapshot = try await authorized { try await api.playbackState(accessToken: $0) }
            try validatePlayback(session, account: account)
            guard let snapshot, snapshot.deviceID == device, snapshot.trackID == expectedTrack else { return }
            try await authorized { try await api.pause(deviceID: device, accessToken: $0) }
        }
    }
    func seekPlayback(to seconds: Double, session: UUID) async throws {
        guard playbackSession == session, let device = playbackDevice else { throw CancellationError() }
        let account = sessionID; let api = self.api
        try await command { [self] in
            try validatePlayback(session, account: account)
            let expectedTrack = playbackTrack
            let snapshot = try await authorized { try await api.playbackState(accessToken: $0) }
            try validatePlayback(session, account: account)
            guard let snapshot, snapshot.deviceID == device, snapshot.trackID == expectedTrack else {
                throw MusicError.message("Spotify 已切换播放曲目或设备，请重新选择歌曲。")
            }
            try await authorized { try await api.seek(to: seconds, deviceID: device, accessToken: $0) }
        }
    }
    func playbackSnapshot(session: UUID) async throws -> SpotifyPlaybackState? {
        let account = sessionID; try validatePlayback(session, account: account)
        let api = self.api
        let snapshot = try await authorized { try await api.playbackState(accessToken: $0) }
        try validatePlayback(session, account: account)
        return snapshot
    }
    func releasePlayback() { playbackSession = nil; playbackDevice = nil; playbackTrack = nil }
    private func validatePlayback(_ session: UUID, account: UUID) throws {
        try validateSession(account)
        guard playbackSession == session else { throw CancellationError() }
    }
    private func authorized<T: Sendable>(_ operation: @Sendable (String) async throws -> T) async throws -> T {
        let generation = sessionID
        guard let current = token else { throw MusicError.message("请先在音源页连接 Spotify。") }
        let valid = current.isExpired() ? try await refresh() : current
        try validateSession(generation)
        do {
            let value = try await operation(valid.accessToken)
            try validateSession(generation); return value
        } catch let failure as SpotifyAPIError where failure.isUnauthorized {
            // Retry once only after an explicit authorization rejection, never a
            // timeout whose remote playback effect could already have happened.
            try validateSession(generation)
            let latest = token?.accessToken != valid.accessToken ? token! : try await refresh()
            try validateSession(generation)
            let result = try await operation(latest.accessToken)
            try validateSession(generation); return result
        }
    }
    private func refresh() async throws -> SpotifyToken {
        let generation = sessionID
        if let refreshTask {
            let value = try await refreshTask.value
            try validateSession(generation)
            return value
        }
        guard let previous = token else { throw MusicError.message("Spotify 登录已失效，请重新连接。") }
        let operation = UUID(); refreshID = operation
        let id = clientID
        let task = Task { [self] in
            var value = try await authorization.refresh(clientID: id, refreshToken: previous.refreshToken)
            try validateSession(generation)
            if value.scopes.isEmpty { value.scopes = previous.scopes }
            try await credentials.save(value, clientID: id)
            try validateSession(generation)
            token = value
            return value
        }
        refreshTask = task
        defer { if refreshID == operation { refreshTask = nil } }
        let value = try await task.value
        try validateSession(generation)
        return value
    }
    static func message(_ error: any Error) -> String {
        if let error = error as? SpotifyAPIError { return error.localizedDescription }
        if let error = error as? MusicError { return error.localizedDescription }
        if let error = error as? SpotifyAuthorizationError { return error.localizedDescription }
        return PlaybackErrorMessage.describe(error, source: .spotify, fallback: "Spotify 请求未完成，请检查网络后重试。")
    }
}
