import CryptoKit
import Darwin
import Foundation

/// Input identity is tied to actual downloaded/local audio bytes, never to an
/// expiring URL. PCM can add an independent decoded-content fingerprint.
struct LyricAudioIdentity: Codable, Hashable, Sendable {
    var contentDigest: String
    var sampleRate: Double
    var duration: Double
    var pcmDigest: String? = nil

    var isValid: Bool {
        LyricAlignmentDigest.isSHA256(contentDigest) &&
        pcmDigest.map(LyricAlignmentDigest.isSHA256) != false &&
        sampleRate.isFinite && (8_000...384_000).contains(sampleRate) &&
        duration.isFinite && duration > 0 && duration <= 86_400
    }

    /// Hash finite, fixed-gain PCM without retaining it in the cache. Include
    /// sample rate/count so the same bytes at a different speed cannot collide.
    static func fingerprint(samples: [Float], sampleRate: Double) throws -> String {
        try Task.checkCancellation()
        guard sampleRate.isFinite, sampleRate > 0, !samples.isEmpty,
              samples.count <= 192_000 * 1_200 else { throw LyricAlignmentCacheError.invalidIdentity }
        var hash = SHA256()
        hash.update(data: LyricAlignmentDigest.canonical([String(sampleRate), String(samples.count)]))
        var bytes = Data(); bytes.reserveCapacity(16_384)
        for (index, sample) in samples.enumerated() {
            guard sample.isFinite else { throw LyricAlignmentCacheError.invalidIdentity }
            var bits = (sample == 0 ? Float(0) : sample).bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
            if bytes.count >= 16_384 {
                try Task.checkCancellation(); hash.update(data: bytes); bytes.removeAll(keepingCapacity: true)
            } else if index % 4_096 == 0 { try Task.checkCancellation() }
        }
        hash.update(data: bytes)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct LyricLocalAssetFingerprint: Codable, Hashable, Sendable {
    var fileSize: Int64
    var modificationSeconds: Int64
    var modificationNanoseconds: Int64
    var device: Int64
    var inode: UInt64

    static func make(url: URL) throws -> Self {
        try Task.checkCancellation()
        guard url.isFileURL else { throw LyricAlignmentCacheError.unsafeFile }
        let descriptor = open(url.path(percentEncoded: false), O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw LyricAlignmentCacheError.io(errno) }
        defer { close(descriptor) }
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_size >= 0 else { throw LyricAlignmentCacheError.unsafeFile }
        return .init(fileSize: value.st_size, modificationSeconds: Int64(value.st_mtimespec.tv_sec),
                     modificationNanoseconds: Int64(value.st_mtimespec.tv_nsec),
                     device: Int64(value.st_dev), inode: UInt64(value.st_ino))
    }
}

struct LyricAlignmentIdentity: Codable, Hashable, Sendable {
    var recordingDigest: String
    var lyricDigest: String
    var audio: LyricAudioIdentity
    var modelVersion: String
    var algorithmVersion: String

    var key: String {
        LyricAlignmentDigest.hash(LyricAlignmentDigest.canonical([
            "lyric-alignment-v1", recordingDigest, lyricDigest, audio.contentDigest,
            audio.pcmDigest ?? "", String(audio.sampleRate), String(audio.duration), modelVersion, algorithmVersion
        ]))
    }

    var isValid: Bool {
        LyricAlignmentDigest.isSHA256(recordingDigest) && LyricAlignmentDigest.isSHA256(lyricDigest) && audio.isValid &&
        !modelVersion.isEmpty && modelVersion.utf8.count <= 512 &&
        !algorithmVersion.isEmpty && algorithmVersion.utf8.count <= 128
    }

    static func make(track: Track, document: LyricDocument, audio: LyricAudioIdentity,
                     localAsset: LyricLocalAssetFingerprint? = nil, modelVersion: String,
                     algorithmVersion: String, recordingVersion: String = "") throws -> Self {
        try Task.checkCancellation()
        guard audio.isValid, track.duration.isFinite, (0...86_400).contains(track.duration),
              [track.id, track.sourceID ?? "", track.title, track.artist, track.album, track.format ?? ""].allSatisfy({ $0.utf8.count <= 32_768 }),
              recordingVersion.utf8.count <= 1_024,
              LyricAlignmentQualityGate.validDocument(document, audioDuration: audio.duration) else {
            throw LyricAlignmentCacheError.invalidIdentity
        }
        // Keep complete version labels in title/album (Live, remaster, cover,
        // etc.). They are deliberately not normalized into a title-only key.
        var parts = [track.source.rawValue, stableResource(track.id), stableResource(track.sourceID ?? ""),
                     track.appleMusicResourceKind?.rawValue ?? "", track.title, track.artist, track.album,
                     String(track.duration), track.format ?? "", recordingVersion]
        if let range = track.sodaPlayback {
            parts += [String(range.fullDuration), String(range.start), String(range.duration), String(range.isPreview)]
        }
        if let localAsset {
            parts += [String(localAsset.fileSize), String(localAsset.modificationSeconds),
                      String(localAsset.modificationNanoseconds), String(localAsset.device), String(localAsset.inode)]
        }
        let identity = Self(recordingDigest: LyricAlignmentDigest.hash(LyricAlignmentDigest.canonical(parts)),
                            lyricDigest: try LyricAlignmentDigest.lyrics(document), audio: audio,
                            modelVersion: modelVersion, algorithmVersion: algorithmVersion)
        guard identity.isValid else { throw LyricAlignmentCacheError.invalidIdentity }
        return identity
    }

    private static func stableResource(_ value: String) -> String {
        // A resource may itself be a URL. Its query can contain expiring tokens;
        // use the resource path while actual media bytes disambiguate recordings.
        guard var components = URLComponents(string: value),
              ["http", "https"].contains(components.scheme?.lowercased() ?? "") else { return value }
        components.user = nil; components.password = nil; components.query = nil; components.fragment = nil
        return components.string ?? ""
    }
}

struct LyricVocalRegion: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
}

/// Confidence refers to audio-derived anchors, not authoritative provider time.
/// Multi-character ASR runs remain grouped and disclose their estimated units.
struct LyricAlignmentQuality: Codable, Equatable, Sendable {
    var coverage: Double
    var meanConfidence: Double
    var maximumAnchorDrift: Double
    var vocalOverlap: Double
    var matchedUnitCount: Int
    var estimatedUnitCount: Int
}

struct LyricAlignedLine: Codable, Equatable, Sendable {
    var lineID: Int
    var words: [LyricWord]
    var quality: LyricAlignmentQuality
}

struct LyricAlignmentResult: Codable, Equatable, Sendable {
    var lines: [LyricAlignedLine]
    var vocalRegions: [LyricVocalRegion]
    var engineVersion: String
    var localeIdentifier: String
}

enum LyricAlignmentQualityGate {
    static let minimumCoverage = 0.8
    static let minimumConfidence = 0.5
    static let minimumVocalOverlap = 0.65
    static let maximumAnchorDrift = 1.5
    static let maximumWords = 100_000

