import SwiftUI

/// Surface colors follow their SwiftUI subtree. Audio renderers keep their
/// own multicolor palettes rather than inheriting a single interface accent.
struct AppPalette: Sendable {
    let background: Color
    let panel: Color
    let raised: Color
    let accent: Color
    let primary: Color
    let onPrimary: Color
    let highlight: Color
    let text: Color
    let secondary: Color
    let faint: Color
    let line: Color
    let hover: Color
    let colorScheme: ColorScheme

    static let bauhaus = AppPalette(
        background: hex(0xF1EBDD), panel: hex(0xE6DECE), raised: hex(0xD5CBB9),
        accent: hex(0x245CA8), primary: hex(0xB83228), onPrimary: hex(0xFFF8E9),
        highlight: hex(0xE4BC35), text: hex(0x202020), secondary: hex(0x696158),
        faint: hex(0x776D61), line: hex(0x202020).opacity(0.12),
        hover: hex(0x202020).opacity(0.045), colorScheme: .light)

    static let listeningRoom = AppPalette(
        background: hex(0x0E121A), panel: hex(0x181D27), raised: hex(0x232B39),
        accent: hex(0xAAC7EE), primary: hex(0xB83228), onPrimary: hex(0xFFF8E9),
        highlight: hex(0xE4BC35), text: hex(0xF1EBDD), secondary: hex(0xADB6C3),
        faint: hex(0x8C96A4), line: hex(0xF1EBDD).opacity(0.09),
        hover: hex(0xF1EBDD).opacity(0.045), colorScheme: .dark)

    private static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255,
              green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255)
    }
}

private struct AppPaletteKey: EnvironmentKey {
    static let defaultValue = AppPalette.bauhaus
}

extension EnvironmentValues {
    var appPalette: AppPalette {
        get { self[AppPaletteKey.self] }
        set { self[AppPaletteKey.self] = newValue }
    }
}

extension View {
    /// Scope both custom ink and native controls to a surface, including
    /// reusable queue, artwork, lyric and button views rendered within it.
    func appTheme(_ palette: AppPalette) -> some View {
        environment(\.appPalette, palette)
            .environment(\.colorScheme, palette.colorScheme)
            .tint(palette.accent)
    }
}

@MainActor private enum BrandArtwork {
    // Use the same packaged artwork as Finder and the Dock, without carrying
    // another full-resolution PNG in the runtime resources.
    static let icon: NSImage? = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        // A bare SwiftPM executable has no app-bundle icon resources.
        return NSImage(named: NSImage.applicationIconName)
    }()
}

struct AppBrandLogo: View {
    var body: some View {
        Group {
            if let icon = BrandArtwork.icon {
                Image(nsImage: icon).resizable().renderingMode(.original)
                    .interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "headphones").resizable().scaledToFit()
            }
        }.accessibilityLabel("AlpacaMusic 羊驼标志")
            .accessibilityIdentifier("app-brand-logo")
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.appPalette) private var palette
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium)).padding(.horizontal, 18).frame(height: 37)
            .foregroundStyle(palette.onPrimary).background(palette.primary.opacity(configuration.isPressed ? 0.8 : 1), in: .rect(cornerRadius: 7))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(ExperienceMotion.control, value: configuration.isPressed)
    }
}
struct QuietButtonStyle: ButtonStyle {
    @Environment(\.appPalette) private var palette
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11, weight: .medium)).padding(.horizontal, 14).frame(height: 34)
            .foregroundStyle(palette.accent.opacity(configuration.isPressed ? 0.6 : 0.85))
            .background(palette.accent.opacity(configuration.isPressed ? 0.12 : 0.035), in: .rect(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(palette.accent.opacity(0.16)))
            .animation(ExperienceMotion.control, value: configuration.isPressed)
    }
}
struct ToolButton: View {
    @Environment(\.appPalette) private var palette
    var symbol: String
    var label: String
    var active = false
    var action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 15, weight: .regular)).frame(width: 30, height: 30).contentShape(.rect) }
            .buttonStyle(.plain).foregroundStyle(active ? palette.accent : palette.secondary)
            .background(active ? palette.accent.opacity(0.055) : .clear, in: .rect(cornerRadius: 7))
            .help(label).accessibilityLabel(label)
            .animation(ExperienceMotion.control, value: active)
    }
}
struct Eyebrow: View {
    @Environment(\.appPalette) private var palette
    var text: String
    var body: some View { Text(text).font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(2).foregroundStyle(palette.secondary) }
}
struct ArtworkView: View {
    @Environment(\.appPalette) private var palette
    var track: Track?
    var radius: CGFloat = 8
    var highResolution = false
    @State private var loaded: NSImage?
    @State private var loadedKey: String?
    private var key: String { Artwork.key(for: track) + (highResolution ? ":full" : ":thumb") }
    var body: some View {
        ZStack {
            // Lightweight immediate paint: no image decoding in a SwiftUI body.
            LinearGradient(colors: [palette.raised, palette.panel], startPoint: .topLeading, endPoint: .bottomTrailing)
            if loadedKey == key, let loaded {
                Image(nsImage: loaded).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note").font(.system(size: 18, weight: .ultraLight)).foregroundStyle(palette.accent.opacity(0.25))
            }
        }
        .clipped().clipShape(.rect(cornerRadius: radius))
        .accessibilityLabel(track.map { "\($0.title) 封面" } ?? "专辑封面")
        .task(id: key) {
            let identity = key
            let image = highResolution ? await Artwork.loadImage(for: track) : await Artwork.loadThumbnail(for: track)
            guard !Task.isCancelled else { return }
            loaded = image; loadedKey = identity
        }
    }
}
struct SourceBadge: View {
    @Environment(\.appPalette) private var palette
    var source: MusicSource
    var isPreview = false
    var body: some View {
        Text(source.title + (isPreview ? " · 试听" : "")).font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.9).foregroundStyle(palette.secondary)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(palette.accent.opacity(0.12)))
    }
}
struct EmptyState: View {
    @Environment(\.appPalette) private var palette
    var symbol: String
    var title: String
    var message: String = ""
    var actionTitle: String = "导入音乐"
    var action: () -> Void
    var body: some View {
        VStack(spacing: 17) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(palette.secondary)
                .frame(width: 72, height: 72).background(palette.accent.opacity(0.045), in: .circle)
            Text(title).font(.system(size: 19, weight: .regular)).foregroundStyle(palette.text)
            if !message.isEmpty {
                Text(message).font(.system(size: 11)).foregroundStyle(palette.secondary).multilineTextAlignment(.center).lineSpacing(5)
            }
            Button(actionTitle, action: action).buttonStyle(QuietButtonStyle()).padding(.top, 5)
        }.frame(maxWidth: .infinity).padding(.vertical, 75)
    }
}
