// QQ QRC interoperability only; this is not a security cipher.
// Swift adaptation of qrc-decoder (MIT), Copyright (c) [2025] [apoint123].
// Original LyricDecoder (MIT), Copyright (c) 2019 SuJiKiNen.
// Full notices: Resources/Licenses/QRCDecoder-MIT.txt.
import Compression
import Foundation

/// The QQ protocol uses a proprietary DES-like transformation. This narrow
/// decoder intentionally avoids deprecated DES APIs and general encryption use.
enum QQWordLyricCodec {
    static func decode(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= LyricsParser.maximumBytes * 2 else { return nil }
        if isLyricText(value) { return value }
        // Some protocol versions use Base64 even when crypt=0 is requested.
        if let data = Data(base64Encoded: value), data.count <= LyricsParser.maximumBytes,
           let text = String(data: data, encoding: .utf8), isLyricText(text) { return text }
        let encoded = Array(value.utf8)
        guard encoded.count % 16 == 0 else { return nil }
        var bytes: [UInt8] = []; bytes.reserveCapacity(encoded.count / 2)
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: byte - 48
            case 65...70: byte - 55
            case 97...102: byte - 87
            default: nil
            }
        }
        for index in stride(from: 0, to: encoded.count, by: 2) {
            guard let high = nibble(encoded[index]), let low = nibble(encoded[index + 1]) else { return nil }
            bytes.append((high << 4) | low)
        }
        for index in stride(from: 0, to: bytes.count, by: 8) {
            if index % 2048 == 0, Task.isCancelled { return nil }
            var block: UInt64 = 0
            for byte in bytes[index..<index + 8] { block = (block << 8) | UInt64(byte) }
            for schedule in schedules { block = transform(block, schedule: schedule) }
            for offset in 0..<8 { bytes[index + offset] = UInt8(truncatingIfNeeded: block >> (56 - offset * 8)) }
        }
        guard let data = inflate(bytes), let text = String(data: data, encoding: .utf8), isLyricText(text) else { return nil }
        return text.replacingOccurrences(of: "\u{FEFF}", with: "")
    }

    private static func isLyricText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{FEFF}", with: "")
        return trimmed.hasPrefix("[") || (trimmed.hasPrefix("<") && trimmed.contains("LyricContent="))
    }

    private static func inflate(_ source: [UInt8]) -> Data? {
        guard source.count >= 6, source[0] & 15 == 8, source[0] >> 4 <= 7,
              (UInt16(source[0]) * 256 + UInt16(source[1])) % 31 == 0,
              source[1] & 32 == 0 else { return nil }
        // Apple COMPRESSION_ZLIB consumes raw DEFLATE (RFC 1951); strip the
        // RFC 1950 header and verify Adler32 ourselves, including zero padding.
        var result = [UInt8](repeating: 0, count: LyricsParser.maximumBytes + 1)
        let count = source.withUnsafeBufferPointer { input in
            result.withUnsafeMutableBufferPointer { output in
                compression_decode_buffer(output.baseAddress!, output.count, input.baseAddress! + 2, input.count - 2, nil, COMPRESSION_ZLIB)
            }
        }
        guard count > 0, count <= LyricsParser.maximumBytes else { return nil }
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in result[..<count] { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        let checksum = b << 16 | a
        for padding in 0...min(7, source.count - 6) {
            let footer = source.count - padding - 4
            if padding > 0, !source[(footer + 4)...].allSatisfy({ $0 == 0 }) { continue }
            let actual = source[footer..<footer + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            if actual == checksum { return Data(result[..<count]) }
        }
        return nil
    }

    private static let schedules: [[UInt64]] = [
        keySchedule(Array("!@#)(NHL".utf8), decrypt: true),
        keySchedule(Array("123ZXC!@".utf8), decrypt: false),
        keySchedule(Array("!@#)(*$%".utf8), decrypt: true)
    ]

    private static func keySchedule(_ bytes: [UInt8], decrypt: Bool) -> [UInt64] {
        var reordered: UInt64 = 0
        for index in [3, 2, 1, 0, 7, 6, 5, 4] { reordered = (reordered << 8) | UInt64(bytes[index]) }
        func half(_ table: [Int]) -> UInt64 { table.reduce(0) { ($0 << 1) | ((reordered >> (63 - $1)) & 1) } }
        var c = half(keyC), d = half(keyD), result: [UInt64] = []
        for amount in shifts {
            c = ((c << amount) | (c >> (28 - amount))) & 0x0fffffff
            d = ((d << amount) | (d >> (28 - amount))) & 0x0fffffff
            var subkey: UInt64 = 0
            for position in compression {
                // QRC's D-half indexing differs by one from standard DES.
                let bit = position < 28 ? (c >> (27 - position)) & 1 : (position < 55 ? (d >> (54 - position)) & 1 : 0)
                subkey = (subkey << 1) | bit
            }
            result.append(subkey)
        }
        return decrypt ? Array(result.reversed()) : result
    }

    private static func permute(_ value: UInt64, width: Int, table: [Int]) -> UInt64 {
        table.reduce(0) { ($0 << 1) | ((value >> (width - $1)) & 1) }
    }
    private static func byteLookup(_ value: UInt64, count: Int, tables: [[UInt64]]) -> UInt64 {
        var result: UInt64 = 0
        for position in 0..<count { result |= tables[position][Int((value >> ((count - position - 1) * 8)) & 255)] }
        return result
    }
    private static func transform(_ block: UInt64, schedule: [UInt64]) -> UInt64 {
        let initial = byteLookup(block, count: 8, tables: inputTables)
        var left = UInt32(truncatingIfNeeded: initial >> 32), right = UInt32(truncatingIfNeeded: initial)
        for index in 0..<15 { (left, right) = (right, left ^ feistel(right, key: schedule[index])) }
        left ^= feistel(right, key: schedule[15])
        return byteLookup(UInt64(left) << 32 | UInt64(right), count: 8, tables: outputTables)
    }
    private static func feistel(_ value: UInt32, key: UInt64) -> UInt32 {
        let expanded = byteLookup(UInt64(value), count: 4, tables: expansionTables) ^ key
        var result: UInt32 = 0
        for index in 0..<8 { result |= substitutionTables[index][Int((expanded >> (42 - index * 6)) & 63)] }
        return result
    }
    private static let inputTables: [[UInt64]] = lookupTables(width: 64, table: initial)
    private static let outputTables: [[UInt64]] = lookupTables(width: 64, table: inverse)
    private static let expansionTables: [[UInt64]] = lookupTables(width: 32, table: expansion)
    private static func lookupTables(width: Int, table: [Int]) -> [[UInt64]] {
        (0..<width / 8).map { position in
            (0..<256).map { permute(UInt64($0) << (width - (position + 1) * 8), width: width, table: table) }
        }
    }
    private static let substitutionTables: [[UInt32]] = (0..<8).map { index in
        (0..<64).map { value in
            let lookup = (value & 32) | ((value & 31) >> 1) | ((value & 1) << 4)
            return UInt32(permute(UInt64(sboxes[index][lookup]) << (28 - index * 4), width: 32, table: pbox))
        }
    }
    private static let initial: [Int] = [34, 42, 50, 58, 2, 10, 18, 26, 36, 44, 52, 60, 4, 12, 20, 28, 38, 46, 54, 62, 6, 14, 22, 30, 40, 48, 56, 64, 8, 16, 24, 32, 33, 41, 49, 57, 1, 9, 17, 25, 35, 43, 51, 59, 3, 11, 19, 27, 37, 45, 53, 61, 5, 13, 21, 29, 39, 47, 55, 63, 7, 15, 23, 31]
    private static let inverse: [Int] = [37, 5, 45, 13, 53, 21, 61, 29, 38, 6, 46, 14, 54, 22, 62, 30, 39, 7, 47, 15, 55, 23, 63, 31, 40, 8, 48, 16, 56, 24, 64, 32, 33, 1, 41, 9, 49, 17, 57, 25, 34, 2, 42, 10, 50, 18, 58, 26, 35, 3, 43, 11, 51, 19, 59, 27, 36, 4, 44, 12, 52, 20, 60, 28]
    private static let pbox: [Int] = [16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10, 2, 8, 24, 14, 32, 27, 3, 9, 19, 13, 30, 6, 22, 11, 4, 25]
    private static let expansion: [Int] = [32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9, 8, 9, 10, 11, 12, 13, 12, 13, 14, 15, 16, 17, 16, 17, 18, 19, 20, 21, 20, 21, 22, 23, 24, 25, 24, 25, 26, 27, 28, 29, 28, 29, 30, 31, 32, 1]
    private static let shifts: [Int] = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]
    private static let keyC: [Int] = [56, 48, 40, 32, 24, 16, 8, 0, 57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35]
    private static let keyD: [Int] = [62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 60, 52, 44, 36, 28, 20, 12, 4, 27, 19, 11, 3]
    private static let compression: [Int] = [13, 16, 10, 23, 0, 4, 2, 27, 14, 5, 20, 9, 22, 18, 11, 3, 25, 7, 15, 6, 26, 19, 12, 1, 40, 51, 30, 36, 46, 54, 29, 39, 50, 44, 32, 47, 43, 48, 38, 55, 33, 52, 45, 41, 49, 35, 28, 31]
    private static let sboxes: [[Int]] = [
        [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8, 4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0, 15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13],
        [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7, 15, 2, 8, 15, 12, 0, 1, 10, 6, 9, 11, 5, 0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15, 13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9],
        [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1, 13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7, 1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12],
        [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9, 10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4, 3, 15, 0, 6, 10, 10, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14],
        [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6, 4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14, 11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3],
        [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8, 9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6, 4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13],
        [4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, 13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6, 1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2, 6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12],
        [13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, 1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2, 7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8, 2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11],
    ]
}
