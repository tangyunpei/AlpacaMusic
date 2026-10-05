import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Work runs on this actor instead of the UI actor. Security scope remains open
/// for directory enumeration, asynchronous metadata loading, and bookmark creation.
actor MetadataImporter {
    static let fileExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "flac", "ogg", "opus", "wav", "wave", "aif", "aiff", "caf"]
    static var supportedContentTypes: [UTType] { AVURLAsset.audiovisualContentTypes.filter { $0.conforms(to: .audio) } }
    private let limit = 5000

    func importURLs(_ urls: [URL]) async -> ImportResult {
        var result = ImportResult()
        var visited = Set<String>()
        for selection in urls.prefix(limit) {
            if Task.isCancelled { break }
            guard selection.isFileURL else { result.errors.append("只能导入本地音频文件"); continue }
            let accessing = selection.startAccessingSecurityScopedResource()
            defer { if accessing { selection.stopAccessingSecurityScopedResource() } }
            do {
                let values = try selection.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
                let files: [URL]
                if values.isDirectory == true {
                    var selected: [URL] = []
                    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
                    let iterator = FileManager.default.enumerator(at: selection, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
                    while let file = iterator?.nextObject() as? URL {
                        if Task.isCancelled { break }
                        guard selected.count + result.tracks.count < limit else { result.errors.append("单次最多导入 5000 首，请分批添加剩余文件"); break }
                        let details = try? file.resourceValues(forKeys: Set(keys))
                        if details?.isSymbolicLink == true { iterator?.skipDescendants(); continue }
                        if iterator?.level ?? 0 > 32 { iterator?.skipDescendants(); continue }
                        if details?.isRegularFile == true && Self.fileExtensions.contains(file.pathExtension.lowercased()) { selected.append(file) }
                    }
                    files = selected
                } else if values.isRegularFile == true || values.isSymbolicLink == true {
                    files = [selection]
                } else { files = [] }
                for file in files {
                    if Task.isCancelled { break }
                    guard result.tracks.count < limit else { break }
                    let canonical = file.resolvingSymlinksInPath().standardizedFileURL
                    guard visited.insert(canonical.path()).inserted else { continue }
                    guard Self.fileExtensions.contains(canonical.pathExtension.lowercased()) else {
                        result.errors.append("\(file.lastPathComponent)：不支持此文件格式"); continue
                    }
                    do { result.tracks.append(try await Self.readMetadata(canonical)) }
                    catch is CancellationError { break }
                    catch { result.errors.append("\(file.lastPathComponent)：\(error.localizedDescription)") }
                }
            } catch { result.errors.append("\(selection.lastPathComponent)：文件不存在或无法读取") }
        }
        return result
    }

    static func readMetadata(_ url: URL) async throws -> Track {
        let asset = AVURLAsset(url: url)
        let (playable, duration, items) = try await asset.load(.isPlayable, .duration, .commonMetadata)
        guard playable else { throw MusicError.message("系统无法解码此音频格式，请转换为 AAC、ALAC、FLAC 或 WAV") }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw MusicError.message("文件中没有可播放的音轨") }
        try Task.checkCancellation()
        let title = await string(.commonIdentifierTitle, items: items) ?? url.deletingPathExtension().lastPathComponent
        let artist = await string(.commonIdentifierArtist, items: items) ?? "未知艺术家"
        let album = await string(.commonIdentifierAlbumName, items: items) ?? "本地音乐"
        var artwork: Data?
        for item in items where item.identifier == .commonIdentifierArtwork {
            if let data = try? await item.load(.dataValue), data.count <= 8 * 1024 * 1024 {
                artwork = thumbnail(data)
                if artwork != nil { break }
            }
        }
        let bookmark: Data
        do { bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: [.nameKey], relativeTo: nil) }
        catch { throw MusicError.message("无法保存文件访问授权，请重新选择文件") }
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return Track(id: "local:\(digest)", title: String(title.prefix(500)), artist: String(artist.prefix(500)), album: String(album.prefix(500)), duration: duration.seconds.isFinite ? max(0, duration.seconds) : 0, source: .local, url: url, bookmark: bookmark, artworkData: artwork, format: url.pathExtension.uppercased())
    }

    private static func string(_ identifier: AVMetadataIdentifier, items: [AVMetadataItem]) async -> String? {
        for item in items where item.identifier == identifier {
            if let value = try? await item.load(.stringValue), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
        }
        return nil
    }

    private static func thumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 384, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= 1024 * 1024 else { return nil }
        return output as Data
    }
}
