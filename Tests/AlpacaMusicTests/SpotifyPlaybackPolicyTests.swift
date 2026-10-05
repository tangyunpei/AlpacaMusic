import Testing
@testable import AlpacaMusic

@Suite struct SpotifyPlaybackPolicyTests {
    @Test func propagationDoesNotPretendTheOldSongIsPlaying() {
        var policy = SpotifyPlaybackPolicy(expectedTrackID: "requested")
        for _ in 0..<3 {
            #expect(policy.observe(trackID: "old", deviceID: "desktop", progress: 40, duration: 100,
                                   isPlaying: true, wantsPlayback: true) == .waiting)
        }
        #expect(!policy.hasPlayed)
        #expect(policy.observe(trackID: "requested", deviceID: "desktop", progress: 1, duration: 100,
                               isPlaying: true, wantsPlayback: true) == .matched)
        #expect(policy.hasPlayed)
    }

    @Test func externalChangesNeverBecomeAnAutomaticQueueAdvance() {
        var policy = SpotifyPlaybackPolicy(expectedTrackID: "requested")
        #expect(policy.observe(trackID: "requested", deviceID: "desktop", progress: 99, duration: 100,
                               isPlaying: true, wantsPlayback: true) == .matched)
        var moved = policy
        #expect(policy.observe(trackID: "another", deviceID: "desktop", progress: 0, duration: 100,
                               isPlaying: true, wantsPlayback: true) == .changedTrack)
        #expect(moved.observe(trackID: "requested", deviceID: "phone", progress: 99, duration: 100,
                              isPlaying: true, wantsPlayback: true) == .changedDevice)
    }

    @Test func onlyObservedMatchingPlaybackAtEndCanAdvance() {
        var policy = SpotifyPlaybackPolicy(expectedTrackID: "requested")
        #expect(policy.observe(trackID: "requested", deviceID: "desktop", progress: 100, duration: 100,
                               isPlaying: false, wantsPlayback: true) == .waiting)
        #expect(policy.observe(trackID: "requested", deviceID: "desktop", progress: 99, duration: 100,
                               isPlaying: true, wantsPlayback: true) == .matched)
        var userPaused = policy
        #expect(userPaused.observe(trackID: "requested", deviceID: "desktop", progress: 100, duration: 100,
                                   isPlaying: false, wantsPlayback: false) == .matched)
        #expect(policy.observe(trackID: "requested", deviceID: "desktop", progress: 100, duration: 100,
                               isPlaying: false, wantsPlayback: true) == .ended)
    }

    @Test func missingPlaybackHasABoundedGracePeriod() {
        var policy = SpotifyPlaybackPolicy(expectedTrackID: "requested")
        for _ in 0..<3 { #expect(policy.missing() == .waiting) }
        #expect(policy.missing() == .unavailable)
    }
}
