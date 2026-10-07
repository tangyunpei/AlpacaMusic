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
