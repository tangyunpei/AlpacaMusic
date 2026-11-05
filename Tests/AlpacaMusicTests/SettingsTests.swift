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
    previous.abstraction = 0.2
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
    #expect(settings.validated().abstraction == 0.2)
    settings.abstraction = 7
    #expect(settings.validated().abstraction == 1)
    settings.abstraction = -1
    #expect(settings.validated().abstraction == 0)
}
