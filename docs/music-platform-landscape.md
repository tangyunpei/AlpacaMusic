# AlpacaMusic — Platform Reach & Audio Formats (research)

> **原生平台更新：** 当前主应用已转为 macOS 原生实现。Apple Music 已编码官方授权、目录搜索与 MusicKit 播放，仍需 App ID、签名、用户授权及订阅联调；Spotify 仅保留外部官方入口。当前范围与验证边界以[官方平台接入](official-platforms.md)为准。以下为历史调研原文，保留其中的旧技术方案与数据，不代表本轮重新核验或当前实现承诺。

| | |
|---|---|
| **Status** | Research input for the platform-reach decision |
| **Date** | August 2026 |
| **Decides** | Which sources AlpacaMusic can play from, and therefore whether the Point Cloud visualizer gets real audio to react to (see §3) |

## 1. Major global platforms

Subscriber share per SQ Magazine's 2026 roundup; user counts vary by report and date (Spotify ~615–760M users, ~240M+ premium depending on source).

| Platform | Global sub share | Streaming format & quality | Lossless | Third-party access for a desktop player |
|---|---|---|---|---|
| Spotify | ~31.7% | Ogg Vorbis 24–320 kbps; AAC on web | **FLAC up to 24-bit/44.1 kHz since Sep 10, 2025** (Premium, no extra cost) | Web API: search/metadata/playlists OK. Playback only via official SDKs (Premium, DRM). **Audio Features / Audio Analysis / Recommendations / previews removed for new apps since Nov 27, 2024** (extended access effectively needs 250K MAU). No raw audio access, and no beat metadata either. |
| Tencent Music (QQ音乐/酷狗/酷我) | ~14.4% | see §2 | see §2 | see §2 |
| Apple Music | ~12.6% | AAC 256 kbps | ALAC up to 24/192 + Dolby Atmos, all paid tiers | MusicKit (developer token + active subscriber). FairPlay DRM stream; no raw audio. DRM support in plain Electron is a known pain point. |
| Amazon Music | ~11.1% | lossy up to ~320 kbps | HD/Ultra HD FLAC up to 24/192 included | No practical third-party playback API. |
| YouTube Music | ~9.7% | AAC (and Opus) up to ~256 kbps | none | Embed/IFrame playback only; audio stays inside the embed. Scraping/extraction violates ToS — not an option. |
| NetEase Cloud Music | ~6.7% | see §2 | see §2 | see §2 |
| Tidal | niche | — | FLAC up to 24/192 (MQA dropped) | Official API is metadata/playback-control oriented; DRM stream. |
| Deezer | ~1.3% | MP3 320 | FLAC 16/44.1 | API mostly metadata + 30s previews. |
| Qobuz | niche | — | FLAC up to 24/192; also a **DRM-free download store** | Store purchases become local files → full access. |
| SoundCloud | large free catalog | Opus/AAC (historically MP3 128) | none | API access limited/waitlisted; some tracks streamable. Long-tail/indie content. |
| Bandcamp | niche but beloved | MP3 V0/320 streams | **DRM-free purchases: FLAC/ALAC/WAV/AIFF/MP3/AAC/Ogg** | Purchases are plain local files → perfect fit. |
| Internet radio (SHOUTcast/Icecast ecosystems) | — | MP3/AAC streams, some FLAC | rare | **Open HTTP streams, no DRM → full audio access.** Fits the "radio" identity of the Mineradio reference. |

## 2. China platforms (QuestMobile MAU, Sep 2025, via 36Kr; 汽水 ~140M by Jan 2026)

