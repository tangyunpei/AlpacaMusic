import Foundation
import Observation

/// An in-process lease for an isolated official website window. Never persisted.
struct QQOfficialPlaybackSession: Sendable {
    let id: UUID
    let generation: UUID
    let cookies: [MusicSessionCookie]
    let invalidations: AsyncStream<Void>
}

actor NativeMusicClient {
    private struct Session: Sendable { var cookies: [MusicSessionCookie]; var profile: MusicAccountProfile }
    private struct ConnectionAttempt { var id: UUID; var previous: Session? }
    private let providers: [MusicSource: any DirectMusicProvider]
    private let credentials: any MusicCredentialStoring
    private var sessions: [MusicSource: Session] = [:]
    private var generations: [MusicSource: UUID] = [:]
    private var credentialWrites: [MusicSource: Task<Void, Error>] = [:]
    private var attempts: [MusicSource: ConnectionAttempt] = [:]
    private var officialPlaybackLeases: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var lyricsObservers: [UUID: AsyncStream<MusicSource>.Continuation] = [:]

    init(providers: [any DirectMusicProvider] = [NeteaseDirectProvider(), QQDirectProvider(), SodaDirectProvider()], credentials: any MusicCredentialStoring = MusicCredentialStore()) {
        self.providers = Dictionary(providers.map { ($0.source, $0) }, uniquingKeysWith: { first, _ in first })
        self.credentials = credentials
    }
    func connectedSources() -> Set<MusicSource> { Set(sessions.keys) }
    func isConnected(_ source: MusicSource, accountID: String) -> Bool { sessions[source]?.profile.id == accountID }
    func restore(_ source: MusicSource) async throws -> MusicAccountProfile? {
        try Task.checkCancellation()
        guard MusicSourceAvailability.isVisible(source) else { return nil }
        let token = generation(source)
        let cookies = try await credentials.load(for: source)
        try validate(source, token)
        guard !cookies.isEmpty else { return nil }
        let values = DirectMusicAccess.sessionCookies(cookies, for: source)
        guard !values.isEmpty else { return nil }
        let profile = try await provider(source).profile(cookies: values)
        try validate(source, token)
        guard !profile.id.isEmpty, !profile.displayName.isEmpty else { throw MusicError.message(L10n.string("无法确认账户身份，请重新登录")) }
        // Restoring already saved credentials only validates and publishes the session.
        // Rewriting them can need a separate macOS Keychain authorization after an update.
        sessions[source] = Session(cookies: values, profile: profile)
        advanceGeneration(source)
        return profile
    }
    func connect(_ source: MusicSource, cookies: [MusicSessionCookie], attemptID: UUID = UUID()) async throws -> MusicAccountProfile {
        try Task.checkCancellation()
        if attempts[source]?.id != attemptID { attempts[source] = ConnectionAttempt(id: attemptID, previous: sessions[source]) }
        let token = advanceGeneration(source)
        let values = DirectMusicAccess.sessionCookies(cookies, for: source)
        guard !values.isEmpty else { throw MusicError.message(L10n.string("尚未检测到\(source.title)登录，请先在网页完成登录或扫码确认")) }
        let profile = try await provider(source).profile(cookies: values)
        try validate(source, token)
        guard !profile.id.isEmpty, !profile.displayName.isEmpty else { throw MusicError.message(L10n.string("无法确认账户身份，请重新登录")) }
        do {
            try await persist(values, source: source)
            try validate(source, token)
        } catch {
            if generations[source] == token {
                try? await persist(sessions[source]?.cookies, source: source)
            }
            throw error
        }
        sessions[source] = Session(cookies: values, profile: profile)
        // Requests begun while authenticating still used the previous account.
        advanceGeneration(source)
        return profile
    }
    func completeConnection(_ source: MusicSource, attemptID: UUID) {
        if attempts[source]?.id == attemptID { attempts.removeValue(forKey: source) }
    }
    @discardableResult func cancelConnection(_ source: MusicSource, attemptID: UUID? = nil) async throws -> MusicAccountProfile? {
        if let attemptID, attempts[source]?.id != attemptID { return sessions[source]?.profile }
        advanceGeneration(source)
        if let previous = attempts.removeValue(forKey: source) { sessions[source] = previous.previous }
        // Revert even if profile validation committed just before the sheet closed.
        try await persist(sessions[source]?.cookies, source: source)
        return sessions[source]?.profile
    }
    func disconnect(_ source: MusicSource) async throws {
        advanceGeneration(source); sessions.removeValue(forKey: source); attempts.removeValue(forKey: source)
        try await persist(nil, source: source)
    }
    func search(_ query: String, source: MusicSource) async throws -> [Track] {
        let (session, token) = try snapshot(source)
        let result = try await provider(source).search(query, cookies: session.cookies)
        try validate(source, token)
        return result
    }
    func playlists(_ source: MusicSource) async throws -> [RemoteMusicPlaylist] {
        let (session, token) = try snapshot(source)
        let result = try await provider(source).playlists(profile: session.profile, cookies: session.cookies)
        try validate(source, token)
        return result
    }
    func tracks(in playlist: RemoteMusicPlaylist) async throws -> [Track] {
        let (session, token) = try snapshot(playlist.source)
        do {
            let result = try await provider(playlist.source).tracks(in: playlist, cookies: session.cookies)
            try validate(playlist.source, token)
            return result
        } catch {
            // A partial result is data carried by an error. It needs the same
            // account-generation and cancellation checks as a successful list.
            try validate(playlist.source, token)
            throw error
        }
    }
    func preparePlayback(_ track: Track) async throws -> Track {
        let (session, token) = try snapshot(track.source)
        let result = try await provider(track.source).preparePlayback(track, cookies: session.cookies)
        try validate(track.source, token)
        guard result.source == track.source, result.id == track.id else { throw MusicError.message(L10n.string("平台返回的歌曲身份已变化，已停止播放")) }
        return result
    }
    func resolve(_ track: Track) async throws -> URL {
        let (session, token) = try snapshot(track.source)
        let result = try await provider(track.source).resolve(track, cookies: session.cookies)
        try validate(track.source, token)
        return result
    }
    func lyricsScope(for source: MusicSource) throws -> LyricsSessionScope {
        let (_, token) = try snapshot(source)
        try validate(source, token)
        return .init(source: source, generation: token)
    }
    func validateLyricsScope(_ scope: LyricsSessionScope) throws {
        try validate(scope.source, scope.generation)
        guard sessions[scope.source] != nil else { throw CancellationError() }
    }
    func lyrics(_ track: Track, scope: LyricsSessionScope) async throws -> LyricsPayload? {
        guard scope.source == track.source else { throw CancellationError() }
        try validateLyricsScope(scope)
        let (session, token) = try snapshot(track.source)
        do {
            let result = try await provider(track.source).lyrics(track, cookies: session.cookies)
            try validate(track.source, token)
            return result
        } catch {
            try validate(track.source, token)
            throw error
        }
    }
    func lyricsSessionChanges() -> AsyncStream<MusicSource> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<MusicSource>.makeStream(bufferingPolicy: .bufferingNewest(16))
        lyricsObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeLyricsObserver(id) } }
        return stream
    }
    private func removeLyricsObserver(_ id: UUID) { lyricsObservers.removeValue(forKey: id) }
    func officialQQPlaybackSession() throws -> QQOfficialPlaybackSession {
        try Task.checkCancellation()
        let (session, token) = try snapshot(.qq)
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        officialPlaybackLeases[id] = continuation
        return .init(id: id, generation: token, cookies: DirectMusicAccess.sessionCookies(session.cookies, for: .qq), invalidations: stream)
    }
    func validateOfficialQQPlaybackSession(_ session: QQOfficialPlaybackSession) throws {
        try validate(.qq, session.generation)
        guard officialPlaybackLeases[session.id] != nil, sessions[.qq] != nil else { throw CancellationError() }
    }
    func releaseOfficialQQPlaybackSession(_ id: UUID) {
        officialPlaybackLeases.removeValue(forKey: id)?.finish()
    }
    @discardableResult private func advanceGeneration(_ source: MusicSource) -> UUID {
        let token = UUID(); generations[source] = token
        for observer in lyricsObservers.values { observer.yield(source) }
        if source == .qq {
            let leases = Array(officialPlaybackLeases.values)
            officialPlaybackLeases.removeAll()
            for lease in leases { lease.yield(()); lease.finish() }
        }
        return token
    }
    private func provider(_ source: MusicSource) throws -> any DirectMusicProvider {
        guard let value = providers[source] else { throw MusicError.message(L10n.string("此平台尚不支持应用内连接")) }
        return value
    }
    private func persist(_ cookies: [MusicSessionCookie]?, source: MusicSource) async throws {
        let previous = credentialWrites[source], store = credentials
        let task = Task {
            if let previous { _ = try? await previous.value }
            if let cookies { try await store.save(cookies, for: source) }
            else { try await store.delete(for: source) }
        }
        credentialWrites[source] = task
        try await task.value
    }
    private func generation(_ source: MusicSource) -> UUID {
        if let value = generations[source] { return value }
        let value = UUID(); generations[source] = value; return value
    }
    private func validate(_ source: MusicSource, _ token: UUID) throws {
        try Task.checkCancellation()
        guard generations[source] == token else { throw CancellationError() }
    }
    private func snapshot(_ source: MusicSource) throws -> (Session, UUID) {
        guard let value = sessions[source] else { throw MusicError.message(L10n.string("请先在音源页登录\(source.title)")) }
        return (value, generation(source))
    }
}