    static func acceptedResult(_ result: LyricAlignmentResult, for document: LyricDocument,
                               audioDuration: Double) -> LyricAlignmentResult? {
        guard validDocument(document, audioDuration: audioDuration),
              !result.engineVersion.isEmpty, result.engineVersion.utf8.count <= 512,
              !result.localeIdentifier.isEmpty, result.localeIdentifier.utf8.count <= 128,
              result.lines.count <= document.lines.count,
              result.vocalRegions.count <= 10_000,
              validRegions(result.vocalRegions, audioDuration: audioDuration) else { return nil }
        let accepted = acceptedLines(result.lines, for: document, audioDuration: audioDuration,
                                     vocalRegions: result.vocalRegions)
        guard !accepted.isEmpty else { return nil }
        var filtered = result; filtered.lines = accepted
        return filtered
    }

    static func acceptedLines(_ proposed: [LyricAlignedLine], for document: LyricDocument,
                              audioDuration: Double, vocalRegions: [LyricVocalRegion]? = nil) -> [LyricAlignedLine] {
        guard validDocument(document, audioDuration: audioDuration), proposed.count <= document.lines.count else { return [] }
        let originals = Dictionary(uniqueKeysWithValues: document.lines.enumerated().map { ($0.element.id, $0.offset) })
        let duplicateIDs = Set(Dictionary(grouping: proposed, by: \.lineID).filter { $0.value.count > 1 }.map(\.key))
        var seen = Set<Int>(), count = 0
        return proposed.compactMap { aligned -> (Int, LyricAlignedLine)? in
            guard !duplicateIDs.contains(aligned.lineID), seen.insert(aligned.lineID).inserted,
                  let index = originals[aligned.lineID] else { return nil }
            let line = document.lines[index]
            // Layer one always wins. Audio-derived candidates never replace a
            // whole line that already has any valid provider word boundaries.
            guard line.words.isEmpty, let start = line.start else { return nil }
            let end = min(line.end ?? audioDuration,
                          index + 1 < document.lines.count ? document.lines[index + 1].start ?? audioDuration : audioDuration)
            let lexicalCount = LyricAudioAnchorMatcher.lexicalUnitCount(in: line.text)
            guard end > start, !aligned.words.isEmpty, lexicalCount > 0,
                  aligned.quality.matchedUnitCount <= lexicalCount, aligned.quality.estimatedUnitCount <= lexicalCount,
                  Double(aligned.quality.matchedUnitCount) / Double(lexicalCount) >= minimumCoverage,
                  (aligned.words.first?.start ?? .infinity) <= start + maximumAnchorDrift,
                  aligned.words.map(\.text).joined() == line.text,
                  validQuality(aligned.quality), aligned.words.count <= 10_000 else { return nil }
            count += aligned.words.count
            guard count <= maximumWords else { return nil }
            let originalCharacters = Array(line.text)
            var previousEnd = start, characterOffset = 0
            for (wordIndex, word) in aligned.words.enumerated() {
                let characters = Array(word.text), upper = characterOffset + word.text.count
                guard upper <= originalCharacters.count,
                      Array(originalCharacters[characterOffset..<upper]) == characters else { return nil }
                guard word.id == wordIndex, !word.text.isEmpty, word.text.utf8.count <= 32_768,
                      word.start.isFinite, let wordEnd = word.end, wordEnd.isFinite,
                      word.start >= start, word.start >= previousEnd, wordEnd > word.start,
                      wordEnd <= end, wordEnd <= audioDuration else { return nil }
                previousEnd = wordEnd; characterOffset = upper
            }
            guard characterOffset == originalCharacters.count else { return nil }
            if let vocalRegions {
                guard validRegions(vocalRegions, audioDuration: audioDuration),
                      measuredVocalOverlap(aligned.words, regions: vocalRegions) >= minimumVocalOverlap else { return nil }
            }
            return (index, aligned)
        }.sorted { $0.0 < $1.0 }.map(\.1)
    }

