import AVFoundation
import Foundation

struct PlaybackErrorLogFact: Sendable {
    let domain: String
    let code: Int
}

/// Preserve app-authored messages, but never show arbitrary NSError text,
/// userInfo, URLs, or AVPlayer error comments that can contain signed media URLs.
enum PlaybackErrorMessage {
    static func describe(_ error: (any Error)?, source: MusicSource, fallback: String,
                         logEvents: [PlaybackErrorLogFact] = []) -> String {
        if let error = error as? SpotifyAPIError { return error.localizedDescription }
        if let error = error as? SpotifyAuthorizationError { return error.localizedDescription }
        if let error = error as? MusicError { return error.localizedDescription }
        if let error = error as? SourceFailure { return error.message }
        var facts: [PlaybackErrorLogFact] = []
        if let error {
            var current: NSError? = error as NSError
            var seen = Set<ObjectIdentifier>()
            while let value = current, facts.count < 5, seen.insert(ObjectIdentifier(value)).inserted {
                facts.append(PlaybackErrorLogFact(domain: value.domain, code: value.code))
                current = value.userInfo[NSUnderlyingErrorKey] as? NSError
            }
        }
        facts.append(contentsOf: logEvents.suffix(3))
        let transport = facts.filter { $0.domain == NSURLErrorDomain || $0.domain == "HTTP" }
        let other = facts.filter { $0.domain != NSURLErrorDomain && $0.domain != "HTTP" }
        let reasons = (transport + other).compactMap(reason)
        let detail = reasons.first ?? fallback
        var seen = Set<String>()
        let codes = facts.compactMap { fact -> String? in
            // Unrecognized domains are intentionally not echoed back.
            let allowed = [NSURLErrorDomain, AVFoundationErrorDomain, "CoreMediaErrorDomain", NSOSStatusErrorDomain, NSPOSIXErrorDomain, NSCocoaErrorDomain, "HTTP"]
            guard allowed.contains(fact.domain) else { return nil }
            let value = "\(fact.domain) \(fact.code)"
            return seen.insert(value).inserted ? value : nil
        }
        return codes.isEmpty ? detail : L10n.string("\(detail)（\(codes.joined(separator: L10n.string("；")))）")
    }

    private static func reason(_ fact: PlaybackErrorLogFact) -> String? {
        if fact.domain == NSURLErrorDomain {
            switch URLError.Code(rawValue: fact.code) {
            case .timedOut: return L10n.string("音频服务器响应超时，请重试。")
            case .notConnectedToInternet: return L10n.string("当前没有网络连接。")
            case .networkConnectionLost: return L10n.string("播放期间网络连接中断，请重试。")
            case .cannotFindHost, .dnsLookupFailed: return L10n.string("无法解析音频服务器地址，请检查网络或 DNS。")
            case .cannotConnectToHost: return L10n.string("无法连接音频服务器。")
            case .badServerResponse: return L10n.string("音频服务器返回了无效响应；尚不能确定是否与账号权限有关。")
            case .resourceUnavailable: return L10n.string("音频服务器报告资源当前不可用，未提供更具体原因。")
            case .fileDoesNotExist: return L10n.string("音频文件已移动或删除，请重新导入。")
            case .noPermissionsToReadFile: return L10n.string("应用没有读取此音频文件的权限，请重新选择文件授权。")
            case .userAuthenticationRequired: return L10n.string("音频服务器要求重新验证访问权限，请重试或重新登录平台。")
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                return L10n.string("音频服务器的 HTTPS 安全连接失败，请检查系统时间和网络。")
            default: return nil
            }
        }
        if fact.domain == "HTTP" {
            switch fact.code {
            case 401: return L10n.string("音频服务器要求身份验证（HTTP 401），请重新登录后重试。")
            case 403: return L10n.string("音频服务器拒绝访问（HTTP 403）；服务器未说明是否为地址过期、权限或地区限制。")
            case 404, 410: return L10n.string("平台给出的音频资源当前不存在，请重新获取播放地址。")
            case 429: return L10n.string("音频服务器限制了请求频率，请稍后重试。")
            case 500...599: return L10n.string("音频服务器暂时出错，请稍后重试。")
            default: return nil
            }
        }
        guard fact.domain == AVFoundationErrorDomain else { return nil }
        switch AVError.Code(rawValue: fact.code) {
        case .contentIsProtected: return L10n.string("音频受内容保护，当前播放路径无法解码此资源。")
        case .contentIsNotAuthorized, .applicationIsNotAuthorized: return L10n.string("系统播放器未获得此音频的播放授权。")
        case .fileFormatNotRecognized, .fileFailedToParse, .failedToParse: return L10n.string("系统无法识别或解析平台返回的音频格式。")
        case .decodeFailed, .decoderNotFound, .undecodableMediaData, .formatUnsupported: return L10n.string("系统无法解码此音频，文件可能损坏或格式不受支持。")
        case .decoderTemporarilyUnavailable: return L10n.string("系统音频解码器暂时不可用，请重试。")
        case .serverIncorrectlyConfigured: return L10n.string("音频服务器的响应不符合系统播放器要求。")
        case .contentIsUnavailable, .noLongerPlayable: return L10n.string("系统报告此音频目前不可播放；平台未提供更具体原因。")
        default: return nil
        }
    }
}
