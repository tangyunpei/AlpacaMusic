import Foundation
import Testing
@testable import AlpacaMusic

@Test func malformedVisualValuesAreBounded() {
    var settings = VisualSettings.standard
    settings.depth = .nan; settings.bounce = 999; settings.density = -4; settings.scheme = 10; settings.idle = -.infinity
    let valid = settings.validated()
    #expect(valid.depth == 0.35)
    #expect(valid.bounce == 0.4)
    #expect(valid.density == 160)
    #expect(valid.scheme == 0)
    #expect(valid.idle == 0.012)
}
@Test func durationFormattingHandlesLiveStreams() {
    #expect(formattedTime(.infinity) == L10n.string("直播"))
    #expect(formattedTime(.nan) == L10n.string("直播"))
    #expect(formattedTime(125) == "2:05")
}

@Test func savedVisualPreferencesKeepTheirValuesWhenAbstractionIsMissing() throws {
    var previous = VisualSettings(density: 224, pointSize: 2.6, depth: 0.62, glow: false, reduceMotion: true)
    previous.abstraction = 0.87
    let encoded = try JSONEncoder().encode(previous)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "abstraction")
    let legacy = try JSONSerialization.data(withJSONObject: object)
    let restored = try JSONDecoder().decode(VisualSettings.self, from: legacy)
    previous.abstraction = 0
    #expect(restored == previous)
    // Presets use this same decoder, so introducing the control cannot discard
    // a user's previously named settings.
    let presetData = try JSONSerialization.data(withJSONObject: [["id": "saved", "name": "Quiet", "settings": object]])
    let presets = try JSONDecoder().decode([VisualPreset].self, from: presetData)
    #expect(presets.count == 1 && presets[0].name == "Quiet" && presets[0].settings == previous)
}

@Test func abstractionPreferencesRoundTripAndRejectNonfiniteValues() throws {
    var settings = VisualSettings.standard
    settings.abstraction = 0.78
    let restored = try JSONDecoder().decode(VisualSettings.self, from: JSONEncoder().encode(settings))
    #expect(restored.abstraction == 0.78)
    settings.abstraction = .nan
    #expect(settings.validated().abstraction == 0)
    settings.abstraction = 7
    #expect(settings.validated().abstraction == 1)
    settings.abstraction = -1
    #expect(settings.validated().abstraction == 0)
}

/// Abstraction's default moved from 0.2 to 0 on 2026-11-13: true colours and
/// every point. Settings saved at the old default move once; a value chosen
/// later, even 0.2, stays.
@Test @MainActor func settingsSavedAtTheOldAbstractionDefaultMoveToZeroOnce() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "abstraction-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let suite = "AlpacaAbstractionDefault.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
    var saved = VisualSettings(density: 224); saved.abstraction = 0.2
    defaults.set(try JSONEncoder().encode(saved), forKey: "visual-settings")
    let first = AppModel(directory: directory, preferences: defaults, ephemeralAccounts: true)
    #expect(first.visual.abstraction == 0 && first.visual.density == 224)
    first.visual.abstraction = 0.2
    first.player.shutdown()
    let second = AppModel(directory: directory, preferences: defaults, ephemeralAccounts: true)
    #expect(second.visual.abstraction == 0.2)
    second.player.shutdown()
}

@Test @MainActor func aChosenAbstractionIsKeptAndTheVeryDenseTierIsAllowed() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "abstraction-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let suite = "AlpacaAbstractionKept.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
    var saved = VisualSettings(density: 320); saved.abstraction = 0.55
    defaults.set(try JSONEncoder().encode(saved), forKey: "visual-settings")
    let model = AppModel(directory: directory, preferences: defaults, ephemeralAccounts: true)
    #expect(model.visual.abstraction == 0.55 && model.visual.density == 320)
    model.player.shutdown()
    #expect(VisualSettings.standard.abstraction == 0 && VisualSettings.densities == [96, 160, 224, 320])
    #expect(VisualSettings(density: 400).validated().density == 160)
}
