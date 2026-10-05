# Motion design revision — 2026-10-01

The earlier functional acceptance did not establish visual-design acceptance. The user rejected the kinetic typography and the three Canvas visualizations; the point-cloud presentation was explicitly retained.

## Design changes

- Kinetic lyrics use distinct spatial compositions, a stronger white typographic hierarchy, continuous development through the middle of the line, and a short handoff between adjacent timed lines.
- The ring becomes a projected orbital light field; ribbons become filled, overlapping silk surfaces; stars use perspective depth and forward travel. Their shapes, palettes and movement differ.
- Lyrics use a local contrast scrim instead of heavily dimming the entire visualization. The point-cloud renderer is unchanged.
- Ordinary line timestamps do not become fabricated word timings. Protected Apple Music audio still receives time-based ambience rather than claimed PCM analysis.

## Verification

The final candidate passed **259 tests in 25 suites** (13.445 seconds), including the existing real local/HTTP AVPlayer and Metal checks. New coverage verifies visible changes in the middle of each lyric composition, Chinese punctuation, deterministic seeks, bounded outgoing text, freezing the complete visual/audio shape on pause or reduced motion, ambience without fabricated audio energy, and distinct rendered modes. Repeated raster checks allow only tiny native gradient color noise; changed geometry remains detectable.

The macOS 27.0 API audit passed with warnings treated as errors. The release binary was built with SDK 27.0 and minimum macOS 26.0, and passed strict signature verification using the existing Developer ID identity, bundle `dev.byalpaca.music` and MusicKit enabled.

Native fixture playback was sampled through the full original lyric sequence, with mode changes, pause, seek, reduced motion and Apple Music ambience policy. The final high-resolution native inspection confirmed the continuous ring and silk surfaces after removing the visible per-facet seams. A 30-second original-text movie and three 12-second synthetic-signal movies were also exported. Exported movies and sampled screenshots are review artifacts, not an automated aesthetic score or a measured native frame-rate benchmark.

The signed app was installed at the normal project application path and launched successfully. Actual Apple Music playback of a test track advanced past 1:34; LRCLIB-labelled lyrics used the new kinetic compositions, and switching from deep-space ambience to silk worked during playback. The production reduced-motion preference was not enabled during this revision. Geometry tests and these observations do not imply that the user has approved the new visual style.

The library remained byte-for-byte unchanged. The point-cloud source is unchanged. QQ/NetEase account and playback code were outside this revision; their existing automated coverage ran, but no new manual login/import cycle is claimed.

The isolated fixture application uses original test text and clearly labelled synthetic input. Its twelve-second signal cycle covers silence, bass impulses, a frequency sweep, crescendo and abrupt silence. It does not read production accounts or the music library.

## Artifacts and rollback

- Installed binary SHA-256: `75ea4f89a584f6b779374fe2566b810c2c517ff09cef8adc387fb207bc1089dd`.
- Prior app: `build/.AlpacaMusic-before-motion-redesign-20261001.app`.
- Source/library backups are retained locally outside the repository.
- Test, release and API audit logs are retained locally outside the repository.


- Review clips and contact sheets are retained locally outside the repository.
- The final isolated QA bundle is retained locally outside the repository.
