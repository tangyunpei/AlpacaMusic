# AlpacaMusic — Visualization Spec: Album Cover Point Cloud Mode (封面点云)

> **2026-09-30 实现方向更新：** 根据当前产品决定，首发为 macOS 原生应用，使用 macOS 27 SDK / Swift 6.4，最低 macOS 26。SwiftUI + AVPlayer + Metal 取代下文历史设计中的 Electron / Three.js / Web Audio 实现路径；点云的视觉与轴向运动要求继续作为参考。当前工程入口为根目录 `Package.swift`，接口映射见 [native-architecture.md](native-architecture.md)，实测范围见 [verification.md](verification.md)。本文其余部分保留原始设计记录，不代表所有验收项已经通过。

| | |
|---|---|
| **Status** | Draft v0.3 — for review (v0.2: axis-discipline motion rules; v0.3: selectable motion schemes A/B from Junpei's follow-up review) |
| **Owner** | Junpei |
| **Date** | 2026-07-29 |
| **Target stack** | Electron (renderer) + Three.js / WebGL |
| **Companion prototype** | `prototype/point-cloud-mode.html` (single file, open in any browser) |

---

## 1. Background & intent

AlpacaMusic is a desktop music player whose interface direction references **Mineradio** (mineradio.cn / github.com/XxHuberrr/Mineradio): a player you *watch* as well as listen to, with full-screen switchable visualization modes surrounding a compact playback UI. Mineradio ships modes such as 封面粒子 (Cover Particles), 频谱方块 (Spectrum Blocks), 星球 (Planet) and 滚筒 (Tunnel), all built on WebGL particle systems inside an Electron shell.

**Point Cloud Mode** is AlpacaMusic's take on Cover Particles, with two deliberate upgrades over a flat particle poster:

1. **Real depth.** The album cover is rebuilt as a 3D cloud of colored points where each point has a Z position derived from the artwork itself. Orbiting the camera produces parallax — the cover reads as a sculpted relief, not a flat image (comparable in spirit to Mineradio's "Planet" sculptural effect).
2. **Musical bounce.** The cloud bounces up and down with the music: a vertical displacement wave whose amplitude follows the track's low-frequency energy, with sharper pulses on detected beats. When playback stops, the cloud settles into a gentle idle float so the scene never freezes.

## 2. Goals and non-goals

**Goals**

- G1 — At rest and at default settings, the album cover is clearly recognizable inside the cloud.
- G2 — Depth is perceivable: orbiting ±30° produces visible parallax between foreground and background points.
- G3 — Motion feels tied to the music: bounce amplitude tracks bass energy, beat hits produce visible accents, silence produces near-stillness (idle float only).
- G4 — 60 fps at 1080p on mid-tier hardware (Apple M1 iGPU / GTX 1650 class) at the default density.
- G5 — Every track works: any cover resolution or aspect ratio, and a deterministic placeholder when a track has no artwork.

**Non-goals (this phase)**

AI depth inference at runtime (specced as V2 in §4.2 but not required for V1), gesture/camera control, VR output, additional visualization modes (spectrum, tunnel, planet), and mobile targets are all out of scope for this document's V1 acceptance.

## 3. User stories

- US-1: As a listener, when I open Point Cloud Mode I see my current track's cover assemble from scattered points within about a second, then bounce in time with the song.
- US-2: As a listener, I can drag to orbit the cloud freely and see the artwork's depth, then double-click to snap back to the default view.
- US-3: As a tinkerer, I can adjust point density, point size, depth strength, and bounce intensity, and save my combination as a preset (matching Mineradio's per-mode parameter + preset behavior).
- US-4: As a listener on a weak GPU, the mode degrades (fewer points) rather than stuttering.

## 4. Functional requirements

### FR-1 — Cover ingestion & point sampling

- FR-1.1 Cover source priority: embedded tag artwork (ID3/FLAC/MP4 atoms) → cached online artwork (source TBD, see Open Questions) → **procedural placeholder** generated deterministically from a hash of `artist + title` (so the same track always yields the same placeholder).
- FR-1.2 The cover is normalized to a square working texture (center-crop, 512×512) before sampling. Fully transparent pixels (alpha < 10) are skipped.
- FR-1.3 The cloud is sampled as a regular N×N grid. Density presets: **Low 96² (~9.2k)**, **Medium 160² (~25.6k, default)**, **High 224² (~50k)**. Density beyond High is allowed on user request but not covered by performance guarantees.
- FR-1.4 Per point, the sampler stores: base XY (plane position), RGB color, luminance L (Rec. 709: `0.2126R + 0.7152G + 0.0722B`), and a per-point random seed (used for stagger, jitter, and desynchronized idle motion).
- FR-1.5 Rebuild (new cover or density change) must not block the UI thread for more than one frame; sampling may run in a worker or be chunked.

### FR-2 — Depth pipeline (V1 luminance, V2-ready)

The depth system is defined behind a single interface so the V2 AI provider can be swapped in without touching rendering.

```ts
interface DepthProvider {
  // bitmap in → normalized depth map [0..1] at grid resolution
  compute(cover: ImageBitmap, gridN: number): Promise<Float32Array>;
}
```

- FR-2.1 **V1 `LuminanceDepthProvider`:** depth = smoothed luminance. Pipeline: grayscale → light blur (≈1px at 512, kills speckle so the relief reads as surfaces, not noise) → percentile normalization (2nd–98th percentile mapped to 0..1, clamped) → optional gamma curve → optional invert (user toggle: "bright = near" vs "bright = far").
- FR-2.2 Z displacement: `z = (depth − 0.5) × depthScale`. `depthScale` default **0.35 × cloud width**, user range 0–1.0×. Depth changes update the `aDepth` GPU attribute only; no geometry rebuild.
- FR-2.3 Requirement check for G2: with the default depth scale, orbiting to ±30° yaw must show clear silhouette separation on a typical high-contrast cover.
- FR-2.4 **V2 `AIDepthProvider` (spec only, do not build in V1):** monocular depth estimation (candidate: Depth Anything V2 Small via onnxruntime-web, WebGPU with WASM fallback). Runs async in the background after track start; result cached per album ID on disk; on completion the depth attribute is hot-swapped with a ≤300ms crossfade. Budget: ≤2s compute on mid hardware, never blocks playback or UI; on failure/timeout, luminance depth silently remains. Output contract identical to FR-2.1 (normalized Float32Array), which is why V1 must already route all depth through `DepthProvider`.

### FR-3 — Motion: audio-reactive bounce + idle float

**Audio analysis service** (shared, not owned by this mode):

- FR-3.1 Web Audio `AnalyserNode` (fftSize 2048) teed off the playback chain (`MediaElementAudioSourceNode → analyser → destination`). One shared `AudioContext` per app; the visualizer only reads.
- FR-3.2 Derived signals published per frame:
  - `bassEnergy` ∈ [0,1] — mean magnitude of ~20–160 Hz bins, envelope-smoothed (fast attack ≈50 ms, slow release ≈300 ms).
  - `beat` events — adaptive threshold: fire when instantaneous bass > 1.3 × rolling 0.7s mean (plus small absolute floor), with a 250 ms refractory period.
  - `beatPulse` ∈ [0,1] — set to 1 on each beat, exponential decay ≈350 ms.

**State A — Playing (audio-reactive bounce):**

- FR-3.3 Vertical (Y) displacement per point: a traveling sine wave across X, `Δy = sin(x·waveFreq − t·waveSpeed + depth·k) × bounceAmp × bassEnergy × depthWeight`.
- FR-3.4 **Depth-weighted motion:** `depthWeight = 0.7 + 0.6 × depth` — foreground points move ~1.3× more than background points. This couples the two headline features: the bounce itself makes the depth visible even from a head-on camera.
- FR-3.5 Beat accents: on `beatPulse`, (a) point size × (1 + 0.5·pulse), (b) brightness lift, (c) whole-cloud vertical kick proportional to pulse, and (d) the **beat pop** — **primarily a Z push** toward the camera on high-depth points, accompanied by a **gentler** radial expansion in the cover plane (X+Y, anchored at the cloud center, ~1–2% at full pulse, depth-weighted so bright/near points follow more). Z carries the pop; X+Y follow softly. Default on; one toggle controls the whole pop. (This is Scheme A's beat accent — Scheme B replaces it with a radial X+Y burst, see FR-3.6.)
- FR-3.6 **Axis discipline & motion schemes** (v0.2, generalized in v0.3): fixed axis roles — X = sideways grid position, Y = up/down, Z = height relief of the cover. Governing principle: **exactly one axis carries continuous motion** (the energy wave + idle float); the remaining axes move only inside brief beat accents; the static relief always lives on Z. Two schemes, exposed as a user parameter:
  - **Scheme A — "Y-bounce" (default):** continuous motion on **Y** (wave, beat kick, idle float). Beat accent = the FR-3.5d pop (Z push primary + gentle X+Y follow ~1–2%). Reads strongest from the default head-on camera — this is the original "cloud bounces up and down". (Diagram: `docs/axis-convention.svg`.)
  - **Scheme B — "Z-breathe" (v0.3, from review):** continuous wave + idle float move on **Z**, riding on top of the static relief — the sculpture breathes and ripples in depth while the artwork stays pixel-crisp in-plane (X and Y untouched between beats). Beat accent = a radial **X+Y** burst from the cloud center (~2–4% at full pulse, depth-weighted) plus the scheme-neutral size/brightness pulse; there is **no Z beat push** in this scheme (Z is the continuous axis). Reads strongest at an angle or while orbiting; head-on it reads as size/brightness breathing.
  - Trade-off summary: A maximizes visible bounce from the default camera; B maximizes artwork integrity during continuous motion. Switching schemes is a uniform change only — no geometry rebuild.
- FR-3.7 Legibility cap (G1): at default settings the mean |Δy| must stay ≤ 8% of cloud height so the artwork never dissolves into noise at full bounce.

**State B — Paused / no audio (idle float):**

- FR-3.8 Gentle breathing: per-point sinusoidal **Y-only** drift, amplitude ≈1.5% of cloud height, phase desynchronized by the per-point seed; no beat pulses; slow global drift only.

**Transitions:**

- FR-3.9 All audio-driven uniforms are low-pass filtered so play ⇄ pause blends over ≤500 ms. The cloud never snaps between states.
- FR-3.10 If audio analysis is unavailable (e.g., protected/routed output), fall back to a constant gentle wave at idle amplitude — never a frozen frame, and never fake "beats".

### FR-4 — Entry & track-change animation

- FR-4.1 Fast entry (ref. Mineradio 封面粒子 "快速入场动画"): points fly in from a scattered shell to their target positions in 0.8–1.2 s with per-point stagger (seeded) and cubic easing.
- FR-4.2 On track change: current cloud dissolves outward (~0.4 s) while the next cover samples; new cloud assembles per FR-4.1. If the next cover isn't ready, hold the dissolve end-state, never a blank flash.
- FR-4.3 A "reduce motion" app setting skips assembly/dissolve (cut + 200 ms crossfade instead).

### FR-5 — Camera & interaction

- FR-5.1 Default framing: cloud fills ~70% of viewport height, camera with a slight initial yaw/tilt so depth reads immediately on entry.
- FR-5.2 Drag to orbit: unlimited yaw, pitch clamped to ±75°, with inertia (ref. Mineradio 360° free rotation). Scroll/pinch zoom 0.6×–2.5×. Double-click resets framing.
- FR-5.3 Optional auto-orbit (default off): slow yaw ≈4°/s for ambient/screensaver use.

### FR-6 — Parameters & presets

- FR-6.1 Live-adjustable without rebuild: point size, depth scale, invert depth, bounce intensity, wave speed, idle float amount, glow blending, auto-orbit. Density changes trigger a rebuild (FR-1.5).
- FR-6.2 Built-in presets **Calm / Punchy / Deep Relief** (values in Appendix A) plus user-saved custom presets, persisted in the app's settings store (matching Mineradio's per-mode preset save).

### FR-7 — Fallbacks & failure behavior

- FR-7.1 No artwork → procedural placeholder (FR-1.1); the mode is never empty.
- FR-7.2 WebGL context loss → automatic context restore and cloud rebuild within 2 s.
- FR-7.3 Cover decode failure → placeholder + non-blocking toast.

## 5. Non-functional requirements

- NFR-1 **Performance:** 60 fps at 1080p, Medium density, on M1 iGPU / GTX 1650 class; ≥30 fps floor at High density. Per-frame JS budget ≤4 ms: all displacement runs in the vertex shader driven by a handful of uniforms (`time, energy, beatPulse, …`); the CPU only reads the analyser and updates uniforms.
- NFR-2 **Auto-degrade ladder** when fps < 45 for 3 s: High→Medium→Low density, then cap `devicePixelRatio` at 1.5, then disable glow blending. Restore one step at a time when fps > 55 for 10 s.
- NFR-3 **Latency:** mode becomes visible ≤500 ms after cover texture decode; audio-to-motion latency ≤50 ms (one analyser read per frame).
- NFR-4 **Memory:** ≤150 MB incremental at High density including textures.
- NFR-5 **Battery:** optional 30 fps cap when on battery power (Electron `powerMonitor`).
- NFR-6 **Offline:** the mode has zero network dependencies (Three.js bundled with the app, not CDN-loaded; V2 depth model shipped or downloaded once and cached).

## 6. Technical notes (informative, matches prototype)

- One `THREE.Points` + `BufferGeometry`; attributes: `position` (base XY), `aColor`, `aDepth`, `aSeed`, `aScatter` (entry origin). `ShaderMaterial` with round soft sprites (`gl_PointCoord` discard + smoothstep edge), size attenuation `uSize × (uScale / −mv.z)`, optional additive blending ("glow") with `depthWrite:false`.
- Per-frame uniform updates only: `uTime, uEnergy, uBeat, uAssemble` — everything else changes on user input. Beat detection and envelopes live in JS (FR-3.2), not in shader.
- Electron: analysis in the renderer process off the `<audio>` element; create the `MediaElementAudioSourceNode` exactly once per element (Web Audio throws on a second call).
- The companion prototype implements FR-1 (file/placeholder sources), FR-2.1–2.3, FR-3 (including a synthetic-beat simulator for testing without an audio file), FR-4.1, FR-5, and the FR-6.1 parameter set. Its defaults are the normative values in Appendix A.

## 7. Acceptance criteria

- AC-1 Loading any JPEG/PNG cover (tested: 1:1, 4:3, 16:9, ≥3000px, ≤200px) produces a recognizable point cloud; a track with no artwork shows the deterministic placeholder. (FR-1, FR-7)
- AC-2 With depth at default, orbiting to 30° yaw shows parallax; toggling invert visibly flips relief direction; changing depth scale does not rebuild geometry (verified via frame-time trace). (FR-2)
- AC-3 Playing a bass-heavy track: cloud bounce amplitude visibly follows the music; muting the track collapses motion to idle float within 500 ms; beats produce size/brightness pulses at plausible moments ≥80% of the time on a 120 BPM reference track. (FR-3)
- AC-4 Pausing leaves a gently floating (never frozen, never snapping) cloud. (FR-3.8, 3.9)
- AC-4b With beat pop disabled and music playing, the two non-continuous axes are bit-stable across frames while the continuous axis animates — Scheme A: X and Z stable, Y moving; Scheme B: X and Y stable, Z moving (verifiable in a frame capture). (FR-3.6)
- AC-5 Entry assembly completes in ≤1.2 s; track change never flashes an empty scene. (FR-4)
- AC-6 Orbit/zoom/reset work as specced; pitch cannot flip past ±75°. (FR-5)
- AC-7 All FR-6.1 sliders take effect live; the three built-in presets load Appendix A values exactly; a custom preset survives app restart. (FR-6)
- AC-8 60 fps sustained for 3 min at 1080p/Medium on reference hardware; forcing fps < 45 triggers the degrade ladder in order. (NFR-1, 2)
- AC-9 Airplane mode: mode fully functional with local files. (NFR-6)
- AC-10 Depth path routed through `DepthProvider`; swapping in a mock provider (e.g., radial gradient) requires zero rendering-code changes. (FR-2.4 readiness)

## 8. Open questions

1. Online artwork source & licensing for tracks without embedded art (NetEase/QQ APIs as in Mineradio, or MusicBrainz/CAA?) — affects FR-1.1.
2. Settings store choice for presets (electron-store vs app config file). — FR-6.2
3. ~~Beat pop default?~~ **Resolved 2026-07-29:** ships default-on — Z push primary, with a gentler X+Y radial follow (FR-3.5d); outside the pop, X never animates (FR-3.6).
4. Color treatment: always original cover colors, or optional theme tint to match the app's accent (Mineradio uses lens/color customization)?
5. V2 model distribution: bundle (~25 MB) vs first-run download; license review for chosen depth model.
6. Default motion scheme — A (Y-bounce) or B (Z-breathe)? To be settled by A/B feel-testing in prototype v0.3 (Motion → Scheme dropdown); A remains default until decided.

## Appendix A — Default parameters (normative; mirrored by the prototype)

| Parameter | Default | Range | Notes |
|---|---|---|---|
| Density | 160² (Medium) | 96²–224² presets | rebuild on change |
| Motion scheme | A — Y-bounce | A / B | B: Z continuous, beat = X+Y burst ~2–4% |
| Point size | 1.8 | 0.5–4.0 | px at reference distance, ×(1+0.5·beat) |
| Depth scale | 0.35 | 0–1.0 | × cloud width |
| Invert depth | off | on/off | bright = near by default |
| Bounce intensity | 0.16 | 0–0.4 | × cloud height at energy = 1 |
| Wave frequency | 4.0 | 1–10 | cycles across cloud width |
| Wave speed | 3.5 | 0.5–8 | rad/s |
| Idle float | 0.012 | 0–0.05 | × cloud height |
| Glow (additive) | on | on/off | auto-off on degrade ladder |
| Beat pop | on | on/off | Z push primary + gentle X+Y radial ~1–2%, ≈350 ms decay |
| Auto-orbit | off | on/off | 4°/s |
| **Preset: Calm** | bounce 0.10, speed 2.0, idle 0.015, size 1.6, depth 0.30 | | |
| **Preset: Punchy** | bounce 0.22, speed 5.0, idle 0.010, size 1.9, depth 0.35 | | |
| **Preset: Deep Relief** | bounce 0.14, speed 3.0, idle 0.012, size 1.7, depth 0.65 | | |
