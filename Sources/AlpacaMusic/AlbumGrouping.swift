import Foundation

/// Combines provider-owned album collections with metadata-only groups for older
/// imports. Inferred groups are a view of tracks and never become saved playlists.
enum AlbumGrouping {
    private struct Key: Hashable {
        let source: MusicSource
        let title: String
        let artist: String
    }

    static func importedID(source: MusicSource, remoteID: String) -> String {
        identity(prefix: "album:remote:", components: [source.rawValue, remoteID])
    }

    static func collections(stored: [MusicAlbum], tracks: [Track]) -> [MusicAlbum] {
        var result = stored
        var represented = Set<String>()
        var explicitKeys = Set<Key>()
        for album in stored {
            represented.formUnion(album.trackIDs)
            explicitKeys.insert(key(source: album.source, title: album.name, artist: album.artist))
        }
        var indices: [Key: Int] = [:]
        for track in tracks where !represented.contains(track.id) {
            let title = displayText(track.album)
            guard !title.isEmpty else { continue }
            let group = key(source: track.source, title: title, artist: track.artist)
            // A reimport's exact provider membership wins over older tracks with
            // matching metadata. Those omitted songs remain in All Songs.
            guard !explicitKeys.contains(group) else { continue }
            if let index = indices[group] {
                result[index].trackIDs.append(track.id)
                if result[index].artworkURL == nil { result[index].artworkURL = track.artworkURL }
            } else {
                indices[group] = result.count
                result.append(MusicAlbum(
                    id: identity(prefix: "album:inferred:", components: [group.source.rawValue, group.title, group.artist]),
                    name: title, artist: displayText(track.artist), source: track.source,
                    trackIDs: [track.id], artworkURL: track.artworkURL))
            }
        }
        return result
    }

    private static func key(source: MusicSource, title: String, artist: String) -> Key {
        Key(source: source, title: normalized(title), artist: normalized(artist))
    }

    private static func displayText(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func normalized(_ value: String) -> String {
        displayText(value).folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func identity(prefix: String, components: [String]) -> String {
        // Length-prefixed UTF-8 components avoid separator ambiguity and retain
        // stable identities between launches without Swift's randomized Hasher.
        let bytes = components.map { "\($0.utf8.count):\($0)" }.joined()
        return prefix + Data(bytes.utf8).base64EncodedString()
    }
}