    static func validQuality(_ quality: LyricAlignmentQuality) -> Bool {
        quality.coverage.isFinite && (minimumCoverage...1).contains(quality.coverage) &&
        quality.meanConfidence.isFinite && (minimumConfidence...1).contains(quality.meanConfidence) &&
        quality.maximumAnchorDrift.isFinite && (0...maximumAnchorDrift).contains(quality.maximumAnchorDrift) &&
        quality.vocalOverlap.isFinite && (minimumVocalOverlap...1).contains(quality.vocalOverlap) &&
        quality.matchedUnitCount > 0 && quality.matchedUnitCount <= maximumWords &&
        quality.estimatedUnitCount >= 0 && quality.estimatedUnitCount <= maximumWords
    }

    static func validDocument(_ document: LyricDocument, audioDuration: Double) -> Bool {
        guard audioDuration.isFinite, audioDuration > 0, audioDuration <= 86_400,
              document.timing != .plain, !document.isInstrumental, !document.lines.isEmpty,
              document.lines.count <= LyricsParser.maximumLines,
              Set(document.lines.map(\.id)).count == document.lines.count else { return false }
        var previous = -Double.infinity, bytes = 0, words = 0
        for line in document.lines {
            guard let start = line.start, start.isFinite, start >= 0, start >= previous,
                  start < audioDuration, !line.text.isEmpty, line.text.utf8.count <= 32_768,
                  line.end.map({ $0.isFinite && $0 > start && $0 <= 86_400 }) ?? true else { return false }
            bytes += line.text.utf8.count + (line.translation?.utf8.count ?? 0)
            words += line.words.count
            guard bytes <= LyricsParser.maximumBytes, words <= maximumWords else { return false }
            var wordStart = start
            for word in line.words {
                bytes += word.text.utf8.count
                guard word.start.isFinite, word.start >= wordStart, word.start >= start,
                      word.text.utf8.count <= 32_768, bytes <= LyricsParser.maximumBytes,
                      word.end.map({ $0.isFinite && $0 > word.start && $0 <= (line.end ?? 86_400) }) ?? true else { return false }
                wordStart = word.start
            }
            previous = start
        }
        return true
    }

