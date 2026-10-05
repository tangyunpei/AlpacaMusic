import CoreFoundation
import CryptoKit
import Foundation
import OSLog

/// Direct official-platform requests. No cookies are persisted by the provider,
/// no shared account is used, and every playback activation obtains a fresh URL.
struct QQDirectProvider: DirectMusicProvider {
    let source: MusicSource = .qq
    private let http: NativeMusicHTTP
    private let playbackFailureReporter: @Sendable (PlaybackTicketDiagnostic) -> Void
    init(http: NativeMusicHTTP = NativeMusicHTTP(), playbackFailureReporter: @escaping @Sendable (PlaybackTicketDiagnostic) -> Void = { $0.log() }) {
        self.http = http
        self.playbackFailureReporter = playbackFailureReporter
    }
    /// Contains fixed cookie names and booleans only, never session values or URLs.
    struct PlaybackTicketDiagnostic: Equatable, Sendable {
        let selectedCookieName: String?
        let primaryCandidatesBothPresent: Bool
        let primaryCandidatesDiffer: Bool
        let selectedValueWasDecoded: Bool
        var safeDescription: String {
            "ticket=\(selectedCookieName ?? "none") both_primary_present=\(primaryCandidatesBothPresent) primary_differ=\(primaryCandidatesDiffer) percent_decoded=\(selectedValueWasDecoded)"
        }
        func log() {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.byalpaca.music", category: "QQPlayback").error("Playback URL resolution failed: \(safeDescription, privacy: .public)")
        }
    }
    private struct Session {
        var uin: String
        var webUin: String
        var playbackKey: String?
        var playbackDiagnostic: PlaybackTicketDiagnostic
        var csrf: UInt32
        var legacyCSRF: UInt32
        var commUin: Any {
            // Website getUin parses only identifiers shorter than 14 digits.
            // Longer values stay strings, avoiding JavaScript number rounding.
            if webUin.count < 14, let number = UInt64(webUin) { return number }
            return webUin
        }
    }
    private func session(_ cookies: [MusicSessionCookie], endpoint: URL = URL(string: "https://u.y.qq.com/cgi-bin/musics.fcg")!) throws -> Session {
        let valid = DirectMusicAccess.sessionCookies(cookies, for: .qq).filter { $0.matches(endpoint) }.sorted { $0.path.count > $1.path.count }
        // The website's cookie getter decodes URI escapes before using values in
        // UIN, authst and CSRF fields. HTTP Cookie headers remain untouched.
        let protocolNames: Set<String> = ["login_type", "wxopenid", "wxuin", "uin", "qqmusic_uin", "p_uin", "qqmusic_key", "qm_keyst", "music_key", "wxskey", "p_lskey", "p_skey", "skey", "lskey"]
        var decoded: [String: String] = [:]
        for cookie in valid where protocolNames.contains(cookie.name) && !cookie.value.isEmpty && decoded[cookie.name] == nil {
            decoded[cookie.name] = try Self.protocolCookieValue(cookie.value)
        }
        func value(_ name: String) -> String? { decoded[name] }
        let wechat = value("login_type") == "2" || value("wxopenid") != nil
        let raw = (wechat ? value("wxuin") : value("uin")) ?? value("qqmusic_uin") ?? value("p_uin") ?? ""
        // Prefer the web music key; retain existing scoped fallback tickets.
        // The name is selected from constants, never from an arbitrary cookie.
        let playbackKeyName = ["qqmusic_key", "qm_keyst", "music_key", "wxskey"].first { value($0) != nil }
        let playbackKey = playbackKeyName.flatMap(value)
        let webKey = value("qqmusic_key"), legacyKey = value("qm_keyst")
        let bothPrimaryKeys = webKey != nil && legacyKey != nil
        let selectedRaw = playbackKeyName.flatMap { name in valid.first { $0.name == name && !$0.value.isEmpty }?.value }
        let playbackDiagnostic = PlaybackTicketDiagnostic(selectedCookieName: playbackKeyName, primaryCandidatesBothPresent: bothPrimaryKeys, primaryCandidatesDiffer: bothPrimaryKeys && webKey != legacyKey, selectedValueWasDecoded: selectedRaw != playbackKey)
        guard let id = normalizedUin(raw), (playbackKey ?? value("p_lskey")) != nil else {
            throw MusicError.message("请先在应用内登录 QQ 音乐，或重新登录已过期的账户。")
        }
        let digits = raw.hasPrefix("o") ? String(raw.dropFirst()) : raw
        let webUin = digits.count < 14 ? id : digits
        // Authentication tickets and CSRF inputs have different browser rules.
        // Missing CSRF candidates keep the official seed, 5381; qm_keyst is not
        // substituted into either hash, and p_lskey is not a legacy hash input.
        let csrf = value("qqmusic_key") ?? value("p_skey") ?? value("skey") ?? value("p_lskey") ?? value("lskey") ?? ""
        let legacyCSRF = value("skey") ?? value("qqmusic_key") ?? ""
        return Session(uin: id, webUin: webUin, playbackKey: playbackKey, playbackDiagnostic: playbackDiagnostic, csrf: QQWebSigning.csrfToken(csrf), legacyCSRF: QQWebSigning.csrfToken(legacyCSRF))
    }
    private static func protocolCookieValue(_ raw: String) throws -> String {
        var value = raw
        for _ in 0..<8 {
            guard let next = value.removingPercentEncoding else { break }
            if next == value { return value }
            value = next
        }
        throw MusicError.message("QQ 音乐登录信息的编码无法识别，请重新完成官网登录。")
    }
    func profile(cookies: [MusicSessionCookie]) async throws -> MusicAccountProfile {
        let account = try session(cookies)
        // userid=0 requests the authenticated account, never somebody's public page.
        let root = try await get(path: "/rsc/fcgi-bin/fcg_get_profile_homepage.fcg", query: ["cid": "205360838", "ct": "24", "userid": "0", "reqfrom": "1", "reqtype": "0", "needNewCode": "0"], account: account, cookies: cookies)
        guard let creator = (root["data"] as? [String: Any])?["creator"] as? [String: Any] else {
            throw MusicError.message("QQ 音乐没有返回当前账户资料，请重新完成官网登录。")
        }
        if let rawID = string(creator["uin"]), let id = normalizedUin(rawID) {
            // An opaque identity never overrides a conflicting numeric account.
            guard id == account.uin else {
                throw MusicError.message("QQ 音乐返回的账户与本次登录不一致，请重新完成官网登录。")
            }
        } else {
            // The official profile treats creator.uin as optional and uses the
            // authenticated userid=0 response's encrypt_uin for self identity.
            // This shared website contract applies to both QQ and WeChat login.
            // Malformed nonempty numeric fields must not silently fall back.
            guard hiddenUin(creator["uin"]) else {
                throw MusicError.message("QQ 音乐返回的账户资料缺少有效账号标识（本人资料：数字标识字段格式不支持），请稍后重试。")
            }
            guard validEncryptedUin(creator["encrypt_uin"]) else {
                let value = creator["encrypt_uin"]
                let missing = value == nil || value is NSNull || (value as? String)?.isEmpty == true
                let category = missing ? "缺少加密标识" : "加密标识字段格式不支持"
                throw MusicError.message("QQ 音乐返回的账户资料缺少有效账号标识（本人资料：数字标识隐藏；\(category)），请稍后重试。")
            }
        }
        guard let rawName = string(creator["nick"]) ?? string(creator["nickname"]),
              !plain(rawName).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MusicError.message("QQ 音乐未返回当前账户昵称，请稍后重试。")
        }
        return MusicAccountProfile(id: account.uin, displayName: plain(rawName))
    }
    func search(_ query: String, cookies: [MusicSessionCookie]) async throws -> [Track] {
        let account = try session(cookies)
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        guard query.count <= 200 else { throw MusicError.message("搜索内容过长，请缩短关键词。") }
        let data = try await rpc(module: "music.search.SearchCgiService", method: "DoSearchForQQMusicDesktop", parameters: ["remoteplace": "txt.yqq.song", "searchid": String(UInt64.random(in: 1...UInt64.max)), "search_type": 0, "query": query, "page_num": 1, "num_per_page": 40], account: account, cookies: cookies)
        if let meta = data["meta"] as? [String: Any], (integer(meta["is_filter"]) ?? 0) < 0 {
            throw MusicError.message("QQ 音乐限制了本次搜索，请重新登录或稍后重试。")
        }
        guard let body = data["body"] as? [String: Any], let song = body["song"] as? [String: Any], let list = song["list"] as? [[String: Any]] else { throw malformed() }
        let tracks = list.compactMap(track)
        guard tracks.count == list.count else { throw malformed() }
        return uniqueTracks(tracks)
    }
    func lyrics(_ track: Track, cookies: [MusicSessionCookie]) async throws -> LyricsPayload? {
        guard track.source == .qq, let mid = track.sourceID, validID(mid) else { throw MusicError.message("歌曲缺少有效的 QQ 音乐标识，无法读取歌词。") }
        let endpoint = URL(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg")!
        let account = try session(cookies, endpoint: endpoint)
        let response = try await get(path: endpoint.path, query: ["songmid": mid, "nobase64": "0", "notice": "0", "needNewCode": "0"], account: account, cookies: cookies)
        func text(_ value: Any?) throws -> String? {
            guard let value else { return nil }
            guard let value = value as? String, value.utf8.count <= LyricsParser.maximumBytes * 2 else { throw MusicError.message("QQ 音乐歌词格式无法读取。") }
            if value.isEmpty { return nil }
            guard let bytes = Data(base64Encoded: value), bytes.count <= LyricsParser.maximumBytes,
                  let decoded = String(data: bytes, encoding: .utf8) else { throw MusicError.message("QQ 音乐歌词编码无法读取。") }
            return decoded
        }
        guard let original = try text(response["lyric"]), !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .init(text: original, translation: try text(response["trans"]))
    }
    func playlists(profile: MusicAccountProfile, cookies: [MusicSessionCookie]) async throws -> [RemoteMusicPlaylist] {
        let account = try session(cookies)
        guard normalizedUin(profile.id) == account.uin else { throw MusicError.message("QQ 音乐账户已改变，请重新登录。") }
        var output: [RemoteMusicPlaylist] = []
        for kind in ["created", "favorite"] {
            var offset = 0
            var previousPages = Set<String>()
            for page in 0..<50 {
                let created = kind == "created", size = 100
                let path = created ? "/rsc/fcgi-bin/fcg_user_created_diss" : "/fav/fcgi-bin/fcg_get_profile_order_asset.fcg"
                let parameters = created ? ["hostuin": account.uin, "sin": String(offset), "size": String(size)] : ["ct": "20", "cid": "205360956", "userid": account.uin, "reqtype": "3", "sin": String(offset), "ein": String(offset + size - 1)]
                let root = try await get(path: path, query: parameters, account: account, cookies: cookies)
                guard let data = root["data"] as? [String: Any], let items = data[created ? "disslist" : "cdlist"] as? [[String: Any]] else { throw malformed() }
                let ordinary = items.filter { let dir = integer($0["dirid"]); return dir != 205 && dir != 206 }
                let converted = ordinary.compactMap { item -> RemoteMusicPlaylist? in
                    guard let id = string(item["tid"]) ?? string(item["dissid"]), validID(id),
                          let name = string(item["diss_name"]) ?? string(item["dissname"]) else { return nil }
                    return RemoteMusicPlaylist(id: id, name: plain(name), trackCount: max(0, integer(item["song_cnt"]) ?? integer(item["songnum"]) ?? 0), artworkURL: artwork(string(item["diss_cover"]) ?? string(item["logo"])), source: .qq)
                }
                guard converted.count == ordinary.count else { throw malformed() }
                let pageIDs = items.compactMap { string($0["tid"]) ?? string($0["dissid"]) }.joined(separator: ",")
                if !items.isEmpty && !previousPages.insert(pageIDs).inserted { throw MusicError.message("QQ 音乐返回了重复的歌单分页，请稍后重试。") }
                for playlist in converted where !output.contains(where: { $0.id == playlist.id }) { output.append(playlist) }
                offset += items.count
                let total = integer(data["totaldiss"]) ?? integer(data["totoal"]) ?? integer(data["total"])
                if items.isEmpty, let total, offset < total { throw malformed() }
                if items.isEmpty || (total.map { offset >= $0 } ?? (items.count < size)) { break }
                if page == 49 { throw MusicError.message("QQ 音乐歌单数量超过本次读取范围，请稍后缩小范围。") }
            }
        }
        return output
    }
    func tracks(in playlist: RemoteMusicPlaylist, cookies: [MusicSessionCookie]) async throws -> [Track] {
        let account = try session(cookies)
        guard playlist.source == .qq, !playlist.id.isEmpty, playlist.id.utf8.allSatisfy({ (48...57).contains($0) }),
              let identifier = Int64(playlist.id), identifier > 0 else { throw MusicError.message("QQ 音乐歌单标识无效，请刷新歌单列表。") }
        var output: [Track] = [], offset = 0
        var hydrated: [Int64: Track] = [:]
        var hydrationFailures: [Int64: String] = [:]
        var detailRequests = 0, failedCount = 0
        var issues: [String] = [], pageSignatures = Set<Data>()
        var reportedTotal: Int?
        var firstFailureSummary: String?
        for page in 0..<100 {
            // The official page sends parseInt(id, 10). A JSON string is rejected
            // by this RPC with code 10006, even when the decimal contents match.
            let data = try await rpc(module: "music.srfDissInfo.aiDissInfo", method: "uniform_get_Dissinfo", parameters: ["disstid": identifier, "userinfo": 1, "tag": 1, "orderlist": 1, "song_begin": offset, "song_num": 100, "onlysonglist": 1, "enc_host_uin": ""], account: account, cookies: cookies)
            guard let list = data["songlist"] as? [Any] else {
                throw MusicError.message("QQ 音乐歌单响应格式异常（读取歌单曲目：第 \(page + 1) 页 songlist 为\(playlistFieldType(data["songlist"]))，预期列表），本次未导入。")
            }
            if let total = integer(data["total_song_num"]) {
                guard total >= 0, reportedTotal == nil || reportedTotal == total else {
                    throw MusicError.message("QQ 音乐歌单分页总数不一致，本次未导入，请刷新后重试。")
                }
                reportedTotal = total
            }
            if !list.isEmpty {
                let pageData = try JSONSerialization.data(withJSONObject: list, options: [.sortedKeys])
                guard pageSignatures.insert(Data(SHA256.hash(data: pageData))).inserted else {
                    throw MusicError.message("QQ 音乐返回了重复的歌单分页，本次未导入，请稍后重试。")
                }
            }
            var parsed: [Track] = []
            for (index, value) in list.enumerated() {
                try Task.checkCancellation()
                let position = offset + index + 1
                var failure: String?
                if let row = value as? [String: Any], let item = track(row) {
                    parsed.append(item)
                } else if let original = value as? [String: Any], let row = trackFields(original),
                          trackMID(row) == nil, let songID = playlistSongID(row) {
                    if let cached = hydrated[songID] { parsed.append(cached); continue }
                    if let cached = hydrationFailures[songID] { failure = cached }
                    else if detailRequests >= 20 {
                        failure = "补资料失败：已达到每次导入最多 20 次的补充请求上限。"
                    }
                    if failure == nil {
                        detailRequests += 1
                        do {
                            let item = try await hydratePlaylistTrack(songID, account: account, cookies: cookies)
                            try Task.checkCancellation()
                            hydrated[songID] = item; parsed.append(item)
                        } catch is CancellationError { throw CancellationError() }
                        catch let error as MusicError { failure = "补资料失败：\(error.localizedDescription)" }
                        catch { failure = "补资料失败：无法完成详情请求。" }
                    }
                    if let failure { hydrationFailures[songID] = failure }
                } else { failure = "：\(playlistTrackIssue(value))" }
                if let failure {
                    failedCount += 1
                    if issues.count < 20 { issues.append("第 \(page + 1) 页，第 \(position) 首\(failure)") }
                    if firstFailureSummary == nil {
                        let reason = failure.hasPrefix("：") ? "：歌曲资料缺少有效标识或标题。" : failure.replacingOccurrences(of: " MID", with: "标识")
                        firstFailureSummary = "第 \(position) 首\(reason)"
                    }
                }
            }
            output = uniqueTracks(output + parsed); offset += list.count
            let total = reportedTotal ?? (playlist.trackCount > 0 ? playlist.trackCount : nil)
            if list.isEmpty, let total, offset < total {
                throw MusicError.message("QQ 音乐歌单分页格式不完整（第 \(page + 1) 页为空，已读取 \(offset)/\(total) 首），本次未导入。")
            }
            if list.isEmpty || (total.map { offset >= $0 } ?? (list.count < 100)) {
                try Task.checkCancellation()
                if let total, offset != total {
                    throw MusicError.message("QQ 音乐歌单总数与读取数量不一致（已读取 \(offset)/\(total) 首），本次未导入。")
                }
                guard failedCount > 0 else { return output }
                let omitted = failedCount - issues.count
                let remainder = omitted > 0 ? "；另有 \(omitted) 条失败原因未展开" : ""
                let message = "QQ 音乐歌单曲目格式不完整（成功解析 \(offset - failedCount)/\(offset) 首；\(issues.joined(separator: "；"))\(remainder)），本次未导入。"
                guard !output.isEmpty else { throw MusicError.message(message) }
                let summary = "已读完整份 \(offset) 首歌单，成功解析 \(offset - failedCount)/\(offset) 首，\(failedCount) 首未能读取。\(firstFailureSummary ?? "")\(remainder)"
                throw MusicError.incompletePlaylist(.init(tracks: output, totalCount: offset, failedCount: failedCount, issues: issues, message: summary))
            }
            if page == 99 { throw MusicError.message("QQ 音乐歌单过大，无法一次读取全部曲目。") }
        }
        return output
    }
    private func hydratePlaylistTrack(_ id: Int64, account: Session, cookies: [MusicSessionCookie]) async throws -> Track {
        // Official song detail accepts song_id. Only replace the damaged identity
        // after the server confirms this exact numeric ID; never treat it as MID.
        let data = try await rpc(module: "music.pf_song_detail_svr", method: "get_song_detail_yqq", parameters: ["song_id": id], account: account, cookies: cookies)
        guard let info = data["track_info"] as? [String: Any] else {
            throw MusicError.message("平台详情缺少曲目对象，无法确认该歌曲是否仍存在。")
        }
        guard let returnedID = positiveSongID(info["id"]) else {
            throw MusicError.message("平台详情缺少有效数字歌曲编号。")
        }
        guard returnedID == id else { throw MusicError.message("平台返回的歌曲与请求编号不一致。") }
        guard trackMID(info) != nil else { throw MusicError.message("平台详情仍没有合法歌曲 MID。") }
        guard let item = track(info) else { throw MusicError.message("平台详情缺少可用标题或曲目结构不受支持。") }
        return item
    }
    /// Static field categories and row counts only: never echo track/account data.
    private func playlistFieldType(_ value: Any?) -> String {
        guard let value else { return "缺失" }
        if value is NSNull { return "空值" }
        if value is String { return "文本" }
        if value is NSNumber { return "数字或布尔值" }
        if value is [String: Any] { return "对象" }
        if value is [Any] { return "列表" }
        return "不支持的类型"
    }
    private func playlistTrackIssue(_ value: Any) -> String {
        guard let original = value as? [String: Any] else { return "曲目为\(playlistFieldType(value))，预期对象" }
        guard let row = trackFields(original) else {
            let present = ["track_info", "songInfo", "songinfo", "song"].filter { original[$0] != nil }
            if present.count > 1 { return "曲目含多个包裹字段，格式不明确" }
            return "曲目包裹字段 \(present.first ?? "songInfo")=\(playlistFieldType(original[present.first ?? "songInfo"]))，预期对象"
        }
        if trackMID(row) == nil {
            let mid = "mid=\(midDiagnostic(row["mid"]))、songmid=\(midDiagnostic(row["songmid"]))"
            let numeric = "id=\(numericIDDiagnostic(row["id"]))、songid=\(numericIDDiagnostic(row["songid"]))"
            let conflict = positiveSongID(row["id"]).flatMap { id in positiveSongID(row["songid"]).map { id != $0 } } == true
            return "歌曲标识格式不支持（\(mid)；\(numeric)\(conflict ? "；两个数字编号冲突" : "")）"
        }
        return "标题字段 title=\(playlistFieldType(row["title"]))、name=\(playlistFieldType(row["name"]))、songname=\(playlistFieldType(row["songname"]))"
    }
    func resolve(_ track: Track, cookies: [MusicSessionCookie]) async throws -> URL {
        let account = try session(cookies, endpoint: URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!)
        do {
            return try await resolve(track, account: account, cookies: cookies)
        } catch {
            if !(error is CancellationError), !Task.isCancelled { playbackFailureReporter(account.playbackDiagnostic) }
            throw error
        }
    }
    private func resolve(_ track: Track, account: Session, cookies: [MusicSessionCookie]) async throws -> URL {
        guard track.source == .qq, let mid = track.sourceID, validID(mid) else { throw MusicError.message("QQ 音乐歌曲标识无效，请重新搜索。") }
        guard let playbackKey = account.playbackKey else {
            throw MusicError.message("QQ 音乐网页登录有效，但本次会话缺少播放票据，请重新打开应用内官网窗口完成登录。")
        }
        let metadataAccount = try session(cookies)
        guard metadataAccount.uin == account.uin else {
            throw MusicError.message("QQ 音乐资料与播放会话的账户不一致，请重新打开应用内官网窗口完成登录。")
        }
        let detail = try await rpc(module: "music.pf_song_detail_svr", method: "get_song_detail_yqq", parameters: ["song_mid": mid], account: metadataAccount, cookies: cookies)
        guard let info = detail["track_info"] as? [String: Any], string(info["mid"]) == mid else {
            throw MusicError.message("QQ 音乐未返回所选歌曲的资料，请重新搜索后重试。")
        }
        guard let file = info["file"] as? [String: Any], let mediaID = file["media_mid"] as? String, validID(mediaID) else {
            throw MusicError.message("QQ 音乐未返回这首歌的有效媒体编号，暂时无法请求播放地址。")
        }
        // One ordinary file, using the actual media identifier and the user's
        // existing scoped ticket. No quality sweep, alternate account, or retry
        // through another authorization endpoint after a platform rejection.
        let requestedFilename = "M500\(mediaID).mp3"
        let data = try await playbackData(mid: mid, songType: integer(info["type"]) ?? 0, filename: requestedFilename, account: account, playbackKey: playbackKey, cookies: cookies)
        guard let entries = data["midurlinfo"] as? [[String: Any]] else {
            throw MusicError.message("QQ 音乐播放授权响应缺少歌曲列表，请稍后重试或更新应用。")
        }
        guard let entry = entries.first(where: { string($0["songmid"]) == mid }) else {
            throw MusicError.message("QQ 音乐未返回所选歌曲的播放授权，请在官网查看其可播放状态。")
        }
        if let result = integer(entry["result"]), result != 0 {
            throw MusicError.message("QQ 音乐未能返回这首歌的播放地址（平台返回码 \(result)），平台未说明具体原因。")
        }
        if let filename = entry["filename"] as? String, !filename.isEmpty, filename != requestedFilename {
            throw MusicError.message("QQ 音乐返回的音频文件与本次请求不一致，暂未播放。")
        }
        guard let purl = string(entry["purl"]), !purl.isEmpty else {
            throw MusicError.message("QQ 音乐未提供当前账户可播放的完整音频链接，请在官网查看这首歌的可播放状态。")
        }
        guard let path = URL(string: purl)?.path else { throw MusicError.message("QQ 音乐返回的音频地址无法解析，请稍后重试。") }
        let filename = URL(fileURLWithPath: path).lastPathComponent
        guard !filename.uppercased().hasPrefix("RS"), !path.lowercased().contains("/trial"), !path.contains("试听") else {
            throw MusicError.message("QQ 音乐仅返回了试听音频，暂不播放；请在官网查看完整歌曲的可播放状态。")
        }
        let fileExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard ["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "mp4"].contains(fileExtension) else {
            throw MusicError.message("QQ 音乐返回的音频格式暂不支持；加密文件不会被解密或播放。")
        }
        // Inspect every server-supplied candidate before giving up. A nonempty
        // but unusable thirdip must not hide a valid sip from the same response.
        // Use the website's default only when no candidates were supplied.
        let reportedServers = (data["thirdip"] as? [String] ?? []) + (data["sip"] as? [String] ?? [])
        let servers = reportedServers.isEmpty ? ["https://ws6.stream.qqmusic.qq.com/"] : reportedServers
        var rejectedHosts: [String] = []
        var unsupportedConnection = false
        var firstAddressIssue: String?
        // Categories are fixed app text; never include raw URLs, schemes or IPs.
        func recordAddressIssue(_ reason: String) {
            if firstAddressIssue == nil { firstAddressIssue = reason }
        }
        for server in servers {
            guard let base = URL(string: server), let resolved = URL(string: purl, relativeTo: base)?.absoluteURL,
                  var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else {
                recordAddressIssue("候选地址无法解析"); continue
            }
            guard let scheme = components.scheme else { recordAddressIssue("候选地址缺少协议"); continue }
            guard scheme == "https" || scheme == "http" else { recordAddressIssue("地址协议不受支持"); continue }
            if components.scheme == "http", components.port == 80 { components.port = nil }
            components.scheme = "https"
            guard let url = components.url else { recordAddressIssue("候选地址无法解析"); continue }
            guard let rawHost = url.host, !rawHost.isEmpty else { recordAddressIssue("候选地址缺少主机"); continue }
            guard let host = safeDiagnosticHost(rawHost) else {
                recordAddressIssue(rawHost.contains(":") ? "IP 地址格式不受支持" : "主机名格式不受支持")
                continue
            }
            if url.user != nil || url.password != nil || (url.port != nil && url.port != 443) {
                unsupportedConnection = true
                if rejectedHosts.count < 3, !rejectedHosts.contains(host) { rejectedHosts.append(host) }
                continue
            }
            guard host.hasSuffix(".qqmusic.qq.com") || host.hasSuffix(".music.tc.qq.com") else {
                if rejectedHosts.count < 3, !rejectedHosts.contains(host) { rejectedHosts.append(host) }
                continue
            }
            return url
        }
        guard !rejectedHosts.isEmpty else {
            throw MusicError.message("QQ 音乐返回的音频地址不可用（\(firstAddressIssue ?? "没有可用的候选地址")），请稍后重试。")
        }
        let hosts = rejectedHosts.joined(separator: "、")
        if unsupportedConnection { throw MusicError.message("QQ 音乐返回的音频连接参数不受支持（主机：\(hosts)）。") }
        throw MusicError.message("QQ 音乐返回了不受信任的音频地址（主机：\(hosts)），暂未播放。")
    }
    private func playbackData(mid: String, songType: Int, filename: String, account: Session, playbackKey: String, cookies: [MusicSessionCookie]) async throws -> [String: Any] {
        let parameters: [String: Any] = ["guid": String(UInt64.random(in: 10_000_000...99_999_999)), "songmid": [mid], "songtype": [songType], "uin": account.webUin, "loginflag": 1, "platform": "20", "filename": [filename]]
        let payload: [String: Any] = ["comm": ["uin": account.webUin, "format": "json", "ct": 19, "cv": 0, "authst": playbackKey], "req_0": ["module": "vkey.GetVkeyServer", "method": "CgiGetVkey", "param": parameters]]
        var request = request(URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let root = try json(await http.data(for: request, source: .qq, cookies: cookies))
        try check(root, operation: "获取播放地址")
        guard let result = root["req_0"] as? [String: Any] else { throw malformed() }
        try check(result, operation: "获取播放地址")
        guard let data = result["data"] as? [String: Any] else { throw malformed() }
        if data["code"] != nil { try check(data, operation: "获取播放地址") }
        return data
    }
    private func rpc(module: String, method: String, parameters: [String: Any], account: Session, cookies: [MusicSessionCookie]) async throws -> [String: Any] {
        // Metadata keeps the browser cookie + UIN/CSRF contract. Playback uses
        // its separate ticket-authenticated request above; do not mix the two.
        let payload: [String: Any] = ["comm": ["ct": 24, "cv": 4747474, "uin": account.commUin, "format": "json", "inCharset": "utf-8", "outCharset": "utf-8", "notice": 0, "platform": "yqq.json", "needNewCode": 1, "g_tk": account.legacyCSRF, "g_tk_new_20200303": account.csrf], "req_0": ["module": module, "method": method, "param": parameters]]
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        var url = URLComponents(string: "https://u.y.qq.com/cgi-bin/musics.fcg")!
        url.queryItems = [URLQueryItem(name: "sign", value: QQWebSigning.signature(for: body))]
        var request = request(url.url!); request.httpMethod = "POST"; request.httpBody = body; request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let operation = ["uniform_get_Dissinfo": "读取歌单曲目", "get_song_detail_yqq": "读取歌曲资料", "DoSearchForQQMusicDesktop": "搜索歌曲"][method] ?? "完成请求"
        let root = try json(await http.data(for: request, source: .qq, cookies: cookies)); try check(root, operation: operation)
        guard let result = root["req_0"] as? [String: Any] else { throw malformed() }; try check(result, operation: operation)
        guard let data = result["data"] as? [String: Any] else { throw malformed() }
        if data["code"] != nil { try check(data, operation: operation) }; return data
    }
    private func get(path: String, query: [String: String], account: Session, cookies: [MusicSessionCookie]) async throws -> [String: Any] {
        var parameters = query
        parameters.merge(["format": "json", "uin": account.uin, "loginUin": account.uin, "hostUin": "0", "g_tk": String(account.legacyCSRF), "g_tk_new_20200303": String(account.csrf), "inCharset": "utf8", "outCharset": "utf-8", "platform": "yqq.json", "needNewCode": "1"]) { original, _ in original }
        var url = URLComponents(string: "https://c.y.qq.com\(path)")!; url.queryItems = parameters.keys.sorted().map { URLQueryItem(name: $0, value: parameters[$0]) }
        let root = try json(await http.data(for: request(url.url!), source: .qq, cookies: cookies)); try check(root); return root
    }
    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url); request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer"); request.setValue("https://y.qq.com", forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Accept"); request.setValue("AlpacaMusic/1.0 (macOS; QQ Music Web)", forHTTPHeaderField: "User-Agent"); return request
    }
    private func json(_ data: Data) throws -> [String: Any] {
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw malformed() }; return result
    }
    private func check(_ result: [String: Any], operation: String = "完成请求") throws {
        guard let code = integer(result["code"]) else { throw malformed() }
        guard code == 0 else {
            if [1000, -1000, 101010].contains(code) { throw MusicError.message("QQ 音乐登录已失效，请重新登录（平台返回码 \(code)）。") }
            throw MusicError.message("QQ 音乐\(operation)失败（平台返回码 \(code)），请稍后重试。")
        }
    }
    private func track(_ row: [String: Any]) -> Track? {
        guard let row = trackFields(row) else { return nil }
        guard let mid = trackMID(row),
              let title = string(row["title"]) ?? string(row["name"]) ?? string(row["songname"]) else { return nil }
        let singers = (row["singer"] as? [[String: Any]] ?? []).compactMap { string($0["name"]) }.joined(separator: " / ")
        let album = row["album"] as? [String: Any] ?? [:], albumID = string(album["mid"]) ?? string(row["albummid"])
        let cover = albumID.flatMap { validID($0) ? URL(string: "https://y.gtimg.cn/music/photo_new/T002R500x500M000\($0).jpg") : nil }
        return Track(id: "qq:\(mid)", title: plain(title), artist: plain(singers), album: plain(string(album["title"]) ?? string(album["name"]) ?? string(row["albumname"]) ?? ""), duration: Double(max(0, integer(row["interval"]) ?? 0)), source: .qq, sourceID: mid, artworkURL: cover, format: "QQ 音乐")
    }
    private func trackMID(_ row: [String: Any]) -> String? {
        [row["mid"], row["songmid"]].compactMap { $0 as? String }.first(where: validID)
    }
    private func positiveSongID(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        guard let text = string(value), !text.isEmpty, text.count <= 19,
              text.utf8.allSatisfy({ (48...57).contains($0) }), let id = Int64(text), id > 0 else { return nil }
        return id
    }
    private func playlistSongID(_ row: [String: Any]) -> Int64? {
        let id = positiveSongID(row["id"]), songID = positiveSongID(row["songid"])
        if let id, let songID, id != songID { return nil }
        return id ?? songID
    }
    private func numericIDDiagnostic(_ value: Any?) -> String {
        "\(playlistFieldType(value))（\(positiveSongID(value) == nil ? "非有效正整数" : "有效正整数")）"
    }
    private func midDiagnostic(_ value: Any?) -> String {
        guard let text = value as? String else { return playlistFieldType(value) }
        if text.isEmpty { return "空文本" }
        if text.count > 80 { return "超长字段" }
        return validID(text) ? "有效" : "含不支持字符"
    }
    /// Supported response containers share one parser in search and playlists.
    /// Do not merge conflicting containers or invent a MID from a numeric song ID.
    private func trackFields(_ row: [String: Any]) -> [String: Any]? {
        let containers = ["track_info", "songInfo", "songinfo", "song"].filter { row[$0] != nil }
        guard let key = containers.first else { return row }
        guard containers.count == 1 else { return nil }
        return row[key] as? [String: Any]
    }
    private func uniqueTracks(_ tracks: [Track]) -> [Track] { var seen = Set<String>(); return tracks.filter { seen.insert($0.id).inserted } }
    /// QQ's short UIN cookies may be padded (o0012345678), while profile JSON
    /// returns an integer. Normalize decimal text without rounding long WeChat IDs.
    private func normalizedUin(_ raw: String) -> String? {
        let digits = raw.hasPrefix("o") ? raw.dropFirst() : raw[...]
        guard !digits.isEmpty, digits.count <= 24, digits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        let result = String(digits.drop(while: { $0 == "0" }))
        return result.count >= 5 ? result : nil
    }
    private func hiddenUin(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return true }
        guard let raw = string(value) else { return false }
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return raw.utf8.allSatisfy { $0 == 48 }
    }
    private func validEncryptedUin(_ value: Any?) -> Bool {
        // Hygiene limits for an opaque server value, not a claimed cipher format.
        // The value is never decrypted, displayed, persisted or used in a URL.
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 512 else { return false }
        return value.unicodeScalars.allSatisfy { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }
            && value != "0"
    }
    /// Diagnose CDN compatibility without exposing signed paths, queries or userinfo.
    private func safeDiagnosticHost(_ value: String?) -> String? {
        guard let value = value?.lowercased(), !value.isEmpty, value.utf8.count <= 253,
              value.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }) else { return nil }
        return value
    }
    private func validID(_ value: String) -> Bool { !value.isEmpty && value.count <= 80 && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) } }
    private func string(_ value: Any?) -> String? { if let value = value as? String { return value }; if let value = value as? NSNumber { return value.stringValue }; return nil }
    private func integer(_ value: Any?) -> Int? { if let value = value as? NSNumber { return value.intValue }; if let value = value as? String { return Int(value) }; return nil }
    private func plain(_ value: String) -> String { value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">") }
    private func artwork(_ value: String?) -> URL? {
        guard let value, var url = URLComponents(string: value.hasPrefix("//") ? "https:\(value)" : value), url.scheme == "http" || url.scheme == "https", url.user == nil, url.password == nil else { return nil }
        url.scheme = "https"; return url.url
    }
    private func malformed() -> MusicError { .message("QQ 音乐响应格式已变化，请稍后重试或更新应用。") }
}
