import Foundation
import Observation

private struct LibrarySnapshot: Codable, Sendable {
    var version: Int = 1
    var tracks: [Track] = []
    var favorites: Set<String> = []
    var playlists: [MusicPlaylist] = []
    var sources: [SourceConfiguration] = SourceConfiguration.defaults
}

private enum StartupMutation {
    case add([Track]), favorite(String), create(MusicPlaylist), addToPlaylist(String, Track)
    case removeFromPlaylist(String, String), deletePlaylist(String), removeTrack(String), sources([SourceConfiguration])
    case importRemote(RemoteMusicPlaylist, String, [Track])
}

/// All disk operations are serialized off the main actor. Revision checks prevent
/// an older task, scheduled later, from overwriting a newer UI snapshot.
private actor LibraryStorage {
    let directory: URL
    private var latestRevision: UInt64 = 0
    var location: URL { directory.appending(path: "library-v1.json") }
    init(directory: URL) { self.directory = directory }

    func read() throws -> (snapshot: LibrarySnapshot?, warning: String?) {
        guard FileManager.default.fileExists(atPath: location.path(percentEncoded: false)) else { return (nil, nil) }
        let data: Data
        do { data = try Data(contentsOf: location) }
        catch { throw MusicError.message("无法读取音乐资料库，请检查应用数据目录权限") }
        do {
            var state = try JSONDecoder().decode(LibrarySnapshot.self, from: data)
            guard state.version == 1, state.tracks.count <= 10000,
                  Set(state.tracks.map(\.id)).count == state.tracks.count,
                  state.tracks.allSatisfy({ !$0.id.isEmpty && $0.duration.isFinite && $0.duration >= 0 && ($0.source != .local || $0.bookmark != nil) }) else { throw MusicError.message("资料库格式无效") }
            state.sources = try SourceService.validatedConfigurations(state.sources)
            let ids = Set(state.tracks.map(\.id))
            state.favorites.formIntersection(ids)
            for index in state.playlists.indices { state.playlists[index].trackIDs = state.playlists[index].trackIDs.filter(ids.contains) }
            // Resolve bookmarks without UI, renew stale bookmarks, and retain missing
            // records as unavailable so favorites and playlists do not disappear.
            for index in state.tracks.indices where state.tracks[index].source == .local {
                do {
                    var stale = false
                    let url = try URL(resolvingBookmarkData: state.tracks[index].bookmark!, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    state.tracks[index].url = url
                    state.tracks[index].unavailable = !FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false))
                    if stale && !state.tracks[index].unavailable {
                        state.tracks[index].bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: [.nameKey], relativeTo: nil)
                    }
                } catch { state.tracks[index].unavailable = true }
            }
            return (state, nil)
        } catch {
            let backup = directory.appending(path: "library-v1.corrupt-\(UUID().uuidString).json")
            try FileManager.default.moveItem(at: location, to: backup)
            return (LibrarySnapshot(), "音乐资料库格式损坏，已保留原始备份并创建空资料库。原始音频文件没有改动。")
        }
    }

    func save(_ state: LibrarySnapshot, revision: UInt64) throws {
        guard revision >= latestRevision else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: location, options: [.atomic])
        latestRevision = revision
    }
}

@MainActor @Observable final class MusicLibrary {
    private(set) var tracks: [Track] = [] { didSet { trackLookup = nil; listingRevision &+= 1 } }
    private(set) var favorites: Set<String> = [] { didSet { listingRevision &+= 1 } }
    private(set) var playlists: [MusicPlaylist] = [] { didSet { listingRevision &+= 1 } }
    private(set) var listingRevision: UInt64 = 0
    @ObservationIgnored private var trackLookup: [String: Track]?
    private(set) var sources: [SourceConfiguration] = SourceConfiguration.defaults
    private(set) var ready = false
    private(set) var busy = false
    var error: String?
    private(set) var persistenceError: String?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let storage: LibraryStorage
    @ObservationIgnored private let importer = MetadataImporter()
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var saveTask: Task<Result<Void, MusicError>, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var startupMutations: [StartupMutation] = []
    @ObservationIgnored private var applyingStartup = false
    @ObservationIgnored private var persistenceBlocked = false

    init(directory: URL? = nil) {
        let directory = directory ?? URL.applicationSupportDirectory.appending(path: "AlpacaMusic", directoryHint: .isDirectory)
        self.directory = directory
        self.storage = LibraryStorage(directory: directory)
    }

