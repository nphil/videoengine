# VideoEngine — Android landscape research

Date: 2026-11-24 · Scope: web research only (no code run on devices) · Companion to `PLATFORMS.md` (contract 2.2, stages 0-5).
Legend: ⚠ = not verified from a primary source or not tested on our devices. Effort: S ≈ days, M ≈ 1-3 weeks, L ≈ a month+.

**Licence hygiene.** No source code of GPL/LGPL projects was read for this report — only READMEs, docs, issue threads and release notes. GPL/LGPL projects below are *design references only*. Permissive code (MIT, BSD, ISC, Apache, Unlicense) is marked "adaptable".

## 1. Verdict (5 lines)

1. **Build on Media3, as planned.** It is what the best Android apps use, and it already owns hardware decode, passthrough, frame-rate hints, tunnelling, scrubbing and preload.
2. **Do not wrap libmpv / libVLC as the main engine.** On Android mpv has no HDR/DV output, copies frames to the CPU on many TV boxes, and neither library is an embeddable, permissively licensed AAR.
3. **Add three small, permissive escape hatches inside the contract:** libass (ISC) for rich ASS, dav1d/FFmpeg software decoders as Media3 extensions, and an MIT `dovi_tool`-based Profile 7 → 8.1 rewrite.
4. **Treat upscaling as a GL rung (GSR/FSR/Anime4K-style) first, ML on the NPU as a gated spike** — real, but not proven for video on our two devices.
5. **Expect most pain on the Onn box, not the tablet:** weak CPU, 3 GB, no NPU, passthrough/seek quirks on its Amlogic chip. Test there first.

## 2. Landscape

