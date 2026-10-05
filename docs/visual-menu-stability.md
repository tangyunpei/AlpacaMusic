# Immersive visual menu stability — 2026-10-01

## Cause and change

With lyrics visible, `ImmersiveView` read `player.position` inside its lyrics computed property. The 100 ms playback clock consequently invalidated the same view scope that constructed the native Menu and its hover-driven Picker submenu. This matches the reported submenu flicker and inability to select a visual effect while captions are active.

`ImmersiveLyricsPanel` now owns the playback-position observation. `ImmersiveChrome` independently owns the controls and does not read playback time. The visual Picker uses the inline style, listing all six modes directly with native selection state. Existing geometry, bindings, lyrics timing, animations, reduce-motion behavior and action handlers are preserved. No audio or account behavior changes.

## Validation

- 295 tests in 28 suites passed.
- Review confirmed that the parent room and controls do not read the playback clock.
- macOS 27 SDK audit passed with warnings treated as errors; minimum deployment stays macOS 26.
- MusicKit-enabled release built, verified with the existing Apple developer signature, and installed after a normal app quit. The prior app bundle and source remain backed up.
- Native Apple Music playback of 爱爱爱 with dynamic captions: the menu stayed open while playback advanced from 3.68 to 9.45 seconds without menu subtree changes, then selected ribbons successfully.
- All six visual effects selected successfully during the native session. Dynamic captions continued updating while switching among ribbons, starfield, orbit, point cloud and waveform; artwork also selected with dynamic captions.
- Scroll lyrics and hidden lyrics both allowed visual changes; showing lyrics again retained the chosen effect. Playback continued through the checks. The original artwork mode, dynamic-caption selection and paused playback state were restored afterward.
- Apple Music's waveform availability limitation is unchanged; selecting that effect does not assert that raw audio is available.

No artificial unit test was added for a native menu tracking issue; actual playback interaction is required to verify the fix.