| Platform | MAU | Trend | Streaming/download formats | Third-party access |
|---|---|---|---|---|
| 酷狗音乐 KuGou (TME) | ~210M | −8.1% | lossy 128–320; VIP FLAC (SQ) / Hi-Res; encrypted downloads `.kgm/.kgma` | No official open API. Community/unofficial APIs exist (gray area). |
| QQ音乐 (TME) | ~190M | −2.8% | AAC/MP3 128–320; VIP FLAC SQ / Hi-Res 24-bit / 臻品母带; encrypted downloads `.qmc*`, `.mflac`, `.mgg` | Same — unofficial community APIs; VIP tracks need an account cookie. **This is what Mineradio integrates.** |
| 网易云音乐 NetEase | ~150M | +1.5% | MP3/AAC 128–320; VIP FLAC 无损 / Hi-Res; encrypted downloads `.ncm` | Same — the self-hosted community API ecosystem is the most mature of the three. **Also a Mineradio integration.** |
| 汽水音乐 Soda (ByteDance) | ~120M→~140M | +90.7% | app-only; ad-unlocked free listening (VIP ¥8/mo, SVIP ¥18/mo) | No API at all — app-locked. Not reachable. |
| 酷我音乐 KuWo (TME) | ~110M | −8.0% | lossy + VIP FLAC; encrypted downloads `.kwm` | Unofficial only. |

Notes: unofficial NetEase/QQ APIs are self-hosted community projects that return direct MP3/FLAC URLs for playable tracks. They power players like Mineradio, but they are unsanctioned, can break without notice, and repos periodically get taken down — treat as a best-effort source with graceful degradation, never the only source.

## 3. The constraint that decides everything: DRM vs. raw audio

The Point Cloud Mode needs raw PCM — the Web Audio `AnalyserNode` (FR-3.1) must read the decoded waveform to drive bounce and beats.

- **DRM platforms (Spotify SDK, Apple MusicKit, YouTube embed): the decoded audio is never exposed.** The visualizer would run blind — no bass energy, no beats. Spotify's server-side beat metadata (Audio Analysis) would have been a workaround, but it's closed to new apps since Nov 2024. On these platforms AlpacaMusic could only be a *remote control with static visuals* — the flagship feature dies.
- **Non-DRM sources (local files, NetEase/QQ URL-based playback, internet radio, self-hosted servers, Bandcamp/Qobuz purchases): plain audio streams → full AnalyserNode access.** The visualizer works exactly as specced.

Conclusion: AlpacaMusic's reach should be built around non-DRM sources. DRM platforms can only ever be an optional metadata/remote-control layer, not a playback core.

## 4. Music file types reference (local library support)

| Category | Formats | Notes for Electron/Chromium |
|---|---|---|
| Lossy | MP3, AAC (`.m4a`), Ogg Vorbis, Opus, (legacy WMA) | All except WMA decode natively in Chromium |
| Lossless | FLAC, ALAC (`.m4a`), APE, WavPack | FLAC native; ALAC/APE/WavPack need a decoder (ffmpeg/WASM) |
| Uncompressed | WAV, AIFF | WAV native; AIFF needs a decoder |
| Platform-encrypted downloads | `.ncm` (NetEase), `.qmc*`/`.mflac`/`.mgg` (QQ), `.kgm` (KuGou), `.kwm` (KuWo), `.m4p` (legacy iTunes DRM) | Encrypted/DRM containers — **do not support**; decrypting them circumvents DRM. Users point the app at open formats instead. |
| Metadata | ID3v2 (MP3), Vorbis comments (FLAC/OGG), MP4 atoms (M4A) | Embedded cover art here feeds FR-1.1 |

Recommended V1 local support: MP3, AAC/M4A, FLAC, OGG Vorbis, Opus, WAV natively; ALAC/AIFF via bundled ffmpeg or WASM decoder.

## 5. Reach tiers — **decided Aug 2026: Tier 1 + Tier 2 are V1 scope**