struct ConnectedMusicState {
    var profile: MusicAccountProfile?
    var busy = false
    var error: String?
    var playlists: [RemoteMusicPlaylist] = []
    var playlistsLoaded = false
}

@MainActor @Observable final class ConnectedMusicAccounts {
    let client: NativeMusicClient
    private(set) var states: [MusicSource: ConnectedMusicState] = [:]
    @ObservationIgnored private var generations: [MusicSource: UUID] = [:]
    @ObservationIgnored private var loginAttempts: [MusicSource: UUID] = [:]
    init(client: NativeMusicClient) { self.client = client }
    func state(_ source: MusicSource) -> ConnectedMusicState { states[source] ?? ConnectedMusicState() }
    var count: Int { states.values.filter { $0.profile != nil }.count }

    func restore() async {
        let pending = DirectMusicAccess.visibleSources.filter { generations[$0] == nil }.map { ($0, UUID()) }
        for (source, token) in pending {
            generations[source] = token
            states[source, default: ConnectedMusicState()].busy = true
        }
        for (source, token) in pending {
            guard generations[source] == token else { continue }
            do {
                let profile = try await client.restore(source)
                guard generations[source] == token else { continue }
                states[source] = ConnectedMusicState(profile: profile)
            } catch {
                guard generations[source] == token else { continue }
                states[source] = ConnectedMusicState(error: L10n.string("登录恢复失败，请重新连接。\(error.localizedDescription)"))
            }
        }
    }
    func connect(_ source: MusicSource, cookies: [MusicSessionCookie], attemptID: UUID) async throws {
        loginAttempts[source] = attemptID
        let token = UUID(); generations[source] = token
        states[source, default: ConnectedMusicState()].busy = true
        do {
            let profile = try await client.connect(source, cookies: cookies, attemptID: attemptID)
            guard generations[source] == token else { throw CancellationError() }
            states[source] = ConnectedMusicState(profile: profile)
        } catch {
            if generations[source] == token {
                states[source, default: ConnectedMusicState()].busy = false
                states[source, default: ConnectedMusicState()].error = error is CancellationError ? nil : error.localizedDescription
            }
            throw error
        }
    }
    func cancelConnection(_ source: MusicSource, attemptID: UUID) async {
        guard loginAttempts[source] == attemptID else { return }
        loginAttempts.removeValue(forKey: source)
        let token = UUID(); generations[source] = token
        states[source, default: ConnectedMusicState()].busy = false
        do {
            let profile = try await client.cancelConnection(source, attemptID: attemptID)
            if generations[source] == token { states[source] = ConnectedMusicState(profile: profile) }
        } catch {
            if generations[source] == token { states[source, default: ConnectedMusicState()].error = error.localizedDescription }
        }
    }
    func completeConnection(_ source: MusicSource, attemptID: UUID) async {
        if loginAttempts[source] == attemptID { loginAttempts.removeValue(forKey: source) }
        await client.completeConnection(source, attemptID: attemptID)
    }
    func disconnect(_ source: MusicSource) async {
        loginAttempts.removeValue(forKey: source)
        let token = UUID(); generations[source] = token; states[source] = ConnectedMusicState(busy: true)
        do {
            try await client.disconnect(source)
            if generations[source] == token { states[source] = ConnectedMusicState() }
        } catch {
            if generations[source] == token { states[source] = ConnectedMusicState(error: error.localizedDescription) }
        }
    }
    func loadPlaylists(_ source: MusicSource) async {
        guard state(source).profile != nil, !state(source).busy else { return }
        let token = UUID(); generations[source] = token
        states[source, default: ConnectedMusicState()].busy = true
        states[source, default: ConnectedMusicState()].error = nil
        do {
            let values = try await client.playlists(source)
            guard generations[source] == token else { return }
            states[source, default: ConnectedMusicState()].playlists = values
            states[source, default: ConnectedMusicState()].playlistsLoaded = true
        } catch {
            guard generations[source] == token else { return }
            states[source, default: ConnectedMusicState()].error = error.localizedDescription
        }
        states[source, default: ConnectedMusicState()].busy = false
    }
}
