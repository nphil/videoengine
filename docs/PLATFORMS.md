# Platform contract

What the engine does, stated without naming a platform, so a native Android side
(Kotlin on Media3/ExoPlayer and MediaCodec, Rust or C for shared hot paths) behaves
like the Apple side (Swift on AVPlayer, VideoToolbox and FFmpeg). Each section gives
the **rule**, the **Apple mechanism today** and the **Android mechanism proposed**.
Apple facts are checked against `Sources/` and [ENGINE.md](ENGINE.md) at `f3843bf`;
items marked *2.2.0* sit on unmerged branches (`lift-io`, `lift-remux`, `lift-audio`,
`pip-bitmap-subtitles`).

- Android claims link to the [sources](#sources). **⚠ = not verified against official
  documentation**; confirm in stage 1.
- Basis column: **E** = already the engine's rule; **P** = proposed here, needs the owner's OK.
- Contract version: **2.2** (the Apple release that carries every rule below).

## 1. Principles

1. **Native per platform, one repo.** Swift on Apple, Kotlin on Android, no cross-platform
   runtime. Each side uses its own player, decoders, network stack, trust store and
   thermal and power APIs.
2. **Shared:** this contract, test fixtures, golden decision vectors, the FFmpeg version and
   licence set, API names, the diagnostics line format, error names. **Not shared:** player
   glue, the loopback HLS server (Apple only), HTTP stack, UI.
3. **Native hot paths only where measured.** Rust or C enters a shared module for a proven
   cost or a bit-exact rewrite (Dolby Vision RPU, audio shaping), see D5.
4. **Never lie about hardware.** A `hardware` verdict that then fails to play is a bug (sheet H2).
5. Credentials travel as headers, never in URLs. No call blocks the caller's thread. A user
   cancel is the platform's cancellation, not an error.

## 2. The contract

### 2.1 Probe facts

Rule: one `MediaInfo` per source, in FFmpeg vocabulary on both sides. `ProbeDepth.quick`
reads stream info only when the header leaves the pixel format unknown, `.full` always;
timeout 8 s; cancelling cancels the source.

| Fact | Contract value | Apple (E) | Android |
|---|---|---|---|
| Container | FFmpeg demuxer name (`matroska,webm`, `mov,mp4,m4a,3gp,3g2,mj2`) | `avformat` | map from Media3 extractor or MIME via a table in `shared/vectors` ⚠ |
| Codec | FFmpeg codec name (`h264 hevc av1 vp9 eac3 truehd subrip hdmv_pgs_subtitle`) | `avcodec_get_name` | MIME to FFmpeg name, same vectors |
| Video | profile, pixel format, size, bit depth, transfer (`smpte2084`, `arib-std-b67`), primaries; cover art excluded | `VideoStreamInfo` | `Format` and `ColorInfo` via Media3 `MetadataRetriever` [M9]; FFmpeg only for what Media3 lacks (mastering display, light level) ⚠ |
| Dolby Vision | profile, level, compatibility id | `dvcC`/`dvvC`; `dolbyVisionFallback` from server data | codecs string (`dvhe.08.06`) and record from `Format` ⚠; same server fallback |
| Audio, subtitles | index, codec, language, title, default; subtitles add forced and `isBitmap` (PGS, DVB, VobSub) | `AudioStreamInfo`, `SubtitleStreamInfo` | `Tracks` and `Format` |

### 2.2 Route choice

Rule: a pure function of probe facts, decode verdicts and the hardware snapshot returns
`directPlay`, `repackage` or `serverTranscode` plus a reason code, logged as
`route=<r> reason=<code>`. Today it is an app duty on Apple (ENGINE.md, "Duties left to
the app"); D2 moves it into the engine so both platforms share one function and one set of
vectors. First match wins:

| # | Condition | Route | Reason | Basis |
|---|---|---|---|---|
| 1 | no playable audio or video stream | error `noPlayableStreams` | `no-streams` | E |
| 2 | pixel format outside 4:2:0 at 8 or 10 bit (4:2:2, 4:4:4, 12-bit, RGB), or codec verdict `unsupported` | `serverTranscode` | `unsupported-video` | E |
| 3 | HDR or Dolby Vision source, display not HDR-eligible | `serverTranscode` | `hdr-display-missing` | E |
| 4 | Dolby Vision profile 5 and no DV decoder and display | `serverTranscode` | `dv5-unsupported` | P |
| 5 | verdict `softwareOnly` above 1080p or 30 fps (thresholds to be measured) | `serverTranscode` | `software-decode-too-heavy` | P |
| 6 | no audio path (2.5) | `serverTranscode`: audio re-encoded, video copied | `audio-unplayable` | P |
| 7 | the platform player opens the container and codecs | `directPlay` | `ok` | E |
| 8 | container unreadable by the player, every selected stream copyable | `repackage` | `container-unreadable` | E |
| 9 | `repackage` while external playback is active (AirPlay cannot reach the loopback URL, S9) | `serverTranscode` | `external-playback` | E |
| 10 | anything else | `serverTranscode` | `fallback` | E |

| Route | Apple | Android |
|---|---|---|
| `directPlay` | MP4, MOV, HLS with H.264/HEVC and playable audio | everything Media3 reads, **including Matroska and WebM**, also MPEG-TS, MPEG-PS, FLV, Ogg [M1] |
| `repackage` | `RemuxSession`: fragmented MP4 served as HLS on 127.0.0.1 | **not needed for Matroska.** Only AVI, ASF/WMV, RealMedia, absent from Media3's list [M1]; stages 1 to 4 send them to the server (D8) |
| `serverTranscode` | the media server | same |

### 2.3 Video: codec by hardware verdict

Rule: `DecodeVerdict` is `hardware`, `softwareOnly`, `unsupported` or `unknown` (simulator,
emulator). Cached per codec, profile, level, size class (`sd 720 1080 1440 2160 4320`) and
bit depth until the OS or device changes (stamp: OS version + machine on Apple, `Build.FINGERPRINT`
on Android ⚠); one `hw-probe` line per probe. `hardware` must rest on evidence, not a flag.

| Stream | Apple mechanism (E) | Android mechanism (P) |
|---|---|---|
| Verdict source | `VTIsHardwareDecodeSupported`, then a `VTDecompressionSession` that requires hardware and reads `UsingHardwareAcceleratedVideoDecoder` | `MediaCodecList.findDecoderForFormat`, `isHardwareAccelerated`, `areSizeAndRateSupported`, `getSupportedPerformancePoints` (API 29) [A1][A2]. The hardware flag is manufacturer-provided and **cannot be tested for correctness** [A1], so first frame is the proof (H2); a trial `configure` is stage 2 ⚠ |
| H.264 4:2:0; HEVC Main, Main10 | hardware | hardware on nearly all devices ⚠; HDR10 profile constants exist (`HEVCProfileMain10HDR10`, `...HDR10Plus`) [A1] |
| AV1 | hardware only A17 Pro / M3 and newer, else server (H3) | hardware on newer SoCs; software via the AV1 decoder extension (an app build step) [M1] |
| VP9, MPEG-2, VC-1, Hi10P H.264 | per probe (H2) | per probe; Media3 prefers a decoder that supports the **profile**, even a software one [M1] |
| 4:2:2, 4:4:4, 12-bit | transcode | transcode unless a decoder lists the profile ⚠ |

`HardwareCapabilities` is one immutable snapshot per playback start, `changes()` a stream:

| Group | Apple | Android |
|---|---|---|
| decode, encode | VideoToolbox | `MediaCodecList` |
| `display.hdrPlaybackEligible` | `AVPlayer.eligibleForHDRPlayback` | `Display.isHdr()`, `Display.Mode.getSupportedHdrTypes()` (API 34), `Display.HdrCapabilities` below [A3] |
| `display.maxFramesPerSecond`, `wideGamut` | `UIScreen` | `Display.getSupportedModes()`, `isWideColorGamut()` [A3] |
| `edrHeadroom*`, `capturing`, `externalPlaybackActive` | EDR, `sceneCaptureState`, AirPlay | no equivalent for the first two (report 1.0, false); external: `MediaRouter` ⚠ |
| `compute`, `engine` | cores, RAM, Metal 3; FFmpeg, dav1d, VT hwaccel | `availableProcessors`, `ActivityManager.MemoryInfo`, Vulkan level ⚠; FFmpeg, extensions present |

### 2.4 HDR and Dolby Vision, per profile

Rule: never show a wrong picture. Where a Dolby Vision layer cannot be decoded, play the HDR10
or HLG base layer; with no base layer (profile 5) or no HDR display, go to the server.
Dynamic range is declared up front (`VIDEO-RANGE` `SDR`, `PQ`, `HLG`).

| Source | Contract | Apple today | Android proposed |
|---|---|---|---|
| HDR10, HDR10+, HLG, HDR display | plays HDR (HDR10+ as HDR10 where no dynamic-metadata decoder) | `hvc1`, `colr` 9/16/9 or 9/18/9, `mdcv`, `clli` kept | platform decoder and HDR display path [M1][A3] |
| any HDR, display not HDR | server transcode | rule 3 | same. Playback tone mapping on an SDR panel is **not documented** ⚠; Media3 tone-mapping docs cover export only [M13] |
| DV profile 5 | Dolby Vision only, colours unspecified | `dvh1`, record kept or added from fallback, `write_colr` | needs a P5 decoder (`DolbyVisionProfileDvheStn`) and DV display; no base layer, so server (rule 4) [M3] |
| DV profile 7, MEL or FEL | HDR10 base layer by default | `dovi_rpu` strips RPU and enhancement layer; dual-track copies base only | Media3 falls back to a plain HEVC decoder for backward-compatible P7 from 1.12.0-beta01 (P8 already) [M2][M3]. **Before that, P7 went to a P5 decoder and looked grey and washed out** on DV TVs without a P7 decoder [M3] |
| DV profile 7 as 8.1 (*2.2.0*, opt-in) | drop enhancement layer, rewrite RPUs (NLQ removed, CRC-32 redone) | `DolbyVisionRPU`, checked byte for byte against `dovi_tool` | needs sample rewrite before the decoder: shared native module, stage 5 ⚠ feasible inside a Media3 extractor wrapper |
| DV profile 8.1, 8.4 | Dolby Vision, HDR10 or HLG fallback; `baseLayerOnly` forces the base | `hvc1` + `dvvC`, `SUPPLEMENTAL-CODECS` | DV decoder if present, else HEVC base layer [M3] |
| other DV (AVC, AV1 P10, 4, 9) | drop the record, play the base layer | `drop` | P10 known to Media3; unsupported profiles are rejected rather than played as HEVC [M2] ⚠ per release |

`DvheStn` = P5 and `DvheDtb` = P7 are confirmed by [M3]; other profile-to-constant mappings ⚠.

### 2.5 Audio policy

Rule: play the viewer's pick (`preferredIndex`, else default, else first). Keep the bitstream
when the output can take it, else convert as little as possible. Channels shrink only by a
documented mix-down. Lip sync within 40 ms (T1).

| Source | Apple (E) | Android (P) |
|---|---|---|
| AAC-LC, HE-AAC explicit SBR; AAC with program config or implicit SBR | copy; the latter re-encoded (unproven) | platform decoder; PCE and implicit SBR ⚠ test |
| AC-3, E-AC-3 5.1 or JOC | copy (`delay_moov`); JOC keeps Atmos on AirPods (T2) | passthrough if `isPassthroughPlaybackSupported` [M4], else platform decoder, else FFmpeg extension [M1]; JOC kept only if the sink supports it ⚠ |
| E-AC-3 above 5.1 | 5.1 core (`eac3_core`): the MP4 muxer cannot describe 7.1 | passthrough carries the whole stream (**an Apple muxer limit, not a contract rule**) |
| FLAC, ALAC | copy up to stereo, 96 kHz, 24 bit, else re-encode | any decoder, no limit |
| TrueHD, DTS, DTS-HD | decode, mix to 5.1(side), AAC 384 kbit/s, or E-AC-3 640 kbit/s with `surroundCodec = .eac3` (*2.2.0*) | passthrough on TV or receiver, else FFmpeg extension (`dca truehd mlp`) [M1] |
| Opus, Vorbis, MP3, MP2 | decode, AAC 192 kbit/s stereo | platform decoder |
| `shaping` (*2.2.0*): delay up to 2 s either way, dialogue lift 0 to 12 dB, night mode | forces re-encode | custom `AudioProcessor` on PCM; **forces decode, disables passthrough and offload** (offload limits effects [M6]) |

No on-device AAC re-encode on Android: there is no HLS muxer to satisfy. Rule 6 of 2.2 applies
when no passthrough, platform decoder or FFmpeg decoder exists.

### 2.6 Subtitles

Rule: text subtitles are timed cues on the movie timeline, within 100 ms of mpv (S1) and right
within 0.5 s after any seek (S2). Picture subtitles keep pixels and canvas size. Names,
languages, default and forced flags are listed as the container states them.

| Kind | Apple today | Android proposed |
|---|---|---|
| SRT, ASS/SSA, WebVTT, mov_text in the file | WebVTT renditions, fixed 10 s slots; ASS keeps italics and bold, drops positioning and drawings (S5) | Media3 parses SubRip, SSA, WebVTT, TTML [M1][M12]; richer ASS is allowed, never less than Apple |
| Sidecar `.srt .vtt .ass .ssa .smi .sup` | `SubtitleFile.read(fileURL:forcedOnly:)` | `MediaItem.SubtitleConfiguration` for srt, vtt, ssa, ttml [M1]; `.smi`, `.sup` via a shared parser ⚠ |
| PGS, VobSub, DVB | decode to straight RGBA `SubtitleBitmap` with canvas size; the app draws `overlay.bitmaps(at:)`; never muxed | `PgsParser`, `DvbParser`, `VobsubParser` exist [M12], bitmaps draw in `SubtitleView`; **that each reaches the renderer from Matroska is ⚠** (S6, S7) |
| Survive Picture in Picture and external playback | AVPlayer draws only playlist text, so overlays vanish; `bitmapSubtitleText` (*2.2.0*, off by default) adds a WebVTT rendition "<name> (text from picture)" read by Vision OCR | PiP shows the activity's own views [A6], so `SubtitleView` should survive: **expected, ⚠ test S4 and S6**. No OCR feature. Cast out of scope |

### 2.7 Seeking and reuse

| Rule | Apple (E) | Android (P) |
|---|---|---|
| Landing within 0.5 s of the target; shown time = movie time (P2) | each run starts at its keyframe `origin`; app shows `t + origin`, seeks to `target - origin` | native seek, `origin` always 0; default `SeekParameters` is exact [M7][M9] |
| A seek into what is already produced restarts nothing (`seekReusing(to:)`, *2.2.0*: target inside the sealed duration, else a new run) | needed: a remux run is a one-way file | inherent (seek by Cues); keep a back buffer ⚠ |
| Scrubbing responsive | cancel and start a new run | `setScrubbingModeEnabled(true)` while dragging [M7] |
| First frame within one keyframe interval (P1), Cues at end or none | reads the index with ranged requests | Matroska without Cues: **⚠ test**; if not seekable, server |

`PaceGate`, `updatePlayhead` and `setPlayerWaiting` exist only to keep AVPlayer's live
playlist fed; they have no Android counterpart.

### 2.8 Prewarm (*2.2.0*)

Rule: `prewarm(url, headers, byteBudget)` fetches the head of an `http(s)` file before play.
Key = URL plus headers exactly as sent (names case-insensitive, values exact). Default 2 MiB,
at most 16 MiB, one `Range` request. The first source made for the key adopts the bytes (length
and reads inside them cost no request). Dropped when taken, after 3 minutes, under memory
pressure; at most 8 files; `discardAll()` on leaving a screen; returns true only if bytes are held.

| Apple (*lift-io*) | Android proposed |
|---|---|
| in-memory head bytes | `DefaultPreloadManager` / `PreloadMediaSource`: preloads to the sample queue, then hands the source to the player [M10]; use when a title is highlighted |
| key URL + headers | a `SimpleCache` key is URL-only by default ⚠: supply a key that includes the auth identity so a changed token never reuses bytes |
| memory pressure | `ComponentCallbacks2.onTrimMemory` releases the manager ⚠ |

### 2.9 TLS trust (*2.2.0*)

Rule: system trust by default. An optional process-wide hook `serverTrustEvaluator(host, trust) ->
Boolean` accepts a self-signed or private-CA media server the user approved; `true` accepts,
`false` ends the connection, it is asked for every host (always `true` turns checking off), set
before the first request, and covers sources, prewarm, probe and frame extraction alike.

| Apple (*lift-io*) | Android proposed |
|---|---|
| `EngineTLS.serverTrustEvaluator` on the engine's URLSessions | Known private CA: Network Security Config `domain-config` with `trust-anchors` [A5]. User-approved server at run time: one shared `OkHttpClient` with a custom `X509TrustManager`, used by `OkHttpDataSource.Factory` [M11] for playback, prewarm, probe and `FrameExtractor`. Apps targeting API 24+ do **not** trust user-added CAs by default [A5]. Compare host and leaf SHA-256; system check for every other host |

### 2.10 Frame extraction

Rule: one still picture, from the keyframe at or before the time, never later; reads through its
**own** source (same URL and headers as playback, never playback's object); calls run one at a
time on a low-priority queue; one extractor per video, kept open; cancellation drops queued work and
fails the read in flight; 30 s without progress is `timedOut` (outage time excluded); a keyframe
within 64 MiB; at most 3840 wide and 3840 x 2160, never enlarged; sources above 8192 x 4608 refused;
result carries `actualSeconds` and `bytesRead`.

| | Apple (E, v2.1.0) | Android (P) |
|---|---|---|
| Mechanism | FFmpeg demux; VideoToolbox or FFmpeg decode | Media3 `FrameExtractor` (`media3-inspector-frame`, `@UnstableApi`): `getFrame(positionMs)` gives a `ListenableFuture<Frame>` (`bitmap`, `presentationTimeMs`); builder has `setSeekParameters`, `setEffects`, `setMediaSourceFactory`, `setMediaCodecSelector` [M9] |
| Keyframe at or before | native | default seek is exact and decodes forward from the previous keyframe; set a sync-based `SeekParameters` (`PREVIOUS_SYNC` ⚠ confirm accepted) |
| Downscale, own source | `maxWidth`; `ByteRangeSources.make` | `Presentation` effect; separate `DataSource.Factory` on the shared OkHttp client [M9] |
| HDR | flat SDR, **not** tone-mapped; DV P5 colours wrong | HLG `Bitmap` (API 34, `setExtractHdrFrames`); washed colours possible outside CTS-covered inputs [M9]. Callers must not assume tone mapping on either side |
| Threading, fallback | own queue; none | one application thread [M9]; platform `MediaMetadataRetriever` |

### 2.11 Diagnostics and errors

Rule: a logger the app supplies, plus a ring of the last 100 measured lines, `tag key=value ...`, from
`EngineDiagnostics.report()`, with the same tags and keys on both platforms so one support screen and
one parser serve both: `hw-id` (`machine` is `Build.MODEL` on Android), `hw-cpu`, `hw-gpu`, `hw-dec`
and `hw-enc` (`hw sw no ?`), `hw-disp`, `hw-pwr`, `hw-aud`, `hw-eng`, `hw-state` on change, `hw-probe`
(`codec prof lvl wh bits verdict err ms`), `perf-remux` and `perf-run` (Apple), `perf-play`
(`open first_sample first_frame ms`, Android), `route` (new). Apple stages are `os_signpost`
intervals (subsystem `VideoEngine`, category `stages`); Android uses `android.os.Trace` sections of
the same names ⚠. Errors mirror `VideoEngineError`: `sourceUnreachable(status)`, `unsupportedSource`,
`openFailed`, `noPlayableStreams`, `headerFailed`, `readFailed`, `writeFailed`, `decoderUnavailable`,
`encoderUnavailable`, `audioNotCopyable`, `timedOut`, `serverBindFailed` (Apple only), `ffmpeg`. A failed
read is never reported as end of file.

### 2.12 Power and heat

Rule: `shouldShedOptionalWork` is true at thermal `serious` or worse, or in the system low-power mode;
optional work (enhancement, interpolation, prefetch beyond the minimum, thumbnails) stops. No permanent
pixel read-back: attach one only for a feature that needs pixels, remove it on pause, in the background
and from `fair` heat (a 4K 32BGRA copy is about 33 MB a frame). A 10-minute 4K play stays at or below
`fair` (P3).

| Contract | Apple | Android [A4] |
|---|---|---|
| `nominal`, `fair`, `serious`, `critical` | `ProcessInfo.thermalState` | `NONE`; `LIGHT` and `MODERATE` (P); `SEVERE`; `CRITICAL`, `EMERGENCY`, `SHUTDOWN` |
| read, observe | `thermalState`, `isLowPowerModeEnabled`, notifications | `PowerManager.getCurrentThermalStatus()`, `addThermalStatusListener` (API 29), `isPowerSaveMode()`; `getThermalHeadroom` optional ⚠ |

## 3. Where Android differs

**Stronger**
- **Matroska and WebM read natively** [M1]: no remux, temp file, loopback listener, pacing, timeline origin or suspended-socket recovery.
- **Picture subtitles** draw in the player's own view; no OCR copy.
- **GL video effects** on the decoded stream, `setVideoEffects` [M7], also inside `FrameExtractor` [M9].
- **Audio on TV**: passthrough of AC-3, E-AC-3, DTS, TrueHD [M4]; compressed audio offload [M5][M6].
- **Display refresh matching**: `setVideoChangeFrameRateStrategy` drives `Surface.setFrameRate` [M7][M8]; may need a mode-switch UX.
- **Tunnelled playback**: `setTunnelingEnabled(true)` moves decode and release timing to a dedicated processor on some TVs; device-specific, test per device [M5][M6].
- **Preload, caching, decoder extensions** (AV1, VP9, FLAC, Opus, FFmpeg audio) [M1][M10].

**Weaker**
- **Per-device Dolby Vision and HDR**: decoder lists differ by SoC and firmware (a TV with no P7 decoder mis-routed P7 [M3]); no single `eligibleForHDRPlayback`.
- **Hardware flag is self-reported** [A1]; emulators carry no representative hardware codecs ⚠, so device sheets stay manual.
- **`@UnstableApi`** on inspector, effects, preload: pin the version (D4).
- **No AVI, ASF/WMV, RealMedia** [M1]; no AirPlay (Cast is separate work).
- **Native code** must be 16 KB page-aligned for Play; NDK r28 or newer does it by default [A7].

## 4. Repository layout, fixtures, versioning, CI

### Layout (additive, nothing moves)

```
Package.swift  Sources/  Tests/  scripts/  .github/   unchanged, repo root
docs/ENGINE.md  docs/PLATFORMS.md  docs/ANDROID.md (stage 1)
android/                Gradle: :engine (Kotlin), :native (NDK, optional), :sample
shared/fixtures/        media + manifest.json (expected probe, route, audio plan, cue times)
shared/vectors/         JSON golden vectors for the pure functions
scripts/android/        build-ffmpeg.sh (LGPL .so per ABI), verify scripts
```

SwiftPM constraint: a package consumed by URL needs `Package.swift` at the repo root, and it is
**generated** (`scripts/gen-package-swift.sh`). Published tags (`v1.4.0` to `v2.1.0`) point at
immutable commits holding their own tree, so no later move can break them. Still, do not move
`Sources/` or `Tests/`: it needs `path:` entries in the generator and edits to `package-sources.sh`,
`release.sh` and three workflows, for no behavioural gain (D1). New top-level folders do not affect
SwiftPM, which reads `Sources/*` and `Tests/*`.

### Fixtures and vectors

Existing: `Tests/VideoEngineTests/Fixtures/` (`h264-aac.mkv`, `h264-aac-60s.mkv`, `hevc10-opus-srt.mkv`);
keep them, and let Android read them there (`sourceSets.androidTest.assets.srcDir`). New 1 to 3 s clips go
to `shared/fixtures/`, each in `manifest.json` with expected facts, route per device profile, audio action
and cue times:

| Clip | Covers |
|---|---|
| HDR10 MKV and MP4, HLG MKV; DV P5, P7 MEL, P7 FEL, P8.1, P8.4 | F1 to F11 (DV sources need `dovi_tool`-built clips, **to be sourced**) |
| AC-3 5.1, E-AC-3 JOC and 7.1, TrueHD, DTS, 24-bit FLAC, Opus, AAC with PCE | T1 to T9, one tone per channel |
| SRT en/fr plus forced, styled ASS, PGS 1080p on 2160p, VobSub with and without palette | S1, S5 to S8 |
| 4:2:2, 4:4:4, 12-bit, Hi10P, VP9, AV1 10-bit, MPEG-2; MKV with Cues at end and none | route rule 2, H2, P1 |

Vectors are pure and run in `swift test` (through `@testable`) and in Gradle JVM tests, no device:
`AudioPlan.decide`, `MuxPlan.decide`, `isPlayableAAC` configs, the route planner, the thermal mapping, cache-key
size classes, subtitle cue parsing, the `hw-*` line grammar. A rule change edits the contract and its vector
in one commit and both platforms must pass before merge.

### Versioning

- **Contract:** `2.2` above; major = a rule both sides must follow differently, minor = additive.
- **Apple:** `vX.Y.Z` tags as today (SwiftPM needs semver); additive is a minor.
- **Android:** `android-vX.Y.Z` tags. SwiftPM resolves semver tags, so these should be ignored by Apple consumers ⚠: prove with `swift package resolve` before the first tag.
- **Pairing:** release notes on both sides name the contract version; `MAJOR.MINOR` match, patch independent. Apps pin exactly (Apple `exactVersion`; Android one version in the version catalog).

### CI for Android

Runner: **`ubuntu-latest`** (GitHub-hosted, this repo is public). It has the Android SDK, CMake and NDK 27.3 as
default with 29 and 30 installed [G1]: use NDK 29 or newer for 16 KB alignment [A7]. No `xcode-27` runner is
involved. Use `paths:` filters: `android/**` never triggers the Apple FFmpeg build; `shared/**` triggers both.

| Job | What |
|---|---|
| `android-unit` | Gradle JVM tests including vectors, lint |
| `android-ffmpeg` | `scripts/android/build-ffmpeg.sh`: same FFmpeg tag and LGPL configure, **shared** `.so` (LGPL-friendly), `arm64-v8a` plus `x86_64` for the emulator; cached |
| `android-sample` | assemble the sample APK, upload it |
| `android-emu` | emulator smoke on KVM (needs the udev rule on 2-vCPU runners [G2]); probe and route vectors only, **no hardware verdicts** |
| manual | real-device sheets (phone, TV box): P1 to P4, H1 to H4, F1 to F12, T1 to T9, S1 to S10 |

## 5. Android API sketch (Kotlin, mirrors the Swift names)

Package `com.nphil.videoengine` (placeholder, D9). Coroutines replace `async` and `AsyncStream`; coroutine
cancellation replaces `CancellationError`; the Media3 player stays on its application thread.

```kotlin
data class MediaInfo(val container: String, val duration: Double?, val bitRate: Int?,
    val video: List<VideoStreamInfo>, val audio: List<AudioStreamInfo>, val subtitles: List<SubtitleStreamInfo>)
object MediaProbe { suspend fun probe(url: Uri, headers: Map<String, String> = emptyMap(),
    depth: ProbeDepth = ProbeDepth.Quick, timeoutSeconds: Double = 8.0, logger: EngineLogger = EngineLogger.Silent): MediaInfo }

enum class DecodeVerdict { Hardware, SoftwareOnly, Unsupported, Unknown }
interface HardwareCapabilityProvider {
    suspend fun snapshot(): HardwareCapabilities
    suspend fun decodeVerdict(stream: VideoStreamFacts): DecodeVerdict
    fun changes(): Flow<HardwareCapabilities>
}
class LiveHardwareCapabilityProvider(context: Context) : HardwareCapabilityProvider
enum class Route { DirectPlay, Repackage, ServerTranscode }
data class RouteDecision(val route: Route, val reason: String)
object RoutePlanner { fun decide(info: MediaInfo, caps: HardwareCapabilities, verdicts: Map<Int, DecodeVerdict>): RouteDecision }

class PlaybackOptions(val audio: AudioPolicy = AudioPolicy(), val dolbyVision: DolbyVisionMode = DolbyVisionMode.Automatic,
    val dolbyVisionFallback: DolbyVisionConfiguration? = null, val sidecarSubtitles: List<SidecarSubtitles> = emptyList(),
    val matchFrameRate: Boolean = true, val tunneling: Boolean = false)   // Apple-only options are absent, not ignored
class PlaybackSession(context: Context, sourceFactory: () -> DataSource.Factory, options: PlaybackOptions, logger: EngineLogger) {
    val player: ExoPlayer                    // owned by the engine, handed to the app's PlayerView
    val events: Flow<PlaybackEvent>          // Opened, Timeline(origin = 0.0), Progress, Finished, Failed, Stopped
    val subtitleStreams: List<SubtitleStream>
    suspend fun start(at: Double = 0.0)
    suspend fun seekReusing(to: Double): SeekResult
    fun stop()
}
data class AudioPolicy(val preferredIndex: Int? = null, val copyable: Set<String> = PROVEN_COPYABLE /* passthrough set */,
    val surroundCodec: SurroundCodec = SurroundCodec.Aac, val shaping: AudioShaping? = null)

object EnginePrewarm { suspend fun prewarm(url: Uri, headers: Map<String, String>, byteBudget: Int = 2 shl 20): Boolean; fun discardAll() }
object EngineTls { @Volatile var serverTrustEvaluator: ((host: String, chain: List<X509Certificate>) -> Boolean)? = null }
class FrameExtractor(context: Context, sourceFactory: DataSource.Factory, logger: EngineLogger = EngineLogger.Silent) : AutoCloseable {
    suspend fun frame(atSeconds: Double, maxWidth: Int): ExtractedFrame      // bitmap, actualSeconds, bytesRead
}
object EngineDiagnostics { fun report(): String }
sealed class VideoEngineError : Exception()                                  // names as in 2.11
```

`ByteRangeSource` exists on Apple because FFmpeg reads through a custom `AVIOContext`. On Android the network layer is
Media3's `DataSource`; the OkHttp-based factory must keep the same range semantics (206 with a matching
`Content-Range`, retries 0.25 s doubling to 2 s inside a 30 s window, `knownLength`, headers not URLs). A thin
`ByteRangeSource` is added only when an FFmpeg path (audio extension, stage 5 remux) needs one.

### Staged build plan

| Stage | Scope | Exit gate |
|---|---|---|
| 0 | contract merged; `shared/vectors` for the existing pure functions, read by Swift tests; Android CI skeleton | vectors green in `swift test` |
| 1 | `android/` Gradle build; **probe, route decision and playback of every shared fixture** in `:sample` (direct play, native Matroska, text subtitles) | fixtures play; probe equals `manifest.json`; P1, P2 on one phone |
| 2 | hardware snapshot and verdicts, diagnostics lines, thermal and power rules, HDR and Dolby Vision rules | H1 to H4, F1 to F12 on a phone and a TV box |
| 3 | audio policy (passthrough, decoders, FFmpeg extension `.so`), sidecar and bitmap subtitles, PiP | T1 to T7, S1 to S8 |
| 4 | prewarm, TLS hook, frame extractor, scrub mode | prewarm and TLS vectors; scrub thumbnails |
| 5 | shared native module (P7 to 8.1, audio shaping); Media3 `Transformer` for on-device transcode (HDR, DV P8 transmux [M13]); on-device remux for AVI/ASF if wanted | `dovi_tool` byte parity |

## 6. Open decisions

| # | Decision | Recommendation |
|---|---|---|
| D1 | Leave Swift at the repo root and add `android/` and `shared/`, or move Swift under `apple/` | **Leave it.** Moving costs generator, script and workflow edits and buys nothing |
| D2 | Move the route planner into the engine, both platforms | **Yes**: a pure function with vectors; additive minor on Apple |
| D3 | Android minimum API | **API 29** (thermal status, performance points, hardware flag exist from there [A1][A2][A4]); below API 34 use `Display.HdrCapabilities` |
| D4 | Media3 version policy | **Pin exactly, stable only**: 1.11.1 now (2026-09-10) [M2]; move to 1.12 stable for the P7 fallback |
| D5 | Where Rust or C enters | **Kotlin plus FFmpeg `.so` through stage 4.** Add a shared native module (C ABI, Android first) only for the P7 to 8.1 rewrite or audio shaping DSP; Apple keeps its Swift version until it passes the same vectors |
| D6 | Real devices for the manual sheets | **Two**: one recent phone, one Google TV or Shield-class box (passthrough, tunnelling, per-device DV). Owner to name what he has |
| D7 | Android distribution | **AAR as a release asset with a checksum**, as the XCFrameworks are; Maven later only if wanted |
| D8 | Containers Media3 cannot read (AVI, ASF/WMV) | **Server transcode** through stage 4; on-device FFmpeg remux only on demand |
| D9 | Package and artifact id | `io.github.nphil.videoengine`; confirm |
| D10 | HDR source on an SDR display | **Server transcode** on both until a device test proves the platform's playback tone mapping |

## Sources

- **M1** [supported formats](https://developer.android.com/media/media3/exoplayer/supported-formats): containers (Matroska yes, AVI no), decoder extensions, subtitle formats, HDR note.
- **M2** [Media3 release notes](https://github.com/androidx/media/blob/main/RELEASENOTES.md): 1.11.1 (2026-09-10) stable; P7 HEVC fallback in 1.12.0-beta01; DV P10, VobSub, preload, frame extractor history.
- **M3** [issue 3486](https://github.com/androidx/media/issues/3486): P7 sent to a P5 decoder on a DV TV, fixed by fallback; decoder names.
- **M4** [AudioCapabilities](https://developer.android.com/reference/androidx/media3/exoplayer/audio/AudioCapabilities): passthrough check. **M5** [track selection](https://developer.android.com/media/media3/exoplayer/track-selection) and **M6** [battery](https://developer.android.com/media/media3/exoplayer/battery-consumption): tunnelling, offload.
- **M7** [ExoPlayer](https://developer.android.com/reference/androidx/media3/exoplayer/ExoPlayer): frame-rate strategy, video effects, scrubbing mode, seek parameters. **M8** [VideoChangeFrameRateStrategy](https://developer.android.com/reference/androidx/media3/common/C.VideoChangeFrameRateStrategy).
- **M9** [inspector](https://developer.android.com/media/media3/inspector) and [FrameExtractor](https://developer.android.com/reference/kotlin/androidx/media3/inspector/frame/FrameExtractor): frames, HDR, thread rule.
- **M10** [DefaultPreloadManager](https://developer.android.com/reference/androidx/media3/exoplayer/source/preload/DefaultPreloadManager). **M11** [OkHttpDataSource.Factory](https://developer.android.com/reference/androidx/media3/datasource/okhttp/OkHttpDataSource.Factory). **M12** [SubtitleParser](https://developer.android.com/reference/androidx/media3/extractor/text/SubtitleParser): PGS, DVB, VobSub, SSA, SubRip. **M13** [Transformer formats](https://developer.android.com/media/media3/transformer/supported-formats): HDR, DV P8 transmux.
- **A1** [MediaCodecInfo](https://developer.android.com/reference/android/media/MediaCodecInfo), **A2** [VideoCapabilities](https://developer.android.com/reference/android/media/MediaCodecInfo.VideoCapabilities), **A3** [HdrCapabilities](https://developer.android.com/reference/android/view/Display.HdrCapabilities), **A4** [PowerManager](https://developer.android.com/reference/android/os/PowerManager), **A5** [network security config](https://developer.android.com/privacy-and-security/security-config), **A6** [PiP](https://developer.android.com/develop/ui/views/picture-in-picture), **A7** [16 KB pages](https://developer.android.com/guide/practices/page-sizes).
- **G1** [Ubuntu runner image](https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md): SDK and NDK. **G2** [KVM on Linux runners](https://github.blog/changelog/2024-04-02-github-actions-hardware-accelerated-android-virtualization-now-available).

No GPL or LGPL player source was read. The *2.2.0* "design after" notes in ENGINE.md refer to a third-party LGPL project's
documentation only; the Android design here comes from Android's own documentation.