    func tracks(withIDs ids: [String]) -> [Track] {
        // Reading tracks registers the dependency even when the lookup is cached.
        let current = tracks
        if trackLookup == nil { trackLookup = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new }) }
        let lookup = trackLookup ?? [:]
        return ids.compactMap { lookup[$0] }
    }

    func load() async {
        if ready { return }
        if let loadTask { await loadTask.value; return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.loadState()
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func loadState() async {
        do {
            let (state, warning) = try await storage.read()
            if let state {
                tracks = state.tracks; favorites = state.favorites; playlists = state.playlists; sources = state.sources
                if let warning { error = warning }
            } else {
                let demos = try await DemoLibrary.tracks(in: directory)
                tracks = demos; favorites = []; playlists = []; sources = SourceConfiguration.defaults
            }
            // Operations from the still-interactive UI are applied after the disk
            // snapshot. No empty startup snapshot is ever written over stored data.
            ready = true
            applyingStartup = true
            let mutations = startupMutations
            startupMutations.removeAll()
            for mutation in mutations {
                switch mutation {
                case .add(let values): addTracks(values)
                case .favorite(let id): toggleFavorite(id)
                case .create(let playlist): playlists.append(playlist)
                case .addToPlaylist(let id, let track): addToPlaylist(id, track: track)
                case .removeFromPlaylist(let id, let trackID): removeFromPlaylist(id, trackID: trackID)
                case .deletePlaylist(let id): deletePlaylist(id)
                case .removeTrack(let id): removeTrack(id)
                case .sources(let values): sources = values
                case .importRemote(let playlist, let account, let values):
                    do { _ = try importRemotePlaylist(playlist, accountID: account, tracks: values) }
                    catch { self.error = error.localizedDescription }
                }
            }
            applyingStartup = false
            persist()
            _ = await saveTask?.value
        } catch {
            self.error = error.localizedDescription
            // An unreadable existing library must never be replaced with the UI's
            // partial startup state. The next launch can retry the original file.
            persistenceBlocked = true
            ready = true
            startupMutations.removeAll()
        }
    }

    func importURLs(_ urls: [URL]) async -> ImportResult {
        guard !busy else { return ImportResult(errors: ["已有导入任务正在进行，请稍后再试"] ) }
        busy = true
        defer { busy = false }
        let result = await importer.importURLs(urls)
        addTracks(result.tracks)
        if !result.errors.isEmpty { error = result.errors.prefix(4).joined(separator: "\n") }
        return result
    }

    func addTracks(_ additions: [Track]) {
        if !ready { startupMutations.append(.add(additions)) }
        for track in additions {
            if let index = tracks.firstIndex(where: { $0.id == track.id }) { tracks[index] = track }
            else if tracks.count < 10000 { tracks.append(track) }
            else { error = "音乐库最多保存 10000 首歌曲"; break }
        }
        persist()
    }
    func toggleFavorite(_ id: String) {
        guard tracks.contains(where: { $0.id == id }) else { return }
        if !ready { startupMutations.append(.favorite(id)) }
        if !favorites.insert(id).inserted { favorites.remove(id) }
        persist()
    }
    @discardableResult func createPlaylist(_ name: String) -> MusicPlaylist {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = MusicPlaylist(name: String((cleaned.isEmpty ? "未命名歌单" : cleaned).prefix(80)))
        if !ready { startupMutations.append(.create(playlist)) }
        playlists.append(playlist); persist(); return playlist
    }
    func addToPlaylist(_ id: String, track: Track) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        if !ready { startupMutations.append(.addToPlaylist(id, track)) }
        if !tracks.contains(where: { $0.id == track.id }) {
            guard tracks.count < 10000 else { error = "音乐库最多保存 10000 首歌曲"; return }
            tracks.append(track)
        }
        if !playlists[index].trackIDs.contains(track.id) { playlists[index].trackIDs.append(track.id) }
        persist()
    }
    func removeFromPlaylist(_ id: String, trackID: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        if !ready { startupMutations.append(.removeFromPlaylist(id, trackID)) }
        playlists[index].trackIDs.removeAll { $0 == trackID }; persist()
    }
    /// Import is a local snapshot. Reimport merges newly discovered tracks without
    /// deleting local edits or mutating the source platform's playlist.
    @discardableResult func importRemotePlaylist(_ remote: RemoteMusicPlaylist, accountID: String, tracks incoming: [Track]) throws -> MusicPlaylist {
        guard (DirectMusicAccess.sources.contains(remote.source) || remote.source == .appleMusic || remote.source == .spotify), !remote.id.isEmpty, !accountID.isEmpty,
              incoming.allSatisfy({ $0.source == remote.source && !$0.id.isEmpty && $0.duration.isFinite && $0.duration >= 0 && ((remote.source != .appleMusic && remote.source != .spotify) || !($0.sourceID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }) else { throw MusicError.message("歌单内容无效，未导入") }
        var seen = Set<String>()
        let unique = incoming.filter { seen.insert($0.id).inserted }
        if remote.source == .appleMusic || remote.source == .spotify {
            let incomingIDs = Set(unique.map(\.id))
            guard !tracks.contains(where: { incomingIDs.contains($0.id) && $0.source != remote.source }) else { throw MusicError.message("\(remote.source.title) 歌曲标识与其他来源冲突，此次歌单未导入") }
        }
        let existingIDs = Set(tracks.map(\.id))
        guard existingIDs.union(unique.map(\.id)).count <= 10000 else { throw MusicError.message("音乐库最多保存 10000 首；此次歌单未导入") }
        if !ready { startupMutations.append(.importRemote(remote, accountID, unique)) }
        // Encoding disambiguates arbitrary provider IDs without storing credentials.
        let identity = try JSONEncoder().encode([remote.source.rawValue, accountID, remote.id]).base64EncodedString()
        let id = "imported:\(identity)"
        for track in unique {
            if let index = tracks.firstIndex(where: { $0.id == track.id }) {
                var refreshed = track; refreshed.addedAt = tracks[index].addedAt; tracks[index] = refreshed
            } else { tracks.append(track) }
        }
        if let index = playlists.firstIndex(where: { $0.id == id }) {
            let oldIDs = Set(playlists[index].trackIDs)
            playlists[index].trackIDs.append(contentsOf: unique.map(\.id).filter { !oldIDs.contains($0) })
            persist(); return playlists[index]
        }
        let result = MusicPlaylist(id: id, name: String("\(remote.name) · \(remote.source.title)".prefix(80)), trackIDs: unique.map(\.id))
        playlists.append(result); persist(); return result
    }
    func deletePlaylist(_ id: String) {
        if !ready { startupMutations.append(.deletePlaylist(id)) }
        playlists.removeAll { $0.id == id }; persist()
    }
    /// UI imports report success only after the corresponding snapshot reached disk.
    @discardableResult func importRemotePlaylistAndSave(_ remote: RemoteMusicPlaylist, accountID: String, tracks incoming: [Track]) async throws -> MusicPlaylist {
        await load()
        try Task.checkCancellation()
        guard !persistenceBlocked else { throw MusicError.message("音乐资料库当前无法读取，未导入；请重新打开应用后重试。") }
        let playlist = try importRemotePlaylist(remote, accountID: accountID, tracks: incoming)
        if let result = await saveTask?.value {
            do { try result.get() }
            catch { throw MusicError.message("歌单已加入当前会话，但未能保存到磁盘。\(error.localizedDescription)") }
        }
        return playlist
    }
    /// Imports a complete library snapshot without creating a synthetic playlist.
    /// The returned count includes refreshed records; omitted songs stay in the
    /// local library, and validation finishes before any imported state changes.
    @discardableResult func importAppleMusicSongsAndSave(_ incoming: [Track]) async throws -> Int {
        try Task.checkCancellation()
        await load()
        try Task.checkCancellation()
        guard !persistenceBlocked else { throw MusicError.message("音乐资料库当前无法读取，未导入；请重新打开应用后重试。") }
        guard incoming.allSatisfy({
            $0.source == .appleMusic && !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !($0.sourceID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            $0.duration.isFinite && $0.duration >= 0
        }) else { throw MusicError.message("Apple Music 曲库内容无效，此次歌曲未导入") }
        var seen = Set<String>()
        let unique = incoming.filter { seen.insert($0.id).inserted }
        let indices = Dictionary(uniqueKeysWithValues: tracks.enumerated().map { ($0.element.id, $0.offset) })
        guard !unique.contains(where: { track in indices[track.id].map { tracks[$0].source != .appleMusic } ?? false }) else {
            throw MusicError.message("Apple Music 歌曲标识与其他来源冲突，此次歌曲未导入")
        }
        guard Set(indices.keys).union(unique.map(\.id)).count <= 10000 else {
            throw MusicError.message("音乐库最多保存 10000 首；此次 Apple Music 歌曲未导入")
        }
        try Task.checkCancellation()
        for track in unique {
            if let index = indices[track.id] {
                var refreshed = track
                refreshed.addedAt = tracks[index].addedAt
                tracks[index] = refreshed
            } else { tracks.append(track) }
        }
        persist()
        if let result = await saveTask?.value {
            do { try result.get() }
            catch { throw MusicError.message("Apple Music 歌曲已加入当前会话，但未能保存到磁盘。\(error.localizedDescription)") }
        }
        return unique.count
    }
    func retryPersistence() async {
        guard ready, !persistenceBlocked else { return }
        persist()
        _ = await saveTask?.value
    }
    /// Public Soda imports store identity and playback-range metadata. Temporary
    /// media URLs are refreshed only when playback begins.
    @discardableResult func importSodaSongsAndSave(_ incoming: [Track]) async throws -> Int {
        try Task.checkCancellation()
        await load()
        try Task.checkCancellation()
        guard !persistenceBlocked else {
            throw MusicError.message("音乐资料库当前无法读取，未导入；请重新打开应用后重试。")
        }
        guard incoming.allSatisfy({
            $0.source == .soda && !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !($0.sourceID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            $0.duration.isFinite && $0.duration >= 0 &&
            $0.sodaPlayback.map { range in
                range.fullDuration.isFinite && range.fullDuration > 0 && range.fullDuration <= 86400 &&
                range.start.isFinite && range.start >= 0 && range.duration.isFinite && range.duration > 0 &&
                range.start + range.duration <= range.fullDuration + 1
            } ?? true
        }) else { throw MusicError.message("汽水音乐歌曲资料无效，未导入。") }
        var seen = Set<String>()
        let unique = incoming.filter { seen.insert($0.id).inserted }
        let indices = Dictionary(uniqueKeysWithValues: tracks.enumerated().map { ($0.element.id, $0.offset) })
        guard !unique.contains(where: { track in indices[track.id].map { tracks[$0].source != .soda } ?? false }),
              Set(indices.keys).union(unique.map(\.id)).count <= 10000 else {
            throw MusicError.message("歌曲标识冲突或音乐库超过 10000 首，此次未导入。")
        }
        try Task.checkCancellation()
        for track in unique {
            var clean = track
            clean.url = nil
            if let index = indices[track.id] {
                clean.addedAt = tracks[index].addedAt
                tracks[index] = clean
            } else { tracks.append(clean) }
        }
        persist()
        if let result = await saveTask?.value {
            do { try result.get() }
            catch { throw MusicError.message("歌曲已加入当前会话，但未能保存到磁盘。\(error.localizedDescription)") }
        }
        return unique.count
    }
    func removeTrack(_ id: String) {
        if !ready { startupMutations.append(.removeTrack(id)) }
        tracks.removeAll { $0.id == id }; favorites.remove(id)
        for index in playlists.indices { playlists[index].trackIDs.removeAll { $0 == id } }
        // Removing a record never removes or relocates an original music file.
        persist()
    }
    func saveSources(_ values: [SourceConfiguration]) throws {
        sources = try SourceService.validatedConfigurations(values)
        if !ready { startupMutations.append(.sources(sources)) }
        persist()
    }
    func flushPersistence() async {
        if !ready { await load() }
        _ = await saveTask?.value
    }

    private func persist() {
        if !ready {
            Task { [weak self] in await self?.load() }
            return
        }
        guard !applyingStartup, !persistenceBlocked else { return }
        revision &+= 1
        let savedTracks = tracks.map { track in
            var value = track
            if value.source == .soda { value.url = nil }
            return value
        }
        let state = LibrarySnapshot(tracks: savedTracks, favorites: favorites, playlists: playlists, sources: sources)
        let revision = revision, storage = storage
        saveTask = Task { [weak self] in
            do {
                try await storage.save(state, revision: revision)
                if let self, self.revision == revision {
                    if error == persistenceError { error = nil }
                    persistenceError = nil
                }
                return .success(())
            } catch {
                let value = error as NSError
                let reason: String
                switch CocoaError.Code(rawValue: value.code) {
                case .fileWriteOutOfSpace where value.domain == NSCocoaErrorDomain: reason = "磁盘空间不足"
                case .fileWriteNoPermission where value.domain == NSCocoaErrorDomain: reason = "没有写入资料库的权限"
                case .fileWriteVolumeReadOnly where value.domain == NSCocoaErrorDomain: reason = "资料库所在磁盘为只读"
                default: reason = "磁盘写入失败（错误码 \(value.code)）"
                }
                let message = "无法保存音乐资料库：\(reason)。当前会话的更改尚未保存，请修复后重试保存。"
                if let self, self.revision == revision { self.error = message; self.persistenceError = message }
                return .failure(.message(message))
            }
        }
    }
}
