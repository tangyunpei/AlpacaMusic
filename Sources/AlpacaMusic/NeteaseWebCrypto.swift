import CommonCrypto
import Foundation
import Security

/// Encodes the website's weapi request envelope. It grants no account or song rights.
enum NeteaseWebCrypto {
    struct Envelope: Sendable {
        let params: String
        let encSecKey: String
        var formData: Data {
            var form = URLComponents()
            form.queryItems = [URLQueryItem(name: "params", value: params), URLQueryItem(name: "encSecKey", value: encSecKey)]
            return Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        }
    }

    static func encrypt(_ payload: Data, secret: Data? = nil) throws -> Envelope {
        let secret = try secret ?? randomSecret()
        guard secret.count == 16 else { throw MusicError.message(L10n.string("网易云请求加密失败")) }
        let first = try aes(payload, key: Data("0CoJUm6Qyw8W8jud".utf8)).base64EncodedString()
        let params = try aes(Data(first.utf8), key: secret).base64EncodedString()
        // PKCS#1 DER representation of the website's public RSA key.
        let encoded = "MIGJAoGBAOC1CfYlnfhkLbw1ZikBR33yJnfsFStf9orOYVu3tyUVKzqxeodq6opap20uQXYp7E7jQfVhNfzPaVKAEE4DEuy9qSVXyThwEUr2ydBcT38MNoW3pGvuJVkyV1zOELQk2BPP5IddPoIEe5fd71J0HVRrjiidxpNbPs4EYtsKIrjnAgMBAAE="
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                       kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
                                       kSecAttrKeySizeInBits as String: 1024]
        guard let der = Data(base64Encoded: encoded),
              let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil) else {
            throw MusicError.message(L10n.string("网易云请求加密失败"))
        }
        var padded = Data(repeating: 0, count: 128 - secret.count)
        padded.append(contentsOf: secret.reversed())
        guard let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionRaw, padded as CFData, nil) as Data? else {
            throw MusicError.message(L10n.string("网易云请求加密失败"))
        }
        return Envelope(params: params, encSecKey: encrypted.map { String(format: "%02x", $0) }.joined())
    }

    private static func randomSecret() throws -> Data {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".utf8)
        var result = Data()
        while result.count < 16 {
            var value: UInt8 = 0
            guard SecRandomCopyBytes(kSecRandomDefault, 1, &value) == errSecSuccess else {
                throw MusicError.message(L10n.string("无法生成安全的网易云请求"))
            }
            if value < 248 { result.append(alphabet[Int(value) % alphabet.count]) }
        }
        return result
    }

    private static func aes(_ data: Data, key: Data) throws -> Data {
        let iv = Data("0102030405060708".utf8)
        let capacity = data.count + kCCBlockSizeAES128
        var output = Data(count: capacity), count = 0
        let status = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                input.baseAddress, data.count, destination.baseAddress, capacity, &count)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw MusicError.message(L10n.string("网易云请求加密失败")) }
        output.count = count
        return output
    }
}
