import AppKit
import Observation

/// What the menu bar playback buttons show and allow.
struct MenuBarTransportState: Equatable, Sendable {
    var visible: Bool
    var hasTrack: Bool
    var canPlay: Bool
    var isPlaying: Bool
    var isLoading: Bool

    init(visible: Bool, hasTrack: Bool, canPlay: Bool, isPlaying: Bool, isLoading: Bool) {
        self.visible = visible
        self.hasTrack = hasTrack
        self.canPlay = canPlay
        self.isPlaying = isPlaying
        self.isLoading = isLoading
    }

    /// Reads the setting and playback. Play can also start the library when
    /// nothing is current; previous and next need a current track.
    @MainActor init(model: AppModel) {
        let hasTrack: Bool = model.player.current != nil
        let hasLibrary: Bool = !model.library.tracks.isEmpty
        let status: PlaybackStatus = model.player.status
        self.init(visible: model.showsMenuBarControls, hasTrack: hasTrack, canPlay: hasTrack || hasLibrary,
                  isPlaying: status == .playing, isLoading: status == .loading)
    }

    var playSymbol: String { isPlaying ? "pause.fill" : "play.fill" }
    var playLabel: String { isPlaying ? L10n.string("暂停") : L10n.string("播放") }
}

/// The state plus the button labels, so a language change also reaches the
/// tooltips and VoiceOver.
private struct MenuBarTransportPresentation: Equatable {
    var state: MenuBarTransportState
    var previousLabel: String
    var playLabel: String
    var nextLabel: String

    @MainActor init(model: AppModel) {
        let state = MenuBarTransportState(model: model)
        self.state = state
        previousLabel = L10n.string("上一首")
        playLabel = state.playLabel
        nextLabel = L10n.string("下一首")
    }
}

/// The three status items, kept while hidden so they hold their place.
private struct MenuBarTransportItems {
    let previous: NSStatusItem
    let playPause: NSStatusItem
    let next: NSStatusItem
    var all: [NSStatusItem] { [previous, playPause, next] }
}

/// Previous, play and next as menu bar buttons. A SwiftUI menu bar extra
/// holds a single item, so each control is its own AppKit status item.
@MainActor final class MenuBarTransportController: NSObject {
    private weak var model: AppModel?
    private var running = false
    private var generation: UInt64 = 0
    private var items: MenuBarTransportItems?
    private var shown: MenuBarTransportPresentation?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    /// Shows the buttons while the setting is on and keeps them current;
    /// calling it again while running does nothing.
    func start() {
        guard !running else { return }
        running = true
        generation &+= 1
        observe(generation)
    }

    /// Stops following the model and removes the buttons from the menu bar.
    func stop() {
        running = false
        shown = nil
        guard let items else { return }
        self.items = nil
        for item in items.all { NSStatusBar.system.removeStatusItem(item) }
    }

    /// Reads the model, re-arms for its next change, then updates the buttons.
    /// The token ends an observation chain left over from before a restart.
    private func observe(_ token: UInt64) {
        guard running, token == generation else { return }
        guard let model else {
            stop()
            return
        }
        let presentation: MenuBarTransportPresentation = withObservationTracking {
            MenuBarTransportPresentation(model: model)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe(token) }
        }
        apply(presentation)
    }

    /// Creates the buttons the first time they are shown, then touches AppKit
    /// only for what differs from the last update.
    private func apply(_ presentation: MenuBarTransportPresentation) {
        guard presentation != shown else { return }
        if items == nil {
            guard presentation.state.visible else { return }
            items = makeItems()
        }
        guard let items else { return }
        let old: MenuBarTransportPresentation? = shown
        let state: MenuBarTransportState = presentation.state
        shown = presentation
        if old?.state.visible != state.visible {
            for item in items.all { item.isVisible = state.visible }
        }
        if old?.state.playSymbol != state.playSymbol {
            items.playPause.button?.image = Self.symbolImage(state.playSymbol)
        }
        if old?.previousLabel != presentation.previousLabel {
            Self.describe(items.previous, as: presentation.previousLabel)
        }
        if old?.playLabel != presentation.playLabel {
            Self.describe(items.playPause, as: presentation.playLabel)
        }
        if old?.nextLabel != presentation.nextLabel {
            Self.describe(items.next, as: presentation.nextLabel)
        }
        if old?.state.hasTrack != state.hasTrack {
            items.previous.button?.isEnabled = state.hasTrack
            items.next.button?.isEnabled = state.hasTrack
        }
        if old?.state.canPlay != state.canPlay {
            items.playPause.button?.isEnabled = state.canPlay
        }
    }

    /// New items appear to the left of existing ones, so adding next first
    /// makes the buttons read previous, play, next.
    private func makeItems() -> MenuBarTransportItems {
        let next: NSStatusItem = makeItem(named: "AlpacaMusic.Transport.next", symbol: "forward.fill",
                                          action: #selector(nextPressed(_:)))
        let playPause: NSStatusItem = makeItem(named: "AlpacaMusic.Transport.playPause", symbol: nil,
                                               action: #selector(playPausePressed(_:)))
        let previous: NSStatusItem = makeItem(named: "AlpacaMusic.Transport.previous", symbol: "backward.fill",
                                              action: #selector(previousPressed(_:)))
        return MenuBarTransportItems(previous: previous, playPause: playPause, next: next)
    }

    /// A square item whose button sends `action` here. The play item's symbol
    /// follows playback, so `apply` sets it.
    private func makeItem(named name: String, symbol: String?, action: Selector) -> NSStatusItem {
        let item: NSStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = name
        if let button = item.button {
            if let symbol { button.image = Self.symbolImage(symbol) }
            button.target = self
            button.action = action
        }
        return item
    }

    /// A template symbol sized for the menu bar.
    private static func symbolImage(_ symbol: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let image: NSImage? = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }

    /// Sets the tooltip and the VoiceOver label.
    private static func describe(_ item: NSStatusItem, as label: String) {
        item.button?.toolTip = label
        item.button?.setAccessibilityLabel(label)
    }

    @objc private func previousPressed(_ sender: Any?) {
        guard let model else { return }
        Task { await model.player.previous() }
    }

    @objc private func playPausePressed(_ sender: Any?) {
        guard let model else { return }
        Task { await model.toggle() }
    }

    @objc private func nextPressed(_ sender: Any?) {
        guard let model else { return }
        Task { await model.player.next() }
    }
}