| Project | Licence | Engine approach | Does well | Users complain about |
|---|---|---|---|---|
| **Media3 / ExoPlayer** (Google) | Apache-2.0 | The platform's `MediaCodec`; software decoders only via extensions you build (dav1d AV1, FFmpeg audio, VP9, FLAC, Opus…) | Hardware decode, tunnelling, passthrough, scrubbing mode (1.8), preload manager, PlayerPool, MKV/MP4 chapters; fastest-moving. 1.11.1 stable, 1.12.0-beta01 (2026-11-11) | Device-specific bugs (tunnelling, passthrough gaps); DV P7 not decoded until 1.12; no video software decoder for H.264/HEVC; effects pipeline needs the default hardware renderer |
| **Just (Video) Player** (`moneytoo/Player`, 2.8k★) | **Unlicense** (adaptable) | Media3 1.11.1 + FFmpeg audio ext | Frame-rate matching, tunnelling toggle, DV P7 treated as HDR HEVC, decoder-priority setting, PiP, skip silence | Frame-rate switch takes 10-20 s on Chromecast HD (reads 1000 samples; #632); judder after switch (#574); TrueHD Atmos + tunnelling + FFmpeg audio = unsupported (#585); ASS styling limited |
| **NextLib / Next Player** (`anilbeesetti`) | **GPL-3.0** | Media3 + FFmpeg 9.0 / dav1d / mbedTLS extension; libass for ASS; bitmap subs via FFmpeg | Only ready-made *video* software decoders (H.264/HEVC/VP8/VP9/AV1) for Media3; ASS with embedded fonts; subtitle delay/speed | Output capped at 1080p; GPL ⇒ cannot be embedded (we may copy the *idea*, not code) |
| **mpv-android** (3.7k★) | App **MIT**; libmpv LGPL/GPL | Own player (libmpv) with `mediacodec-copy` or software | libass, shaders (Anime4K, FSRCNNX), deband, interpolation; frame-exact subs | **No native HDR** (tone-mapped to SDR, #874); **no DV** (#717/#1081, green/purple on P5); drops on 4K HEVC/AV1 (#1137/#1320); `mediacodec-copy` green/broken 10-bit on some TV boxes (#540/#853/#1088); README says it is *not* a library |
| **mpvKt**, **Aniyomi** (archived 2026-09) | Apache-2.0 | mpv-android glue in Compose | Anime4K via user shaders, polished UI | Same mpv limits; Anime4K setup is manual (config files; Aniyomi/Anime4K #99) |
| **VLC for Android / libVLC** | App GPL-2.0; libVLC LGPL-2.1+ ⚠ | Own pipeline (FFmpeg + MediaCodec) | Plays almost anything | Washed-out HDR (vlc-android #2999 ⚠ title only); DV not detected (jellyfin-androidtv #3173); stutter/crash on DV P7 remux in Stremio (#2402); no TrueHD/DTS-HD passthrough on a Fire TV Cube (VLC #27670 ⚠ snippet) |
| **Kodi** | GPL-2.0+ | Own player, MediaCodec surface path | Passthrough, refresh-rate adjust setting, DV P7 FEL → 8.1 via RPU rewrite (as described in forum/NuvioTV #204) | DV shown as HDR10 on some boxes; P7 FEL issues on some Amlogic boxes ⚠ forum-level evidence |
| **Jellyfin Android TV** | GPL-2.0 | Media3 | Refresh-rate switching; libass **experimental behind a dev flag** | Refresh switch forces PCM audio on Shield (Media3 #2258, jellyfin-androidtv #4067); only the "legacy" bitmap libass mode works on Shield (PR #4630) |
| **Findroid** | GPL-3.0 | Media3 (+ mpv option ⚠ not confirmed) | Offline downloads, simple settings | ⚠ not investigated |
| **Wholphin** (Jellyfin TV) | GPL-2.0 | **Dual: ExoPlayer *or* MPV**, user picks | Auto refresh-rate + resolution switch, trickplay, great SSA/ASS on MPV | ASS invisible in "direct overlay" libass mode (#1049) |
| **Plezy** (Plex, Flutter, 4.3k★) | GPL-3.0 | **Dual: ExoPlayer (Android default) + mpv** | Closest to Marquee: GLSL shader presets, refresh match, TV passthrough | Users switch backend by hand: mpv for ASS/timing, ExoPlayer for HDR/DV (#685) |
| **NuvioTV** | GPL-3.0 | Media3 + libass-android | Plex-like TV UI | Users request a DV P7 → 8.1 mode (#204) |
| **Stremio (Android)** | Proprietary shell | ExoPlayer **and** libVLC | Fallback chain between engines | P7 remux stutter under libVLC (#2402); tunnelling forced on, hard to disable (#2444) |
| **Nova Video Player** | ⚠ old Archos repo Apache-2.0, stale; current licence not checked | Own + ExoPlayer ⚠ | Local/NAS library | ⚠ not investigated |
| **libass-android** (`peerless2012`) | **MIT** (libass: **ISC**) | Media3 extension over libass; several render modes | Used by Jellyfin TV, Fladder, NuvioTV, FongMi | Render mode matters per device (see above) |
| **Anime4K** | **MIT** | GLSL shader pack (mpv user-shader format) | Light anime upscaler; a 2026 hands-on says <3 ms/frame on SD 8 Gen 3 ⚠ single blog | Written for mpv; needs an executor on Android; anime-only look |
| **dovi_tool / hdr10plus_tool** | **MIT** | Rust CLI/lib (`libdovi`) | Reference for P7 → 8.1 RPU conversion | Must be built for Android ABIs |

**Pattern to copy:** the two Plex/Jellyfin TV clients that care about ASS (Plezy, Wholphin) both ship *two* engines and make users choose. Our contract avoids that by choosing per file inside one engine (see §4 and §6).

## 3. What the platform itself already does

- **HDR → SDR panel:** Android's compositor tone-maps HDR to the display (libtonemap since 13; LUT-based on 16) — quality is vendor-defined. [AOSP tone-mapping page]
- **Frame-rate:** `Surface.setFrameRate()` tells the system the content rate; Android TV docs recommend it (and signal for non-seamless switches). `Display.Mode` switching is the older route. [Android TV "Match content frame rate"]
- **Tunnelling:** decoder and audio sync below the app; can give better cadence, but loses GPU effects (PiP blur/corners) and varies by OEM. [AOSP tunnelling page]
- **DV:** apps must check decoder profile support; a DV track may need an HDR-capable decoder not exposed up front — read codec-specific data. [AOSP HDR page]

## 4. Ranked feature candidates

Ranking = value to Nitin's library (MKV remuxes, anime, Plex/Stash) × confidence ÷ effort. Each row says: what · who · how on Media3 · hardware · effort · licence · device.

| # | Feature | Who does it | Native Media3 route for our contract | Hardware | Eff. | Licence / credit | Helps |
|---|---|---|---|---|---|---|---|
| 1 | **DV P7 handling** — play P7 remuxes as HDR10 base layer; later rewrite to P8.1 | Just Player ("P7 as HDR HEVC"); Kodi (rewrite); 1.12-beta01 adds an **H.265 decoder fallback for backward-compatible DV P7** (#3486) | Step 1: move to Media3 1.12 stable, let the ladder pick HEVC decoder for P7 (never claim DV on screen). Step 2 (stage 5): native module rewrites RPU P7→8.1 on the fly with `libdovi` and feeds a P8 stream to the DV decoder | HW HEVC/DV decoder | S + L | `dovi_tool` MIT (credit) | Pad (needs DV-capable path ⚠), Onn (2026 box has **no P7**, so step 1 is the whole story) |
| 2 | **ASS/SSA via libass** with embedded fonts | Next Player (GPL, no code), Jellyfin TV (experimental), mpv, Wholphin | Use MIT `libass-android` (`ass-media` Media3 extension) or build libass (ISC). Default to the **bitmap-cue render mode**; pick mode per device after test (Shield reports only legacy works) | CPU raster → GPU texture | M | libass ISC, libass-android MIT — attribute in NOTICE | Both; anime is the main driver |
| 3 | **Frame-rate matching** | Just Player, Jellyfin TV, Wholphin, Kodi | Use the **container frame rate from our probe** (no sample sniffing — Just Player's 1000-sample read costs 10-20 s, #632). Call `Surface.setFrameRate` (+ `setVideoChangeFrameRateStrategy`); on Onn also try explicit mode switch. Re-test audio after the switch | Display / HDMI | S | Idea only; credit Just Player issue | Onn most; Pad has VRR panel |
| 4 | **Software decoders as fallback** (AV1 dav1d, FFmpeg audio, optional FFmpeg video) | Media3 ext (dav1d, since 1.9), NextLib (GPL FFmpeg video ext) | Build `decoder_av1` (dav1d) and `decoder_ffmpeg` audio ext into our AAR; register them **after** hardware in `DefaultRenderersFactory`. **Effects (`setVideoEffects`) do not work with extension video renderers**, so the ladder must drop rungs `scale`/`shader` when SW decode is chosen. Skip FFmpeg *video* (GPL/LGPL packaging, slow on Onn) | CPU (Onn: 4× A55 ⚠ weak) | M | dav1d BSD-2, FFmpeg LGPL (dynamic only) ⚠ | Pad (AV1/odd codecs); Onn only for 1080p AV1 at best ⚠ |
| 5 | **Subtitle cost control** (PGS/DVB, many tracks) | — (Media3 gap) | Media3 #2667: an MKV with 28 bitmap sub tracks stutters on **Onn & Fire stick**, not on Shield. Parse **only the selected** subtitle track; set our own subtitle `TrackSelection` policy; avoid sidecar-bitmap decode until selected | CPU | S-M | — | Onn |
| 6 | **Scrubbing + thumbnails** | Media3 1.8 (`setScrubbingModeEnabled`), Wholphin (trickplay) | Enable scrubbing mode while seek-bar dragged (coalesced seeks, audio off, higher codec rate). Thumbnails: Plex BIF / Stash sprite sheets first; fall back to `FrameExtractor` (`media3-inspector-frame`) on a **second** player | HW decoder | S-M | Apache | Both; Onn needs sprites (extractor is slow ⚠) |
| 7 | **Preload / prewarm** | Media3 `DefaultPreloadManager`, `PlayerPool` (1.11) | Next episode: preload manager with `SimpleRankingDataComparator`; keep a pooled second player to prewarm codec; set `setPlayerTargetBufferBytes` to cap RAM on Onn (3 GB) | RAM, net | M | Apache | Both |
| 8 | **Audio passthrough & Atmos** | Just Player, Kodi, Jellyfin TV | `AudioCapabilities` per route; allow E-AC3(+JOC) bitstream, TrueHD/DTS-HD only if the sink reports it (2026 Onn does **not** pass lossless). Known traps: **PCM-only after refresh switch** (#2258), **~2 s audible gap after every seek with direct audio** on Amlogic S905X5M (#3522, open; same SoC family as the Onn ⚠), **TrueHD Atmos + tunnelling + FFmpeg renderer = unsupported** (Just Player #585). Release 1.12-beta01 fixes a DTS-HD AudioTrack retry (#3487) | HDMI sink / DSP | M | Apache | Onn, Pad via USB-C DAC ⚠ |
| 9 | **HDR → SDR tone mapping** | Platform compositor; Media3 `DefaultVideoFrameProcessor` (GL) | Prefer **platform** path (SurfaceView, no effects) — cheapest, zero-copy. If a user needs consistency, use GL tone-map through `setVideoEffects` (maintainer says possible, ~77 lines of setup, #826; a dedicated `ToneMapToSdrEffect` ⚠ not confirmed shipped). Keep server transcode (D10) for boxes whose compositor looks wrong | HW decoder + GPU | M | Apache | Pad outdoors; Onn on SDR TVs |
| 10 | **Tunnelled playback** | Just Player (toggle), Stremio (forced; hard to turn off, #2444) | Per-device **opt-in**, default off. Known bugs: seek-to-end never ends (#1574), freeze on Google TV Streamer (#2972, device-specific), crash on early audio session id (#3099), no video-only tunnelling on codec2 (#2541). Cannot combine with effects | Decoder → HDMI | S | Apache | Onn if 4K60 judders ⚠ |
| 11 | **GL upscaling (`scale` rung)** | Snapdragon GSR 1 (**BSD-3**), FSR 1 (**MIT**) | Implement as a `GlEffect` in `media3-effect`; one pass, source→display resolution; only when source < ~0.75× panel and not HDR-tunnelled. GSR is tuned for Adreno (Pad); on Onn's Mali use FSR-style or plain Lanczos | GPU (Adreno 830 / Mali) | M | GSR BSD-3 and FSR MIT: keep headers, credit in NOTICE | Pad; Onn limited ⚠ |
| 12 | **Shader rung (Anime4K class)** | Anime4K (**MIT**), used in mpv-android/Aniyomi | Write a mini executor for the mpv user-shader subset (`//!HOOK/BIND/SAVE` passes, fragment only) as a `GlEffect` chain. Ship 2-3 curated presets (Fast/HQ), not a free-form config. Measure ms/frame on both devices before turning on | GPU | L | Anime4K MIT; **do not** reuse mpv/libplacebo code (LGPL) | Pad (anime library); Onn probably not ⚠ |
| 13 | **ML super-resolution on NPU** (`neural` rung) | Qualcomm AI Hub QuickSRNet (**BSD-3**), LiteRT QNN delegate | Spike only. Hands-on 2026 (SD 8 Gen 3, demo 4-layer model, unreviewed blog ⚠): 720p→1440p **9.3 ms**, 1080p→4K **24.8 ms** per frame on Hexagon V75 — plausible for 1080p→1440p. Missing pieces: getting decoded frames into the NPU without CPU copies (AHardwareBuffer/GL interop ⚠ untested), real quality models cost 3-6× more, heat/battery. QuickSRNet listed "not supported" on AI Hub's mobile chip list at time of search ⚠ | Hexagon NPU (Pad only; Onn has none) | L | QuickSRNet BSD-3; LiteRT Apache-2.0; Real-ESRGAN BSD-3 (too heavy ⚠) | Pad only |
| 14 | **Frame interpolation (RIFE)** — not requested, noted | RIFE-ncnn | GPU-only RIFE hit real time only at **320p** on SD 8 Gen 3 ⚠ same blog | GPU | — | MIT | Skip |
| 15 | **Deinterlacing** | mpv (yadif etc.), VLC | Android decoders usually output interlaced frames untouched ⚠. Detect interlace from probe; if rare, leave it. If needed, write a simple GL `bob/yadif-lite` effect | GPU | M | Idea only (no yadif code) | Neither (low demand) |
| 16 | **PiP + background audio** | Just Player, Media3 session | `MediaSessionService` for background; Activity PiP with `setAutoEnterEnabled`; pause effects in PiP; tunnelling loses PiP effects | — | S | Apache | Pad (PiP); Onn background audio |
| 17 | **Performance** — ADPF, load control, zero-copy | Media3 (dynamic scheduling default in 1.11), Android ADPF | Keep **SurfaceView direct path** when no effects (zero-copy); use `PerformanceHintManager` sessions for effect/subtitle threads (API 31+ ⚠ Onn Android 14); tune `DefaultLoadControl` (buffer bytes cap 50-80 MB on Onn; bigger on Pad) | CPU/GPU governor | S-M | Apache | Both |
| 18 | **Network robustness** | Media3 data sources (OkHttp / Ktor in 1.11 / Cronet) | One shared `DataSource.Factory` with our TLS hook; custom `LoadErrorHandlingPolicy` (more retries on Wi-Fi roam); `InitialBitrateSupplier` for Plex; resume from last byte; Matroska without Cues → fall back to byte-range scan ⚠ test | Net | S-M | Apache | Both |

### Notes on the hard ones

- **P7 on the Onn 2026 box:** it has no Profile 7 decoder. The 1.12 fallback plays the HDR10 base layer, which is good enough; P7→8.1 rewrite is only worth it on devices that *do* have a DV decoder but reject P7 (Pad ⚠ verify per-device).
- **ASS render modes** differ by device: use bitmap-cue mode by default (the only one reported working on Shield), keep a debug switch. Drop ASS drawings/positioning only on a per-track basis if rendering is too slow.
- **Software decode vs effects** is the main architectural trap: the moment the ladder picks a software decoder, GL rungs are unavailable. Reflect that in the routing table (RoutePlanner), not in UI.
- **Frame-rate switch can break audio** (PCM-only). After every mode change, re-query `AudioCapabilities` and rebuild the sink; test on Onn + the user's receiver.

## 5. Where realism ends

| Idea | Reality check |
|---|---|
| libmpv for everything | No HDR/DV output on Android; CPU copy path; drop rates at 4K; LGPL/GPL obligations |
| ML upscale on Onn | No NPU; weak Mali; stay on `off`/`scale` |
| ML upscale on Pad | Possible on paper (SD 8 Elite listed for LiteRT QNN); cost is in the glue (frame transfer, model conversion, thermal) |
| NNAPI | Deprecated — use LiteRT |
| FFmpeg video software decode on Onn | A55 cores cannot do 4K HEVC; 1080p H.264 only ⚠ |
| Full Anime4K "HQ" chain on Onn | Mali + 3 GB; expect drops ⚠ |
| Dolby Vision on-screen from our own tone-mapping | We cannot produce DV; we can pass P5/P8 to the system decoder and pass the base layer for P7 |

## 6. Recommended stage 2-5 plan (maps to PLATFORMS.md)

| Stage | Add from this research | Gate |
|---|---|---|
| **1** (probe, route, fixtures) | Add fixtures: DV P7 remux, MKV with 28 bitmap subs, ASS with fonts, 23.976/24/25 fps clips, TrueHD/E-AC3-JOC. Probe records container frame rate and interlace flag | Fixtures play on Pad |
| **2** (hardware snapshot, DV/HDR rules, ladder, Onn joins) | Pin **1.12 stable when released** (beta now); P7 → HEVC fallback rule; ladder rule "software decode ⇒ no GL rungs"; `scale` rung capability flag per GPU; tunnelling opt-in flag (default off) | Onn route matrix filled |
| **3** (audio policy, subs, PiP, passthrough, frame-rate) | libass (MIT wrapper) with bitmap-cue default; bitmap-sub on-demand parsing; frame-rate from probe + `setFrameRate`; audio rebuild after mode change; passthrough/seek-gap test on Onn; PiP/background session | Passthrough + seek test on Onn receiver |
| **4** (prewarm, TLS, frame extractor, scrub, enhance scale/shader) | `DefaultPreloadManager` + `PlayerPool`; `FrameExtractor` second player; scrubbing mode; GSR/FSR `scale` GlEffect; 2 Anime4K-class presets via shader executor; ADPF sessions | ms/frame budget per device |
| **5** (shared native module, neural spike, Transformer, AVI remux) | `libdovi` P7→8.1 rewrite in the shared module; `neural` spike on Pad with LiteRT QNN (1080p→1440p, thermal log); Transformer-based tone-map/export if needed | Spike report, go/no-go |

## 7. What NOT to do

| Don't | Why |
|---|---|
| Embed libmpv/libVLC as the core engine | HDR/DV gap, CPU copies on TV boxes, LGPL/GPL packaging, not a supported library (mpv-android README) |
| Copy NextLib, Next Player, Plezy, Jellyfin, Wholphin, Kodi code | GPL — we may not embed; this report read none |
| Ship FFmpeg *video* decoding by default | Slow on Onn; licence/packaging risk; effects stop working |
| Turn on tunnelling globally | Device-specific freezes, no effects, Stremio users cannot undo it |
| Sniff 1000 samples for frame rate | 10-20 s delay (Just Player #632) |
| Assume DV P7 plays DV on screen | Even the 2026 Onn lacks it; show it as HDR10 and say so in the route summary |
| Add a user-facing "pick your player" switch | Plezy/Wholphin do this because they lack per-file routing; ours is automatic |
| Rely on NNAPI or an unreviewed NPU demo for the roadmap | Deprecated / single-blog numbers; keep as an opt-in spike |
| Parse every subtitle track up front | Onn/Fire stutter (#2667) |
| Build a custom renderer or surface pipeline | Media3 gets fixes from Google every release; we'd own all device bugs |

## 8. Credits and sources

**Adaptable (permissive):** Just Player (Unlicense) — behaviour ideas; libass (ISC); libass-android (MIT); dovi_tool/hdr10plus_tool (MIT); Anime4K (MIT); Snapdragon GSR (BSD-3-Clause, checked LICENSE); FSR 1 (MIT, per PLATFORMS [X5]); Arm ASR (MIT, SPDX header, temporal/game-oriented, not for video ⚠); Qualcomm AI Hub models (BSD-3); LiteRT (Apache-2.0).

**Sources (existing tags M/A/X/O from PLATFORMS.md remain valid):**
- Media3 release notes: https://github.com/androidx/media/blob/release/RELEASENOTES.md · 1.11: https://android-developers.googleblog.com/2026/08/media3-1-11-whats-new.html · 1.10: https://android-developers.googleblog.com/2026/03/media3-110-is-out.html · releases page: https://developer.android.com/jetpack/androidx/releases/media3
- Scrubbing: https://developer.android.com/media/media3/exoplayer/scrubbing
- Media3 issues: #826 tone-map, #1865 P7→8.1, #2258 PCM on refresh switch, #3486 P7 fallback, #3487 DTS-HD retry, #3522 passthrough seek gap, #2667 many bitmap subs, #1574/#2972/#3099/#2541 tunnelling
- AOSP: HDR https://source.android.com/docs/core/display/hdr · tone mapping https://source.android.com/docs/core/display/tone-mapping · tunnelling https://source.android.com/docs/devices/tv/multimedia-tunneling
- Android TV match frame rate: https://developer.android.com/training/tv/playback/adjust-display-settings
- Players: https://github.com/moneytoo/Player (#439/#574/#585/#632) · https://github.com/anilbeesetti/nextlib · https://github.com/mpv-android/mpv-android (#874/#717/#1081/#1137/#1320) · https://github.com/edde746/plezy (#685) · https://github.com/peerless2012/libass-android · https://github.com/libass/libass · jellyfin-androidtv #3173/#4067/#4630 · Wholphin #244/#1049 · NuvioTV #204 · Stremio bugs #2402/#2444
- Shaders/upscaling: https://github.com/bloc97/Anime4K (+ issue #99) · https://github.com/SnapdragonStudios/snapdragon-gsr · https://github.com/arm/accuracy-super-resolution-generic-library
- NPU: https://ai.google.dev/edge/litert/android/npu/qualcomm · https://github.com/quic/ai-hub-models · hands-on (single blog, SD 8 Gen 3): https://muka.cool/android-realtime-sr-memc
- DV tooling: https://github.com/quietvoid/dovi_tool

**Not verified (⚠ roll-up):** Onn passthrough/seek gap (needs device test); Amlogic S905X5M ≈ Onn 2026 SoC (⚠ assumption from XDA/listing); VLC and Kodi issue claims from titles/snippets (GitLab blocked); Nova Video Player and Findroid current state; FFmpeg/dav1d licence terms in our packaging; ADPF on Onn; NPU frame transfer; any ms/frame number.