- **Tier 1 — Local library (V1 core, DECIDED):** folder scan + drag-drop, formats per §4, embedded art → Point Cloud. Zero legal risk, zero dependencies, visualizer fully functional. Every serious desktop player starts here.
- **Tier 2 — NetEase + QQ via self-hosted community APIs (Mineradio parity, DECIDED):** aggregated search across both (Mineradio's "聚合搜索"), direct-URL playback feeds the visualizer. Gray-area and breakable — ship behind a "source plugin" abstraction with graceful fallback.
- **Tier 2.5 — Internet radio (backlog):** open MP3/AAC streams via the radio-browser.info directory; cheap to add, on-brand for the radio identity, visualizer-compatible.
- **Tier 3 — Self-hosted servers (backlog):** OpenSubsonic (Navidrome/Airsonic), Jellyfin — clean documented APIs, DRM-free; natural V2.
- **Tier 4 — DRM-free download stores & open catalogs (backlog, cheap wins):** these are the *legitimate* "downloadable platforms" — files bought/fetched here are plain FLAC/MP3 and simply join the local library, where everything already works: **Bandcamp** (FLAC/ALAC/WAV/MP3 purchases), **Qobuz store** (hi-res FLAC), **Beatport** (DJ/electronic), plus free/open catalogs — **Jamendo** (CC-licensed, has an API), **Free Music Archive**, **Internet Archive** live-music collections, **Audius** (open-API decentralized streaming, DRM-free → visualizer-compatible). Integration can range from "just play the files" (free — ships with Tier 1) to in-app search/browse per store.
- **Tier 5 — Big DRM platforms as *companion* integrations (optional, not playback cores):**
  - **Spotify "remote" mode:** OAuth login → browse your playlists/library, control playback on Spotify Connect devices, show now-playing metadata and art (Point Cloud can render the *cover*, but motion falls back to the FR-3.10 constant wave — no real audio access, and the beat-metadata API is closed to new apps).
  - **YouTube embed mode:** official IFrame embed in a panel; audio stays inside the embed, visualizer blind.
  - These add breadth for users who live on those platforms, at the cost of a visibly degraded visual experience — recommend post-V1, clearly labeled.
- **Excluded by design:** ripping/downloading from Spotify/Apple/YouTube (DRM circumvention and/or ToS violation — would put the whole app at takedown risk), Soda Music (no API), decrypting `.ncm/.qmc/.kgm/.kwm` files (DRM circumvention).

### 5.1 Why Spotify / YouTube / Apple are not playback cores

Four hard reasons, none of them taste: (1) **No legal full-stream access:** outside their official DRM'd SDKs/embeds, these platforms offer no way for a third-party desktop app to play full tracks — apps that do it anyway are circumventing DRM or ToS, which is both legally risky and structurally fragile (breaks every few weeks). (2) **DRM blocks the visualizer:** even via the official SDKs, decoded audio is never exposed to the app, so the Point Cloud gets no bass energy and no beats — the flagship feature runs blind. (3) **API lockdown:** Spotify removed Audio Features/Analysis/Recommendations/previews for new apps (Nov 2024), killing the only server-side workaround for beat data. (4) **Electron DRM friction:** FairPlay/Widevine support in a stock Electron shell is painful to impossible. NetEase/QQ are different in kind: their community APIs return plain, un-DRM'd audio URLs — unofficial, but not circumvention of a DRM system, which is why Mineradio-class players integrate them and not Spotify.

Architecture implication: define a `SourceProvider` interface (search/resolve/stream URL/metadata) mirroring the `DepthProvider` pattern, so Tier 2/2.5/3 are plugins over the same player + visualizer core.

## Sources

- https://sqmagazine.co.uk/music-streaming-statistics/
- https://newsroom.spotify.com/2025-09-10/lossless-listening-arrives-on-spotify-premium-with-a-richer-more-detailed-listening-experience/
- https://subger.com/en/music/learn/lossless-audio-streaming-guide
- https://36kr.com/p/3656914391556489
- https://developers.brizm.dev/blog/spotify-api-changes-2026/
- https://developer.spotify.com/blog/2024-11-27-changes-to-the-web-api
