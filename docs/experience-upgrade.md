# Listening experience update

This change keeps macOS 26 as the minimum, uses the installed macOS 27 SDK, and preserves the stable Developer ID signing identity, MusicKit configuration and saved library.

## Native acceptance — 2026-10-01

The signed candidate was deployed and launched through the normal project application path. The main experience has now been checked in the native application. The final ContentView-only status addition was installed and checked: paused Apple Music displays “已暂停”; resumed playback displays “氛围动画”. All three tested platform connections restored after the final normal restart, with no password prompt observed during the automated launch.

| Area | Observed result |
| --- | --- |
| Library and navigation | All main pages, library, favorites, sources and the imported test playlists opened. Existing tracks and playlists were retained, and scrolling worked. Private playlist names and exact library composition are omitted from this public record. |
| Responsiveness | CUA operations generally responded in about 0.8–1.5 seconds. This includes automation overhead and is not a precise frame-rendering benchmark. One process RSS observation was 339,600 KiB, approximately 332 MiB; it is a snapshot, not a long-running memory-growth test. |
| Native surfaces | Playlist creation, platform import, visual settings, the settings window, queue, file-picker cancellation and immersive view were operated successfully. Native inspection found and corrected opaque-background presentation, vertically stacked segmented labels and hidden background controls exposed to accessibility. |
| NetEase lyrics | Real NetEase lyrics were observed for test tracks. Playback for the tested tracks was refused by the platform with business code 404 and `st=-100`; lyric retrieval success does not establish audio permission. The failure notice could be dismissed manually. |
| QQ playback and lyrics | A QQ test track played with lyrics labelled as QQ. Clicking a line sought to 35 seconds; highlighting and following were observed at 69 seconds. Paused manual scrolling, returning to the current line, kinetic-mode switching and the accessibility seek action to 68.58 seconds worked. |
| Apple Music and LRCLIB | An Apple Music test track played for more than two minutes. A user-triggered LRCLIB lookup matched the song, displayed LRCLIB as the source and showed scrolling/highlight following during playback. |
| Visualizations | All five modes appeared in the native app. The ring responded to QQ PCM audio. Apple Music point-cloud frames changed between 8 and 20 seconds; its ring showed gentle shape changes between 93 and 126 seconds. Those Apple Music effects are ambience, not protected-audio frequency analysis. |
| Kinetic lyric fixture app | Original-text screenshots covered all six compositions without observed overflow, including Chinese/English text and translation. A live fixture clock advanced from 2 to 9 seconds, and the app's reduced-motion toggle was exercised. |

During QA, the app's reduced-motion setting was left enabled, explaining the user's subsequent report of no animation. It was restored to off and motion was verified. The macOS system-wide Reduce Motion setting was not changed; its integration is covered by source review and tests, not a live system-setting toggle.

## Lyric and platform boundaries

The behavior below records the original implementation. The 2026-10-01 follow-up adds current-song automatic Apple Music matching and a bounded disk cache; see [Apple Music lyrics follow-up](apple-music-lyrics.md).

Apple Music's public MusicKit song model exposes whether lyrics exist, but not lyric text. The interface supports explicit LRC/SRT/TXT import or a user-triggered LRCLIB lookup. LRCLIB receives the song title, artist, album and duration only after the user requests the lookup. Results must match all metadata and duration within two seconds; there is no fuzzy-search fallback or background library scan. Requests are serial, spaced by 300 ms, and respect service cooldown responses without automatic retries.

QQ and NetEase lyrics use the app's existing scoped platform sessions. Account-generation changes invalidate their in-memory cache and prevent old responses from replacing the current song. Explicitly imported lyrics are associated with their target track and stored locally; platform and LRCLIB results remain in bounded memory caches. File persistence, paths containing spaces and Chinese characters, account isolation, cancellation, local sidecars and target-song association are covered by fixture tests. This native session did not establish an additional manual-import/restart or account-switch round trip.

Ordinary line-timed lyrics never claim word-level timing. Plain text remains unsynchronized. Apple Music protected audio does not supply the app's PCM analysis pipeline. COTODAMA references inform typography and negative space; this is an original implementation, without copied brand assets or a claim of compatibility with its proprietary engine.

## Build and test evidence

- The full integration run passed **250 tests in 23 suites**, including native AVPlayer local/HTTP playback and actual Metal rendering at 1080p. The macOS SDK 27.0 API audit passed with warnings treated as errors; the shipping minimum remains 26.0.
- These totals belong to that full integration snapshot. Subsequent ContentView-only presentation changes are verified by release compilation and native inspection; the full suite is not claimed to have been rerun for those final changes. The final status build completed in 20.70 seconds and passed strict signature verification. Paused/resumed labels were checked in that installed build; the reduced-motion branch shares the already-tested system/app policy and was reviewed without leaving the live preference enabled again.
- The release passed strict signature verification using the existing Developer ID identity, bundle `dev.byalpaca.music`, minimum macOS 26.0, SDK 27.0 and MusicKit enabled. The signed candidate was installed through the normal project application path.
- Before-change library, application and source were backed up locally. After the final native checks and normal quit, the library remained byte-for-byte unchanged; the final restarted native app also retained the same library and playlist counts.
- The isolated QA application has an ad-hoc signature and does not instantiate production library, account or playback models. Build script: `scripts/preview-experience.sh`; fixture UI: `scripts/qa-experience.swift`. Its layout tests cover Chinese/English/emoji, long strings, multiple sizes, entrance frames, seeking, SRT gaps and reduced motion. Static row images alone do not establish scrolling behavior; real QQ and Apple Music following checks are recorded separately above.
- Three Canvas frames were also rendered with explicitly synthetic input. These are rendering evidence, distinct from the native playback observations.
- An earlier isolated live LRCLIB query through the production client/parser matched a public catalog song and returned 34 timed lines. That probe did not read the user library or platform credentials or write lyric text to its log; the later user-triggered native lookup is separately recorded above.

## Known independent issue

The native search for `最后一夜` returned 91 QQ/NetEase results while Apple Music displayed a raw `MusicDataRequest.Error` / error 1. MusicKit was authorized and Apple Music playback worked. The raw error does not establish whether the catalog request failed because of network, platform authentication or another cause. Search currently lacks the safe HTTP/status and token-error classification already used by the Apple Music library client. This is a separate search-diagnostics issue, not evidence that the new lyric or visual UI caused the request failure.

Final installed binary SHA-256: `0755c35c2bbedb4da817fcadbda714b7e71114c031f4db1000a5eac761fb062b`.

The isolated QA bundle and static rendering evidence remain in local review storage and are not included in this repository.

Sources: [LRCLIB API](https://lrclib.net/docs), [MusicKit hasLyrics](https://developer.apple.com/documentation/musickit/song/haslyrics), [COTODAMA Canvas manual](https://manual.lyric-speaker.com/canvas/index.html?lang=en&store=en_us).
