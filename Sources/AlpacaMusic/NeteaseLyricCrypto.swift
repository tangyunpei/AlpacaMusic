import CommonCrypto
import CryptoKit
import Foundation

/// Narrow eapi envelope for the platform's new lyric route. The protocol hash
/// and fixed AES key describe wire compatibility; they grant no account rights.
enum NeteaseLyricCrypto {
    static func encrypt(_ payload: Data, path: String = "/api/song/lyric/v1") throws -> Data {
        guard path == "/api/song/lyric/v1", payload.count <= 64 * 1024,
              let text = String(data: payload, encoding: .utf8) else {
            throw MusicError.message(L10n.string("网易云请求加密失败"))
        }
        let digest = Insecure.MD5.hash(data: Data("nobody\(path)use\(text)md5forencrypt".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let input = Data("\(path)-36cd479b6b5-\(text)-36cd479b6b5-\(digest)".utf8)
        let key = Data("e82ckenh8dichen8".utf8), capacity = input.count + kCCBlockSizeAES128
        var output = Data(count: capacity), count = 0
        let status = output.withUnsafeMutableBytes { destination in
            input.withUnsafeBytes { source in
                key.withUnsafeBytes { secret in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                            secret.baseAddress, key.count, nil, source.baseAddress, input.count,
                            destination.baseAddress, capacity, &count)
                }
            }
        }
        guard status == kCCSuccess else { throw MusicError.message(L10n.string("网易云请求加密失败")) }
        output.count = count
        return Data("params=\(output.map { String(format: "%02X", $0) }.joined())".utf8)
    }
}
