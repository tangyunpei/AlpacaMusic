# Adaptive lyric canvas — 2026-10-01

## Reference and intent

The user requested more expressive, varied dynamic captions inspired by COTODAMA Speaker Canvas, with musical rhythm influencing their design. The [official Canvas product page](https://cotodama-speaker.com/products/cotodama-speaker-canvas) describes the combination of typography and motion, with calmer or more dynamic treatment according to the music. Its product photography and the [official Lyric Speaker demonstration](https://www.youtube.com/watch?v=I9dJOGbO4H0) were inspected in the browser. The embedded video failed with error 153, but its normal YouTube page played successfully, muted. The visible demonstration included compact and large lettering, weight contrast and tilted layouts. This implementation uses original layout and motion code; it does not implement COTODAMA's proprietary analysis engine.

## Behavior

The lyric director independently combines composition, motion and decorative typography. It selects treatment from the current cue's text density and duration, plus a reproducible text/phrase seed. It does not cycle through eight presets in a fixed order or reshuffle a phrase on each audio frame. Groups settle with small phase differences; longer cues use breathing and drifting movement, while short/dense cues use quicker arrivals. The complete primary text remains visible.

Real beat and energy envelopes from the existing PCM analyzer contribute restrained accents. A dedicated clock smooths measured envelopes with different attack/release rates and freezes them on pause. Missing audio has no synthetic beat. Apple Music uses lyric cue choreography because the current MusicKit player exposes no PCM to this app. Cue duration is not a BPM estimate. Only real supplied word timestamps receive timed highlighting.

Outlined decorative text uses CoreText glyph paths cached at a fixed reference size and scaled during drawing, with bounded caches. The main text remains filled and legible. Decorative layers can be cropped; primary text must fit the viewport. Existing scroll lyrics, translation, seek actions, long-line fallback, menu observation boundaries and reduce-motion semantics remain in place.

## Evidence

- Full Swift test run: 306 tests in 29 suites passed. Coverage includes deterministic phrase direction, readable entrances, primary-text containment under maximum audio accents at small/medium/large sizes, missing and non-finite audio, smoothing and pause behavior, bounded decorations, and preservation of unmatched word metadata.
- macOS 27 SDK audit passed with warnings treated as errors. Release and independent QA builds both passed. The signed release was verified before and after installation; minimum deployment remains macOS 26.
- Native independent QA: original Chinese phrases, outlined layers and translation rendered while the test clock ran. Paused captures kept the same lyric positions; the transport hover appearance differed, so whole-file screenshot equality is not claimed. Reduce Motion removed the decorative motion and stopped the waveform.
- Native signed app: the existing Apple Music track rendered LRCLIB lyrics, advanced between phrases, and changed compositions while playing. The visual menu opened and successfully changed from artwork to oscilloscope and back during dynamic captions. The oscilloscope correctly disclosed that Apple Music has no available audio waveform. Original artwork selection, paused state and position around 00:40 were restored afterward.
- Real PCM accents are connected to the existing analyzer and covered by measured-envelope tests. This turn did not separately verify live PCM beat synchronization with a third-party music track; the montage and independent rhythm exercise use synthetic test input.
- Ten scoped files were installed after verifying that the formal source tree matched the preparation baseline. Source and application backups were preserved. The music-library file remained byte-identical before and after validation.

The opt-in montage uses original test phrases and an explicitly labeled synthetic beat envelope. It samples the production renderer across different cues; it is not a recording of a real song or a claim of native audio beat synchronization.

Preview: 24 seconds, 960 × 540, 24 fps, eight original cues. Local artifact: `AlpacaLyricCanvas/lyric-canvas-preview.mp4` in this chat's visualization directory.

## Phrase wrapping follow-up

Display phrasing is independent from provider cue lines. Long lines now prefer punctuation, supplied spaces/newlines and NaturalLanguage word boundaries, with a viewport-dependent width budget and globally balanced rows. Chinese and Latin text share the same wrapping path; closing punctuation stays with its preceding phrase. The original string and its authoritative cue interval remain intact. Only supplied word timestamps receive word-level timing.

Cues exceeding the selected composition’s two- or three-group capacity use a dedicated row composition with limited relative vertical movement and independent row positions. Extremely long or unreadably small layouts keep the existing reading fallback. Pause, seeking, decorative layers and audio smoothing are unchanged.

Follow-up validation:

- The final full test run passed: 322 tests in 29 suites. The phrasing cases cover Chinese punctuation and supplied spaces, numeral/classifier pairs, quotes, contractions, hyphenated words, mixed text, emoji, combining marks, preserved newlines and defensive limits.
- Primary-text containment and group separation were checked across cue phases and maximum audio accents at multiple viewport sizes. A specific three-group regression covers compositions originally designed for only two groups. Supplied word ordering, word timestamps and cue intervals remain unchanged.
- Original Chinese and English test phrases were rendered with the production caption view at 430- and 1000-point widths and visually inspected. Both scrolling lyrics and the long-line reading fallback use the improved display wrapping while retaining the original accessibility sentence and seek target.
- The macOS 27 SDK audit passed with warnings treated as errors. The final signed release build also passed; minimum deployment remains macOS 26. Six scoped source, test and documentation files and the signed app were installed with source/application backups.
- The signed native app was checked with an Apple Music test track. A previously overlapping three-group LRCLIB cue rendered in three distinct rows after the correction. Scrolling and dynamic lyric modes remained usable. The validation playback was paused and returned to the pre-update position afterward.
- The music-library file remained byte-identical before and after validation. No provider data, lyric cue timing, account state or audio playback logic was rewritten by this follow-up.


## Local word choreography follow-up

The user clarified that Canvas and other COTODAMA demonstrations should be considered separately, and called out word-local circles, frames, flashes, heavier ink and blinking. The [official Japanese Canvas page](https://cotodama-speaker.com/ja/products/cotodama-speaker-canvas) describes impression/chorus estimation and matching typography and motion. The page's embedded demonstration could not play in the research browser. Public documentation does not specify the local-effect trigger algorithm or establish a different algorithm for each speaker model; this implementation does not make those claims.

A separate, sparse accent layer now works within the existing sentence composition. Untimed phrases are split losslessly at NaturalLanguage lexical boundaries; whitespace, punctuation, contractions, hyphens and Unicode graphemes remain intact. At most two eligible content units are selected per cue with reproducible choices. Common function words and punctuation are avoided. This is editorial typographic selection, not semantic importance or vocal-stress recognition.

For compatible, valid supplied word intervals, explicit long durations and gaps determine sustained accents or pause gestures; other selected words use their exact supplied onsets. Pause gestures start near the supplied word end and settle within the available gap. A cue with only a line timestamp uses simultaneous cue-entry typography and restrained settling, without fabricated word times or progressive word hiding. Measured PCM beat input can moderately strengthen an accent inside its actual word window; drum peaks are not classified as vocal stress. Apple Music keeps cue-based typography while PCM is unavailable.

Local marks combine oval strokes, rounded frames, brief luminous plates, heavier ink and an expanding arc. They retain the base glyph; flashes never remove the primary word or repeatedly flash the whole canvas. Flash envelopes have at most two brightness accents per selected onset, 0.42 seconds apart. Heavier glyph advances and maximum mark geometry are reserved before fitting. Single-glyph font-weight interpolation avoids double-ink fringes. Compact compositions whose complete trajectory would cross rows choose a separated-row layout once when preparing the cue. Layout choices include word timing in the plan key and do not change with audio frames. Decorative echoes and outgoing sentences carry no local accents. Reduce Motion suppresses the accent layer; pause and seeks use the same deterministic playback-position envelopes.

Validation:

- The final full run passed 340 tests in 29 suites. Twelve core accent tests cover lossless lexical splitting, function-word avoidance, sparse deterministic choices, actual onsets, supplied gaps/sustains, malformed/non-finite intervals, unavailable audio, reduced motion and seek reconstruction. Rendering regressions cover complete text/timing preservation, simultaneous enhanced-LRC onsets, primary/mark containment and row separation under maximum measured-envelope values across all eight scenes and multiple viewport sizes, and suppression on decorative copies.
- SDK 27 API audit and the final signed release build passed with warnings treated as errors. Shipping minimum remains macOS 26. The isolated native QA build passed independently.
- The native QA app displayed a circle on the current supplied timed word at 00:35.25. The test clock advanced; backward positioning restored the cue. Reduce Motion removed circles and background echoes and kept the complete sentence legible. These are original fixture lyrics with artificial timestamps and an explicitly labeled synthetic spectrum; no actual vocal-stress analysis was verified.
- Offscreen production-renderer stills for Chinese and English were inspected at 430- and 1000-point widths. A 24-second, 960 × 540, 24 fps montage samples all five local mark/ink styles and a timed gap/sustain cue. It uses original text and artificial test timestamps with audio input disabled. Artifact: `AlpacaWordAccents/word-accents-preview.mp4` in this chat's visualization directory.
- Seven scoped code, test and documentation files and the verified signed app were installed with recoverable backups. The installed app rendered the current Apple Music/LRCLIB cue with a local frame; the original track, artwork selection, dynamic-caption mode and paused position at 73.567398088 seconds were preserved. The music-library file remained byte-identical to the preparation baseline.
- This follow-up did not verify real-time vocal-stress recognition or live PCM-to-word alignment for a third-party song. It uses supplied timing and bounded editorial accents; Apple Music still has no PCM input in this app.


## Living word motion follow-up

The prior local accents still read like badges over rigid text. This revision separately inspected the regular [Lyric Speaker demonstration](https://www.youtube.com/watch?v=I9dJOGbO4H0) and a playing [Lyric Speaker Canvas product demonstration by Tsutaya Electrics Plus](https://www.youtube.com/watch?v=0DqLEBpJN10), both muted in the browser. The Canvas footage around 1:47 shows contrasting small and large words and linear strokes participating in the composition. This is visual evidence of its presentation; it does not establish COTODAMA's proprietary triggers, lyric-stress detection, or analysis internals. No reference video or song lyrics were downloaded or embedded in the application.

Words now have a short staggered cue entrance, slight lean and damped return. Sparse focal words have a modest size contrast within their phrase, reserved before fitting. An accent is a finite gesture with preparation, strike, elastic recovery and disappearance. A ring lifts and leans the word, a frame compresses and recoils, a luminous stroke moves briefly across the lower edge, weight emphasis lifts the word, and a held-word arc opens gently. Each drawing shares the word's local translation, tilt and axis scale. Asymmetric open curves, opposing frame corners and traveling stroke tails replace perfect static circles, closed badges and luminous plates. Text remains visible.

Line-only lyrics receive two separately delayed editorial gestures and then a reading rest; the delay never becomes a word timestamp. Supplied onsets, gaps and sustained intervals still control timed effects. Available measured audio only moderates the actual word window; missing Apple Music PCM remains missing. Replaying and seeking reconstruct exactly the same event from playback position. Reduce Motion removes both individual entrances and local gestures.

Natural glyph measurements remain unchanged by sampled motion. Stable advances reserve heavier glyph ink, focal size, axis expansion, word tilt and horizontal movement. The complete trajectory reserves local glyph and stroke motion before fitting; cross-row detection uses the worst local glyph envelope. Local decorative strokes can approach adjacent text; validation does not claim that every decorative stroke is disjoint from every neighbor. No provider, player, account, lyric-source or menu logic changed.

Validation before installation:

- Full run passed 353 tests in 29 suites, including finite event/recovery/rest windows, real timing preservation, all five stroke geometries, deterministic seeking, reduced motion and dense 24 fps glyph/mark containment samples at 300- and 1000-point widths across all eight scenes. A separate continuous editorial trajectory checks focal-word separation from neighbors.
- SDK 27 API audit, signed MusicKit release and independent native QA build passed. Minimum macOS remains 26. No deprecated API was added.
- Original Chinese/English stills at 430 and 1000 points were visually inspected. The production renderer exported a 24-second, 960 × 540, 24 fps montage of five gestures plus a supplied pause/hold cue, with audio disabled and artificial timestamps explicitly labeled. Preview: `AlpacaLivingType/living-type-preview.mp4` in this chat's visualization directory.
- Native isolated QA ran forward from 35.25 seconds through later cues, displayed local underline/word motion, paused, and returned to 35.25. Primary lyric positions reconstructed consistently; frozen audio follows the most recent test input, so full screenshot byte equality is not claimed. Reduce Motion removed local and background gestures and retained complete text. Test data and spectrum are synthetic; this is not validation of real vocal-stress analysis.

Installation verification:

- Nine scoped source, test and documentation files and the signed app were installed after the formal source tree matched the preparation baseline. Installed code/executable hashes match the tested release. The final installed application signature verified successfully in the system environment. Source and application backups remain recoverable.
- The formal application reopened the same Apple Music track, 爸我回來了, paused at 73.567398088 seconds. Immersive mode was restored with dynamic captions, LRCLIB lyrics and the original artwork visual. The current cue rendered using the updated production view; validation did not start third-party song playback. The music-library file stayed byte-identical to the preparation baseline.


## Playback-position word accents follow-up

The user requested that local emphasis arrive when playback reaches its corresponding word, and authorized a pronunciation-weighted estimate when only line timing exists. This supersedes the prior cue-entry editorial delays. Current Netease and QQ paths return ordinary LRC, and Apple Music uses LRCLIB ordinary synced LRC; enhanced LRC imports can carry genuine word intervals. This revision changes the visual scheduler, not providers or stored lyric data.

Estimated schedules are separate visual metadata and never overwrite LyricWord or create supplied timestamps. Genuine word onsets take priority. Without them, a finite closed cue interval is distributed across all spoken units in source order, including function words, using Chinese characters, an English syllable heuristic and limited punctuation pauses. Whitespace and decorative emoji do not consume sung time. The schedule is prepared with the cached layout; no per-frame language analysis or random trigger is added. With no trustworthy closed interval, local estimated accents are omitted. Ordinary LRC line ends can mark the next cue after an interlude, so this estimate cannot establish vocal offsets or exact stress. No acoustic alignment, tempo inference or Apple Music PCM was introduced.

Whole-sentence lexical tokenization precedes row layout, so resizing or changing spatial rows cannot alter a word's identity or scheduled accent. Selected words no longer enter with permanent focal enlargement: size, heavier ink and marks appear during the corresponding event, then return to baseline. Layout still reserves the complete maximum glyph and mark trajectory. Genuine pause-style marks now begin on the selected word onset and use the supplied gap only for recovery; emphasis no longer waits until the word is over. The source label discloses estimated local emphasis for the active line, including mixed real/line-timed documents.


Validation before installation:

- All 364 tests in 29 suites passed in a clean full run. Coverage includes lossless source/timestamp preservation, CJK/English pronunciation weights, punctuation budgets, repeated words, complete-source function-word timing, simultaneous and zero-duration supplied onsets, strict pre-trigger suppression, bounded effect windows, resizing invariance, deterministic seeking and Reduce Motion. Dense containment checks sample the complete cue at 24 fps.
- The initial renderer-export run passed the lyric and montage checks but an existing native playback test paused unexpectedly and produced four cascading spectrum/waveform failures. The standalone five-test native playback suite and subsequent clean full suite both passed without code or assertion changes. Parallel media/export interference is plausible; its precise cause was not established.
- SDK 27 API audit, final signed MusicKit release and independent native QA build passed, with the macOS 26 minimum retained and no deprecated API added.
- In isolated native QA, the supplied word 靠近 had no mark at 34.9 seconds, enlarged and started its circle at 35.06 after its 35.0 onset, and returned to baseline by 37.0. For the line-only English fixture beginning at 9.0, light had no opening-cue mark and showed its frame at 12.56 after the estimated 12.5 onset. The current-line source label disclosed the estimate. Reduce Motion removed both mark and focal enlargement. These are original fixture lyrics and artificial timing, not live vocal alignment.
- The production renderer exported 576 frames to a 24-second, 960 × 540, 24 fps preview: AlpacaWordTiming/word-timing-preview.mp4 in this chat's visualization directory. Chinese/English stills and montage samples were inspected. Text and timestamps are artificial fixtures, and audio input is disabled.

Installation verification:

- Eight scoped source, test and documentation files and the signed app were installed only after the formal source tree matched its preparation baseline. Recoverable backups and the release manifest are retained locally outside the repository. Installed source and executable hashes match the validated stage, and the final application signature verified in the system environment.
- The formal app reopened the prior Apple Music test track and retained its pause state and playback position. The immersive production view rendered the LRCLIB cue, disclosed estimated local emphasis and retained dynamic-caption mode and the artwork visual. The original main view was restored after the check; no third-party song playback was started. The music-library file remained byte-identical to the preparation baseline.


## Complete local gestures across word transitions

The user reported that a local accent disappeared partway through when playback advanced to the next word. The previous scheduler capped estimated gestures at the estimated word end and supplied-timing gestures at the next word onset; this compressed each style's motion and release into very short syllable intervals.

This correction preserves the same actual or pronunciation-estimated trigger, but separates sung-word intervals from visual lifetime. Ordinary gestures use their full style duration (0.84–1.28 seconds), and can settle on their original word after the next word begins. Actual long holds retain the supplied end plus a small recovery; short holds use the normal complete gesture. Contours finish while visible before withdrawing. At most two selected words remain eligible, and all layout reservations, original lyric timestamps, audio availability and deterministic seeking remain unchanged. Entire sentence transitions still end the prior composition; this is a scoped correction for word transitions, not a new cross-sentence overlay.


Validation before installation:

- The full run passed all 369 tests in 29 suites, including all five styles on 40 ms supplied and estimated word windows, continuity across the next onset, contour completion while visible, natural recovery, long holds with an immediate following word and sentence-boundary cleanup. A production layout regression uses 120 ms words and verifies unchanged source text/times, continuation on the original fragment, exact reseek state and Reduce Motion. Existing dense containment and neighboring-word checks also passed.
- SDK 27 API audit, signed MusicKit release and independent native QA build passed with warnings treated as errors; minimum macOS remains 26.
- In a temporary isolated QA copy, the original Chinese fixture used artificial 120 ms intervals (30.0 through 30.48), while the containing sentence remained on screen until 38.0. 此刻 began its circle at 30.18; its gesture remained visible at 30.54, after that word ended at 30.24 and subsequent words had completed. By 31.7 the marks had recovered. Repositioning to 30.54 reconstructed the gesture, and Reduce Motion removed the local marks and motion. This fixture adjustment was confined to temporary QA input and is not part of the installed sources. No third-party song playback or acoustic-alignment claim is made.

Installation verification:

- Four scoped source, test and documentation files and the signed release were installed after matching the complete preparation baseline. Recoverable source and app backups are retained locally outside the repository. Installed code and executable hashes match the validated stage; the final application signature verified in the system environment.
- The formal app restored the prior Apple Music test track, pause state and playback position. Immersive dynamic captions and artwork visual were restored, and the current LRCLIB cue rendered with the estimated-timing label. No third-party playback was started. The user library remained byte-identical to the preparation baseline. The release manifest is retained locally outside the repository.


## Bolder local accent strokes

The user requested thicker, more exaggerated circle, frame and triangle accents. Decorative ink now uses heavier scale-aware strokes, a stronger visible contour and larger hand-drawn reach while keeping the text readable. A triangle gesture joins the existing styles. It is a local animated outline/wedge, not a filled plate over lyrics. Trigger timing, pronunciation estimation, short-word continuation, source timestamps, pause/seek reconstruction and reduced-motion behavior remain part of the existing scheduler. The geometry reservation includes the new stroke width and complete gesture trajectory before fitting.


Validation before installation:

- The complete regression run passed 373 tests in 29 suites. It includes the sixth accent's stable raw value, supplied/estimated onset scheduling, full recovery across short words and deterministic seeking. After the final triangle tail adjustment, all 11 focused rendering/export checks passed again.
- The geometry checks cover stronger ink, brightness scaling, complete gesture reservations, triangle placement above its own glyphs, fitted production layouts and visible/nonempty sampled paths. Ordinary accents reserve their actual selected style, preserving the existing motion range. The SDK 27 audit and final signed MusicKit release and independent native QA build passed; the minimum remains macOS 26.
- Final native QA at 35.06 seconds showed a brighter, thicker circle around 靠近 with its text still legible. Reduce Motion removed the local mark and enlargement. This uses original fixture text and artificial word timestamps, without playback or access to real accounts.
- The production renderer exported 672 frames into a 28-second, 960 × 540, 24 fps montage covering six styles plus a supplied-timing Chinese cue. Ring, frame and triangle stills were inspected, including the completed open triangle after its final tail adjustment. Preview: AlpacaBoldAccents/bold-accents-preview.mp4 in this chat's visualization directory. Lyrics/timestamps are original artificial fixtures and audio input is disabled.


Installation verification:

- Seven scoped source, test and documentation files and the signed app were installed after verifying the complete preparation baseline. Recoverable source/app backups and the release manifest are retained locally outside the repository. Source and executable hashes match the validated stage; the application signature verified in the system environment.
- Immediately before replacement, the prior Apple Music test track was paused with immersive mode, dynamic-caption selection, the audio oscilloscope and lyrics hidden. The final application restored the same song and position, rendered its LRCLIB cue when entering immersion, and then returned to the original hidden-lyrics view. No song playback was started. The library remained byte-identical to the preparation baseline.


## Play each local accent completely once

The user clarified that recovery/bouncing back is not sufficient: the entire decorative animation must play once after it starts. The remaining cancellation was at the source cue's end. The old scheduler compressed a late word's event to that boundary, and the outgoing composition discarded its accent. In addition, the former trail envelope erased part of a contour before it was fully drawn, then reversed the erasure as the recoil settled.

Each triggered accent now owns an independent validated interval. It draws, presents the complete shape, and withdraws once with a monotonic exit clock; lyric timestamps still determine its onset and never shift. Circle, frame and triangle reach their recognizable completed geometry while visible, hold briefly, then erase. Font recoil is a separate motion and cannot restart or rewind the ink. Real long holds retain their supplied hold and release.

The stage retains only the original words whose accents are still running after a cue ends. Their ordinary composition pose freezes at the boundary and transfers smoothly into an upper margin over 200 ms, while the local event continues at live playback time. Two selected owners receive separate stable margin slots so the next sentence remains readable. Current lyrics and accessibility follow the actual next cue immediately; old owner text becomes quieter and fades with its own exit, while decorative ink retains its event opacity. Several fast cue changes do not cancel an older event. Ordinary sentence ghosts keep their short tail without duplicating retained words. The reading-layout fallback also keeps a completion-only canvas overlay. Gaps show the interlude after visible tails finish. Pause, seeking, track/document changes and Reduce Motion remain deterministic and do not maintain a queued animation history.

This supersedes the earlier word-transition correction's explicit cleanup at sentence boundaries. The full cycle is preserved across both word and cue transitions; it is still bounded, sparse typography rather than looping emphasis.


Validation before installation:

- The final full run passed all 382 tests in 29 suites (9.862 seconds), covering every kind on late real/estimated words, full visible presentation, monotonic progress and exit, release after actual holds, no future triggering and deterministic seeking. Stage regressions advance through several 100 ms cues during one owner's event, verify source/active lyric correctness and owner-only retention, check viewport containment and separation from current glyphs after transfer, and verify separate slots for two selected owners. Reduce Motion removes retained events.
- The final SDK 27.0 API audit, signed MusicKit release and independent native QA build passed, retaining the macOS 26 minimum and warnings-as-errors.
- A temporary QA fixture copy used beginning at 0.32–0.40 seconds, followed by three rapid cues. At 0.71 seconds, native QA showed the completed circle and its original word in the upper margin while the accessible/current lyric was on our way. At 1.42 seconds the original gesture was gone. Reduce Motion at 0.71 showed only the current lyric. This fixture edit was confined to the isolated QA copy, and was not installed in production sources. No real song, account or library was accessed by the QA app.
- The production renderer exported 288 frames to a 12-second, 960 × 540, 24 fps preview covering complete ring/frame/triangle cycles across a 0.40-second cue boundary. The trigger remains 0.32; three following cues do not cancel the prior event. Completed stills were inspected for clear shapes, separation and readable current lyrics. Preview: AlpacaCompleteCycle/complete-cycle-preview.mp4 in this chat's visualization directory. Text/timing are original artificial fixtures; the preview has no audio.
- An early stage check found an unclamped interpolation in the new owner text opacity and a test comparing against the opposite seeded direction; the interpolation was fixed and the test now uses the observed seed direction. An export-only nested require macro compile error was also corrected. The subsequent final full run and export both passed.


Installation verification:

- Nine scoped source, test and documentation files and the signed release were installed after matching the complete preparation baseline. Recoverable source/app backups and the release manifest are retained locally outside the repository. The installed source/executable hashes match the validated stage.
- The final app restored the prior Apple Music test track, pause state and playback position. Immersive mode, dynamic-caption selection, audio oscilloscope and the original hidden-lyrics state were restored. Opening immersion rendered the current LRCLIB lyric with estimated emphasis disclosed, then lyrics were hidden again to retain the previous view. No song playback was started. The music-library file remained byte-identical to the preparation baseline.


## Progressive characters in both lyric presentations — 2026-10-03

Scrolling lyrics now retain upcoming text in dim ink and progressively light each grapheme. Dynamic captions reveal only the characters whose time has arrived, including decorative echoes and the long-line reading fallback. Full text determines layout before revealing, so line wrapping and existing character positions do not shift as the sentence grows. Dynamic glyph masks use the complete shaped CoreText line, retaining combining characters, ligatures, emoji and bidirectional shaping; the small reveal movement is disabled with Reduce Motion.

Both modes share a bounded cached timeline. Platform word/character onsets and explicit pauses take priority. Multi-character words are subdivided inside their supplied window; line-only lyrics use the existing syllable/CJK/punctuation allocation shared with local emphasis. These are textual estimates, not measured vocal alignment or BPM recognition. An open final cue uses a bounded conservative duration. Estimated character timing is disclosed in the source label. Plain text or invalid/oversized timing falls back to readable text, and the original lyric document is unchanged.

Playback-position sampling reconstructs the display after backward/forward seeks. Short interpolation is bounded at cue ends; pausing freezes reveal. Existing complete local-accent event lifetimes remain independent of word/line changes. Future echo characters are hidden by the same glyph schedule.

Validation: 600 tests in 57 suites passed, macOS 27 SDK API audit passed, and a signed MusicKit release was built with macOS 26 minimum. New tests cover timing/gaps, estimates, repeated text, Unicode, all eight compositions, all decorative directions, reduced motion, complete accent tails, and production text rasterization with fixed wrapping. Static production-renderer samples were inspected at three times for Chinese supplied word timing, English line estimates, and long reading rows. These artificial original fixtures do not establish exact alignment to a real singer. An existing Cookie-expiry test's fake clock was aligned after Foundation's real-time expiry conversion to remove load-dependent failures; provider code was unchanged.


## Whole-word alphabetic reveals — 2026-10-04

English, Spanish and other cased alphabets now reveal complete words, including accented/combining letters, contractions and internal hyphens. Han, Kana and Hangul retain grapheme-by-grapheme reveals. Mixed lines choose the appropriate unit within each run rather than classifying the whole sentence as one language. Punctuation, whitespace and emoji separate words; standalone numeric cues keep their previous timing.

The cached full-line schedule retains every original grapheme and its singing/progress interval. A separate appearance interval synchronizes all letters in each word from its first onset through its last offset, before layout splitting; provider syllable/letter fragments therefore cannot restart a typing effect. Real provider word starts remain authoritative. Line-only timing still uses the existing estimate and scales with available singing time. The immutable provider document, emphasis event lifetimes, shaped glyphs and reserved layout are unchanged. Scrolling highlights, dynamic primary text, echoes and the long-line fallback share the correction.

Verification uses original English/Spanish/CJK fixtures, provider syllable splits, Unicode joins, repeated words, timing/seek checks and the production text/glyph rendering paths. Static samples do not establish exact vocal alignment for line-only lyrics.

Validation: 631 tests in 60 suites passed, including 11 new whole-word reveal regressions. The production renderer was inspected at three playback positions with Chinese, English and Spanish original fixtures. SDK 27.0 API audit and the signed MusicKit release passed; minimum deployment remains macOS 26.