    private static func validRegions(_ regions: [LyricVocalRegion], audioDuration: Double) -> Bool {
        guard !regions.isEmpty, regions.count <= 10_000 else { return false }
        var end = 0.0
        for region in regions {
            guard region.start.isFinite, region.end.isFinite, region.start >= end,
                  region.end > region.start, region.end <= audioDuration else { return false }
            end = region.end
        }
        return true
    }

    private static func measuredVocalOverlap(_ words: [LyricWord], regions: [LyricVocalRegion]) -> Double {
        var voiced = 0.0, total = 0.0
        for word in words where word.text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }) {
            guard let end = word.end else { continue }
            total += end - word.start
            for region in regions where region.end > word.start && region.start < end {
                voiced += max(0, min(region.end, end) - max(region.start, word.start))
            }
        }
        return total > 0 ? min(1, voiced / total) : 0
    }
}

enum LyricAlignmentCacheError: Error, Sendable {
    case invalidIdentity, invalidDocument, unsafeFile, oversized, io(Int32)
}

enum LyricAlignmentDigest {
    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func canonical(_ values: [String]) -> Data {
        values.reduce(into: Data()) { data, value in
            data.append(contentsOf: String(value.utf8.count).utf8); data.append(58); data.append(contentsOf: value.utf8)
        }
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func lyrics(_ document: LyricDocument) throws -> String {
        try Task.checkCancellation()
        guard document.lines.count <= LyricsParser.maximumLines else { throw LyricAlignmentCacheError.invalidDocument }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        // Text, exact cue boundaries, IDs, translations, and existing words all
        // participate. Display-language source descriptions deliberately do not.
        let data = try encoder.encode(document.lines)
        guard data.count <= 8 * 1024 * 1024 else { throw LyricAlignmentCacheError.oversized }
        return hash(data)
    }
}

/// Cache only derived timing ranges and metrics, never raw audio, tokens,
/// cookies, URLs, or copied lyric text. Every load reattaches original text and
/// revalidates quality, cue windows, provider precedence, and recording identity.
actor LyricAlignmentCache {
    static let maximumRecords = 64
    static let maximumRecordBytes = 1024 * 1024
    static let maximumTotalBytes = 16 * 1024 * 1024
    private let directory: URL

    init(directory: URL) { self.directory = directory.appending(path: "lyric-alignments", directoryHint: .isDirectory) }

    private struct TimedRange: Codable {
        var lower: Int
        var upper: Int
        var start: Double
        var end: Double
    }
    private struct CachedLine: Codable {
        var lineID: Int
        var ranges: [TimedRange]
        var quality: LyricAlignmentQuality
    }
    private struct Record: Codable {
        var version = 1
        var key: String
        var identity: LyricAlignmentIdentity
        var savedAt: Date
        var lines: [CachedLine]
        var vocalRegions: [LyricVocalRegion]
        var engineVersion: String
        var localeIdentifier: String
    }

    func cached(for identity: LyricAlignmentIdentity, document: LyricDocument) throws -> LyricAlignmentResult? {
        try Task.checkCancellation()
        guard identity.isValid, LyricAlignmentQualityGate.validDocument(document, audioDuration: identity.audio.duration) else { return nil }
        guard try LyricAlignmentDigest.lyrics(document) == identity.lyricDigest else { return nil }
        let descriptor: Int32
        do { descriptor = try openDirectory(create: false) }
        catch is CancellationError { throw CancellationError() }
        catch { return nil }
        defer { close(descriptor) }
        let data: Data
        do { data = try read(name: identity.key + ".json", directoryDescriptor: descriptor) }
        catch is CancellationError { throw CancellationError() }
        catch { return nil }
        try Task.checkCancellation()
        guard let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == 1, record.key == identity.key, record.identity == identity,
              record.engineVersion == identity.modelVersion,
              record.lines.count <= document.lines.count,
              record.savedAt.timeIntervalSince1970.isFinite else { return nil }
        let originals = Dictionary(uniqueKeysWithValues: document.lines.map { ($0.id, $0) })
        var proposed: [LyricAlignedLine] = []
        for cached in record.lines {
            try Task.checkCancellation()
            guard let original = originals[cached.lineID], cached.ranges.count <= 10_000 else { return nil }
            let characters = Array(original.text)
            var lower = 0, words: [LyricWord] = []
            for (index, range) in cached.ranges.enumerated() {
                guard range.lower == lower, range.upper > range.lower, range.upper <= characters.count else { return nil }
                words.append(.init(id: index, text: String(characters[range.lower..<range.upper]), start: range.start, end: range.end))
                lower = range.upper
            }
            guard lower == characters.count else { return nil }
            proposed.append(.init(lineID: cached.lineID, words: words, quality: cached.quality))
        }
        return LyricAlignmentQualityGate.acceptedResult(.init(lines: proposed, vocalRegions: record.vocalRegions,
            engineVersion: record.engineVersion, localeIdentifier: record.localeIdentifier), for: document, audioDuration: identity.audio.duration)
    }

    @discardableResult
    func store(_ result: LyricAlignmentResult, for identity: LyricAlignmentIdentity,
               document: LyricDocument, now: Date = Date()) throws -> Bool {
        try Task.checkCancellation()
        guard identity.isValid, result.engineVersion == identity.modelVersion else { return false }
        guard try LyricAlignmentDigest.lyrics(document) == identity.lyricDigest,
              let accepted = LyricAlignmentQualityGate.acceptedResult(result, for: document, audioDuration: identity.audio.duration) else { return false }
        let lines = accepted.lines.map { line in
            var offset = 0
            let ranges = line.words.map { word in
                let lower = offset; offset += word.text.count
                return TimedRange(lower: lower, upper: offset, start: word.start, end: word.end!)
            }
            return CachedLine(lineID: line.lineID, ranges: ranges, quality: line.quality)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let record = Record(key: identity.key, identity: identity, savedAt: now, lines: lines,
                            vocalRegions: accepted.vocalRegions, engineVersion: accepted.engineVersion, localeIdentifier: accepted.localeIdentifier)
        let data = try encoder.encode(record)
        guard data.count <= Self.maximumRecordBytes else { throw LyricAlignmentCacheError.oversized }
        let descriptor = try openDirectory(create: true)
        defer { close(descriptor) }
        try atomicWrite(data, name: identity.key + ".json", directoryDescriptor: descriptor)
        try prune(directoryDescriptor: descriptor)
        return true
    }

    private func openDirectory(create: Bool) throws -> Int32 {
        guard directory.isFileURL else { throw LyricAlignmentCacheError.unsafeFile }
        // Traverse with descriptors so no component, including the final cache
        // directory, can redirect reads/writes through a symbolic link.
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw LyricAlignmentCacheError.io(errno) }
        do {
            for component in directory.pathComponents.dropFirst() {
                try Task.checkCancellation()
                guard component != ".", component != "..", !component.contains("/") else { throw LyricAlignmentCacheError.unsafeFile }
                var next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                if next < 0, errno == ENOENT, create {
                    if mkdirat(descriptor, component, 0o700) != 0, errno != EEXIST { throw LyricAlignmentCacheError.io(errno) }
                    next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard next >= 0 else { throw LyricAlignmentCacheError.io(errno) }
                close(descriptor); descriptor = next
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }

    private func read(name: String, directoryDescriptor: Int32) throws -> Data {
        try Task.checkCancellation()
        let descriptor = openat(directoryDescriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw LyricAlignmentCacheError.io(errno) }
        defer { close(descriptor) }
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG else { throw LyricAlignmentCacheError.unsafeFile }
        guard value.st_size > 0, value.st_size <= Self.maximumRecordBytes else { throw LyricAlignmentCacheError.oversized }
        var result = Data(), bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            try Task.checkCancellation()
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress!, buffer.count)
            }
            if count < 0 { if errno == EINTR { continue }; throw LyricAlignmentCacheError.io(errno) }
            if count == 0 { break }
            guard result.count + count <= Self.maximumRecordBytes else { throw LyricAlignmentCacheError.oversized }
            result.append(contentsOf: bytes.prefix(count))
        }
        return result
    }

    private func atomicWrite(_ data: Data, name: String, directoryDescriptor: Int32) throws {
        try Task.checkCancellation()
        var existing = stat()
        if fstatat(directoryDescriptor, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG else { throw LyricAlignmentCacheError.unsafeFile }
        } else if errno != ENOENT { throw LyricAlignmentCacheError.io(errno) }
        let temporary = "." + UUID().uuidString + ".tmp"
        let descriptor = openat(directoryDescriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw LyricAlignmentCacheError.io(errno) }
        defer { close(descriptor); unlinkat(directoryDescriptor, temporary, 0) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try Task.checkCancellation()
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw LyricAlignmentCacheError.io(errno) }
                guard count > 0 else { throw LyricAlignmentCacheError.io(EIO) }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw LyricAlignmentCacheError.io(errno) }
        try Task.checkCancellation()
        guard renameat(directoryDescriptor, temporary, directoryDescriptor, name) == 0 else { throw LyricAlignmentCacheError.io(errno) }
    }

