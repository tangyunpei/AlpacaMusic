import CryptoKit
import Foundation

/// The platform's zzc wire signature is a public request checksum, not an
/// authentication credential. It never grants membership or playback rights.
enum QQWebSigning {
    static func signature(for body: Data) -> String {
        let digest = Array(Insecure.SHA1.hash(data: body))
        let hexadecimal = Array(digest.map { String(format: "%02X", $0) }.joined())
        let prefix = [23, 14, 6, 36, 16, 7, 19].map { hexadecimal[$0] }
        let suffix = [16, 1, 32, 12, 19, 27, 8, 5].map { hexadecimal[$0] }
        let mask: [UInt8] = [89, 39, 179, 150, 218, 82, 58, 252, 177, 52, 186, 123, 120, 64, 242, 133, 143, 161, 121, 179]
        let encoded = Data(zip(digest, mask).map { $0 ^ $1 }).base64EncodedString().filter { $0 != "/" && $0 != "+" && $0 != "=" }
        return ("zzc" + String(prefix) + encoded + String(suffix)).lowercased()
    }
    static func csrfToken(_ value: String) -> UInt32 {
        value.utf16.reduce(UInt32(5381)) { ($0 &* 33) &+ UInt32($1) } & 0x7fff_ffff
    }
}