    private func prune(directoryDescriptor: Int32) throws {
        try Task.checkCancellation()
        // Enumeration, metadata checks, and removals all stay on the pinned
        // directory descriptor, including if its path is renamed concurrently.
        let copy = dup(directoryDescriptor)
        guard copy >= 0 else { throw LyricAlignmentCacheError.io(errno) }
        guard let stream = fdopendir(copy) else { close(copy); throw LyricAlignmentCacheError.io(errno) }
        defer { closedir(stream) }
        var records: [(name: String, seconds: Int64, nanoseconds: Int64, bytes: Int)] = []
        while let entry = readdir(stream) {
            try Task.checkCancellation()
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            guard name.hasSuffix(".json"), LyricAlignmentDigest.isSHA256(String(name.dropLast(5))) else { continue }
            var value = stat()
            guard fstatat(directoryDescriptor, name, &value, AT_SYMLINK_NOFOLLOW) == 0,
                  value.st_mode & S_IFMT == S_IFREG, value.st_size >= 0 else { continue }
            records.append((name, Int64(value.st_mtimespec.tv_sec), Int64(value.st_mtimespec.tv_nsec), Int(value.st_size)))
        }
        records.sort { a, b in
            if a.seconds != b.seconds { return a.seconds > b.seconds }
            if a.nanoseconds != b.nanoseconds { return a.nanoseconds > b.nanoseconds }
            return a.name < b.name
        }
        var kept = 0, bytes = 0
        for record in records {
            try Task.checkCancellation()
            if record.bytes <= Self.maximumRecordBytes, kept < Self.maximumRecords,
               bytes + record.bytes <= Self.maximumTotalBytes { kept += 1; bytes += record.bytes }
            else if unlinkat(directoryDescriptor, record.name, 0) != 0, errno != ENOENT { throw LyricAlignmentCacheError.io(errno) }
        }
    }
}
