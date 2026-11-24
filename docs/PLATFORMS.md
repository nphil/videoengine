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
| Container | FFmpeg demuxer name (`matroska,webm`, `mov,mp4,m4a,3gp,3g2,mj2`) | `avformat` | Media3 container MIME to the FFmpeg name through one table in `ProbeMapper` (stage 1); `shared/fixtures/manifest.json` checks it |
| Codec | FFmpeg codec name (`h264 hevc av1 vp9 eac3 truehd subrip hdmv_pgs_subtitle`) | `avcodec_get_name` | Media3 MIME or `codecs` string to the FFmpeg name in `ProbeMapper`, checked against the same manifest |
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
| 3 | HDR or Dolby Vision source, display not HDR-eligible. Android also checks the type: HDR10 and HLG need that exact type on the display, an HDR10+ display accepts HDR10 | `serverTranscode` | `hdr-display-missing` | E |
| 4 | Dolby Vision profile 5 and no DV decoder and display | `serverTranscode` | `dv5-unsupported` | P |
| 4b | Dolby Vision the decoder and display cannot play natively and that has no base-layer path: profile 7 until the engine falls back to the HEVC base layer, and profiles 4, 9, 10 (Android; profile 8 plays its base layer under rule 3) | `serverTranscode` | `dv-unsupported` | P |
| 5 | verdict `softwareOnly` above 1080p or 30 fps (thresholds to be measured) | `serverTranscode` | `software-decode-too-heavy` | P |
| 6 | no audio path (2.5) | `serverTranscode`: audio re-encoded, video copied | `audio-unplayable` | P |
| 7 | the platform player opens the container and codecs | `directPlay` | `ok` | E |
| 8 | container unreadable by the player, every selected stream copyable | `repackage` | `container-unreadable` | E |
| 9 | `repackage` while external playback is active (AirPlay cannot reach the loopback URL, S9) | `serverTranscode` | `external-playback` | E |
| 10 | anything else | `serverTranscode` | `fallback` | E |

| Route | Apple | Android |
|---|---|---|
| `directPlay` | MP4, MOV, HLS with H.264/HEVC and playable audio | everything Media3 reads, **including Matroska and WebM**, also MPEG-TS, MPEG-PS, FLV, Ogg, AVI and the raw audio formats (MP3, FLAC, WAV, ADTS AAC, AC-3, E-AC-3, AMR) [M1] |
| `repackage` | `RemuxSession`: fragmented MP4 served as HLS on 127.0.0.1 | **not needed for Matroska or AVI.** Only ASF/WMV, RealMedia, MXF, NUT, SWF are outside Media3's readers [M1]; until the remux exists (stage 5) the planner answers `repackage` only when the caller passes `canRepackage`, else `serverTranscode` with the same reason `container-unreadable` (D8) |
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
| DV profile 7, MEL or FEL | HDR10 base layer by default | `dovi_rpu` strips RPU and enhancement layer; dual-track copies base only | Media3 falls back to a plain HEVC decoder for backward-compatible P7 from 1.12.0-beta01 (P8 already) [M2][M3]. **Before that, P7 went to a P5 decoder and looked grey and washed out** on DV TVs without a P7 decoder [M3]. The pinned 1.11.1 has no fallback (`engine.dolbyVision7Fallback` is false in the snapshot), so without a P7 decoder it goes to the server, rule 4b |
| DV profile 7 as 8.1 (*2.2.0*, opt-in) | drop enhancement layer, rewrite RPUs (NLQ removed, CRC-32 redone) | `DolbyVisionRPU`, checked byte for byte against `dovi_tool` | needs sample rewrite before the decoder: shared native module, stage 5 ⚠ feasible inside a Media3 extractor wrapper |
| DV profile 8.1, 8.4 | Dolby Vision, HDR10 or HLG fallback; `baseLayerOnly` forces the base | `hvc1` + `dvvC`, `SUPPLEMENTAL-CODECS` | DV decoder if present, else HEVC base layer [M3] |
| other DV (AVC, AV1 P10, 4, 9) | drop the record, play the base layer | `drop` | P10 known to Media3; unsupported profiles are rejected rather than played as HEVC [M2] ⚠ per release. Stage 1: no matching decoder and display means the server, rule 4b |

`DvheStn` = P5 and `DvheDtb` = P7 are confirmed by [M3]; other profile-to-constant mappings ⚠.

### 2.5 Audio policy

Rule: play the viewer's pick (`preferredIndex`, else default, else first). Keep the bitstream
when the output can take it, else convert as little as possible. Channels shrink only by a
documented mix-down. Lip sync within 40 ms (T1).

| Source | Apple (E) | Android (P) |
|---|---|---|
| AAC-LC, HE-AAC explicit SBR; AAC with program config or implicit SBR | copy; the latter re-encoded (unproven) | platform decoder; PCE and implicit SBR ⚠ test |
| AC-3, E-AC-3 5.1 or JOC | copy (`delay_moov`); JOC keeps Atmos on AirPods (T2) | passthrough if `isPassthroughPlaybackSupported` [M4], else platform decoder, else FFmpeg extension [M1]; JOC kept only if the sink supports it ⚠ |
| Dolby Atmos: E-AC-3 JOC, AC-4 (**contract rule, P**) | JOC copied untouched (T2) | handed untouched to the platform decoder or passthrough, **never decoded by FFmpeg, never re-encoded**; AC-4 only if `MediaCodecList` lists an `audio/ac4` decoder ⚠; if `shaping` or a PCM sink is forced, Atmos is lost and the app is told |
| E-AC-3 above 5.1 | 5.1 core (`eac3_core`): the MP4 muxer cannot describe 7.1 | passthrough carries the whole stream (**an Apple muxer limit, not a contract rule**) |
| FLAC, ALAC | copy up to stereo, 96 kHz, 24 bit, else re-encode | any decoder, no limit |
| TrueHD, DTS, DTS-HD | decode, mix to 5.1(side), AAC 384 kbit/s, or E-AC-3 640 kbit/s with `surroundCodec = .eac3` (*2.2.0*) | passthrough on TV or receiver, else FFmpeg extension (`dca truehd mlp`) [M1] |
| Opus, Vorbis, MP3, MP2 | decode, AAC 192 kbit/s stereo | platform decoder |
| `shaping` (*2.2.0*): delay up to 2 s either way, dialogue lift 0 to 12 dB, night mode | forces re-encode | custom `AudioProcessor` on PCM; **forces decode, disables passthrough and offload** (offload limits effects [M6]); never applied silently to an Atmos track |

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
- **No ASF/WMV, RealMedia** [M1] (AVI is read: `AviExtractor` is in the default factory of 1.11.1, found in stage 1); no AirPlay (Cast is separate work).
- **Native code** must be 16 KB page-aligned for Play; NDK r28 or newer does it by default [A7].

### 3.1 Device-flexible by rule; target devices

**Rule (P).** The Android engine is tuned to no device. Every capability is **probed at runtime** into one
`HardwareCapabilities` snapshot (the mirror of Apple's): decoders via `MediaCodecList` and performance points,
display HDR types and modes, `AudioCapabilities` and passthrough, GPU and NPU availability, thermal and power.
All decisions (2.2 route, 2.3 verdicts, 2.5 audio, enhancement) are pure functions of that snapshot. **No device-name
checks**; `Build.MODEL` is only logged in `hw-id`. A weak device degrades by a fixed ladder: enhancement off, then a
lower enhancement rung, then software-only video allowed only below the rule 5 limit, then server transcode; audio
goes passthrough, platform decoder, FFmpeg decoder, server. The stage 1 snapshots of both devices are in
`shared/route-vectors.json`, built from the facts below and marked provisional until the device reports replace them
(stage 2); the route vectors replay them next to a synthetic weak and a synthetic strong snapshot, so "works on any device" is a test, not a promise.

**Enhance-picture rungs (P, same names on both platforms).** `off`, `scale` (single-pass spatial upscaler),
`shader` (heavier GPU filter), `neural` (ML super resolution). The rung comes from the snapshot, a short first-use
frame-time benchmark cached per `Build.FINGERPRINT`, and heat: one rung down at `fair`, `off` when
`shouldShedOptionalWork`; never applied to frame extraction or server output; never changes HDR or Dolby Vision
metadata; logged as `hw-state enhance=<rung>`.

Targets: **Xiaomi Pad 8 Pro** (primary; stage 1 runs here) and **Onn 4K Pro** (Google TV box, later Android TV
app). Two generations of the Onn exist and the sources differ, so the column lists both; which one is owned is
recorded in stage 1. Everything not stated by a maker is ⚠ and is read on the device.

| Block | Xiaomi Pad 8 Pro | Onn 4K Pro (2024 / 2026) | How the engine reaches it, any device |
|---|---|---|---|
| SoC, RAM | Snapdragon 8 Elite, 3 nm, Oryon 2+6 cores, Adreno 830 @1100 MHz, 8 or 12 GB [X1]; Qualcomm's brief lists 2+5 for SM8750-3-AB [X2], so count cores at run time | 2024: Amlogic S905X4, 4 x A55 2.0 GHz, Mali-G31 MP2, 3 GB [O1][O2]. 2026: S905X5M, 6 nm, 4 x A55, Mali-G310 V2, 3 GB [O3] | `availableProcessors`, `ActivityManager.MemoryInfo`, GL and Vulkan strings in `hw-cpu`, `hw-gpu` |
| Video decode | hardware H.265, VP9, AV1; 8K HDR playback at 60 fps [X2]; H.264 not named there ⚠ | 2026: H.265, AVS2, VP9, AV1 to 4K at 75 fps 10-bit, HLG, HDR10 [O3]. 2024: AV1, VP9, H.264, H.265 [O1][O2]; limits ⚠ | `MediaCodecList`, `isHardwareAccelerated`, `getSupportedPerformancePoints`, `areSizeAndRateSupported` [A1][A2], recorded per codec, profile, bit depth as `hw-dec` |
| HDR, Dolby Vision | HDR10, HLG, HDR10+, Dolby Vision playback [X2]; Xiaomi lists HDR10 and Dolby Vision [X1]. **Which DV profiles the decoder advertises is not published ⚠**: read `CodecProfileLevel.DolbyVision*` of `video/dolby-vision` decoders in stage 1 | Dolby Vision and HDR10 stated [O1][O3][O5]; HDR10+ listed by one guide [O2] but unconfirmed elsewhere ⚠; **no DV profile 7** on the 2026 box [O5] | decoder profile list plus `Display.HdrCapabilities` of the *connected* display (the TV, not the box) [A3]; 2.4 rules pick per profile. P7 on the box takes the HDR10 base layer through Media3's fallback from 1.12.0-beta01 [M2]; on 1.11.1 (D4) route P7 to the server on a device with no P7 decoder [M3] |
| Atmos, audio out | "Dolby Atmos supported", quad speakers [X1]. Atmos on speakers and headphones is **owner-reported, confirm in stage 1** | Atmos as E-AC-3 JOC passthrough works; DD+ works; **lossless TrueHD, DTS-HD, DTS:X not passed** (firmware, shared by earlier Onn boxes) [O4]. 2024 box ⚠ same | rule in 2.5: JOC untouched to the platform decoder or sink. `AudioCapabilities` [M4]; `Spatializer` (API 32): `getImmersiveAudioLevel`, `isAvailable`, `isEnabled`, `canBeSpatialized(attributes, format)` [X3] for headphones and speakers ⚠ which path the tablet uses |
| Display | 3200 x 2136, up to 144 Hz, 800 nits peak [X1]; HDR peak in HDR mode not stated ⚠; SoC supports up to QHD+ at 240 Hz, VRR [X2] | HDMI 2.0, 4K up to 75 Hz (2026) [O3]; the picture is the TV's | `Display.getSupportedModes()`; `setVideoChangeFrameRateStrategy` drives `Surface.setFrameRate` [M7][M8]. Whether 23.976 has an exact mode on the tablet ⚠. On the box, matching worked in Netflix but not Disney+ or Apple TV [O5]: the engine must request it itself and test it |
| GPU effects, upscaling | Adreno 830; OpenGL ES 3.2, Vulkan 1.3, OpenCL 3.0 [X2]. Media3 effects are GL shader programs, also in `ExoPlayer.setVideoEffects` [M7][X10]; a Vulkan path would sit outside Media3 effects ⚠ | Mali GPUs, far weaker; API levels ⚠ | `scale` rung: Snapdragon GSR 1 is a single-pass GLSL upscaler, **BSD 3-Clause** [X4]; AMD FSR 1.0 is spatial, **MIT** [X5]; both fit a custom `GlEffect`. GSR 2 is a temporal upscaler for game engines (needs per-frame motion data a decoded video lacks) ⚠ inference. Qualcomm's "video super resolution" is a camera-capture feature, not a playback API [X2] |
| NPU, ML upscaling | Hexagon NPU, INT4/8/16 and FP16 [X2]; LiteRT with the Qualcomm AI Engine Direct delegate lists SM8750 as supported [X6]; NNAPI is deprecated since Android 15, do not build on it [X7] | none listed in any source ⚠; `neural` rung unavailable | `neural` rung only if LiteRT reports the delegate. Budget: 41.7 ms a frame at 24 fps, 16.7 ms at 60 fps. Google's only NPU timing (a segmentation model on Galaxy S25, same SoC) is 24.9 ms [X6]: **ML super resolution at 24 fps for small models is plausible, at 60 fps or 4K output unproven ⚠**; the decoder-to-NPU frame transfer is the main risk; QNN runtime licence ⚠ check before shipping. A stage 5 spike, off by default |
| Thermal, perf | passive cooling ⚠ (no fan stated), battery | small mains box ⚠ | `getCurrentThermalStatus`, `getThermalHeadroom` and the ADPF thermal API [A4][X8]; `PerformanceHintManager.createHintSession` (API 31; null if unsupported) for decode and effect threads [X9]; power-efficiency hint on Android 15 [X8] |
| OS, ABI | HyperOS 3 [X1] | Android TV 12 to 14 (2024) [O2]; Android 14 (2026) [O5]; **both run a 32-bit userspace** on 64-bit hardware [O1][O5] | ship **`armeabi-v7a`** as well as `arm64-v8a` (section 4 CI); never assume 64-bit |

**What the TV box covers that the tablet cannot:** passthrough to a real receiver (DD+ and Atmos yes, lossless no),
refresh-rate switching on a real TV, tunnelling (`setTunnelingEnabled` [M5][M6]; works on neither device until tested ⚠),
Google TV navigation (D-pad, leanback launcher; platform guidance not re-read here ⚠), a 32-bit userspace, 3 GB of
RAM, weak GPU and no NPU, so enhancement must scale down or turn off, and DV profile 7 falling back to HDR10.
**What the tablet covers that the box cannot:** Adreno and Hexagon enhancement, quad-speaker Atmos and `Spatializer`,
Picture in Picture, touch, a 144 Hz panel.

**Apple counterpart** (the same rungs and rules; Apple mechanism per **Enhance picture (v3.0.0)**, whose design is
not in any branch readable when this was written ⚠, so these rows state only what the contract needs from it):

| Block | Apple today | Contract need from Enhance picture (v3.0.0) |
|---|---|---|
| Decode | VideoToolbox verdicts (2.3) | none, uses the same snapshot |
| GPU rung (`scale`, `shader`) | Metal ⚠ | same rung names, same `hw-state enhance=`, off at `shouldShedOptionalWork` |
| `neural` rung | Neural Engine or GPU ⚠ | same budget rule (frame time), same off-by-default |
| Heat, power | `ProcessInfo.thermalState`, low-power mode | one rung down at `fair`, off at `serious` |

## 4. Repository layout, fixtures, versioning, CI

### Layout (additive, nothing moves)

```
Package.swift  Sources/  Tests/  scripts/  .github/   unchanged, repo root
docs/ENGINE.md  docs/PLATFORMS.md  android/README.md
android/                Gradle: :videoengine (Kotlin library), :sample; :native (NDK) arrives with FFmpeg in stage 3
shared/fixtures/        manifest.json (what ffprobe reports for Tests/VideoEngineTests/Fixtures); new clips later
shared/route-vectors.json  platform-neutral route vectors and the device snapshots they run on (stage 1); more vector files later
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
keep them, and Android reads them there: a Gradle copy task puts them into the sample's assets, so no binary is duplicated (`sourceSets.androidTest.assets.srcDir` stays an option for instrumented tests). New 1 to 3 s clips go
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
| `android-ffmpeg` | `scripts/android/build-ffmpeg.sh`: same FFmpeg tag and LGPL configure, **shared** `.so` (LGPL-friendly), `arm64-v8a`, **`armeabi-v7a`** (the Onn box runs a 32-bit userspace, 3.1) and `x86_64` for the emulator; cached |
| `android-sample` | assemble the sample APK, upload it |
| `android-emu` | emulator smoke on KVM (needs the udev rule on 2-vCPU runners [G2]); probe and route vectors only, **no hardware verdicts** |
| manual | real-device sheets on the Xiaomi Pad 8 Pro and the Onn 4K Pro: P1 to P4, H1 to H4, F1 to F12, T1 to T9, S1 to S10 |

Stage 1 ships one job, `android` (`.github/workflows/android.yml`), instead of the four above: JVM tests, lint, the release AAR and the sample debug APK, uploaded as the artifacts `videoengine-aar` and `videoengine-sample-debug-apk`. It starts only for `android/**`, `shared/**` and its own file. `shared/**` does not start the Swift workflows until Swift adopts the vectors; that change adds the path to their filters. Edits to `Tests/VideoEngineTests/Fixtures` alone do not start it either; `shared/fixtures/manifest.json` does.

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
| 1 | **Built; device reports pending (see "Stage 1 as built").** `android/` Gradle build; **on the Xiaomi Pad 8 Pro**: probe, route decision and playback of every shared fixture in `:sample` (direct play, native Matroska, text subtitles); records the tablet's `hw-*` snapshot as `shared/devices/xiaomi-pad-8-pro.json` | fixtures play; probe equals `manifest.json`; P1, P2 on the tablet; DV profile list, Atmos path and `Spatializer` state recorded |
| 2 | hardware snapshot and verdicts, diagnostics lines, thermal and power rules, HDR and Dolby Vision rules, the capability ladder; the **Onn 4K Pro** joins (its snapshot recorded, 32-bit build) | H1 to H4, F1 to F12 on both; route vectors replay both snapshots plus a synthetic weak and strong one |
| 3 | audio policy (passthrough, decoders, FFmpeg extension `.so`), sidecar and bitmap subtitles, PiP | T1 to T7, S1 to S8; passthrough and frame-rate matching on the Onn box |
| 4 | prewarm, TLS hook, frame extractor, scrub mode; enhance `scale` and `shader` rungs as Media3 GL effects | prewarm and TLS vectors; scrub thumbnails; rung chosen per snapshot, `off` on the box if it misses the frame budget |
| 5 | shared native module (P7 to 8.1, audio shaping); `neural` rung spike on the tablet (LiteRT, Qualcomm delegate); Media3 `Transformer` for on-device transcode (HDR, DV P8 transmux [M13]); on-device remux for AVI/ASF if wanted | `dovi_tool` byte parity; ML super resolution frame time measured |

### Stage 1 as built

Branch `android-stage1`, not merged, no release. `android/` has the library `:videoengine` and the app `:sample`; `android/README.md` has the build steps and the API. Media3 is pinned to 1.11.1 in the version catalog, min API 29, `compileSdk` 36, package `io.github.nphil.videoengine`, ABIs `arm64-v8a` and `armeabi-v7a` configured. The AAR has no native code until stage 3, so it is the same for both ABIs.

**Shared files.** `shared/route-vectors.json` holds 85 route vectors (every rule 1 to 10 and 4b) and 13 snapshots: the Xiaomi Pad 8 Pro and both Onn 4K Pro generations (provisional, built only from the facts in 3.1), plus synthetic weak and strong snapshots and eight variants of the strong one. `shared/fixtures/manifest.json` holds what ffprobe reports for the three fixtures; the JVM tests run Media3's real Matroska extractor over the files and compare, and the sample's **Check** button does the same on a device. **Swift adopts the same vectors later**: once D2 moves the planner into the engine, a `swift test` reads `shared/route-vectors.json` and replays it through the Swift planner, and that change adds `shared/**` to the Swift workflows' path filters. Stage 1 touches neither Swift code nor those workflows.

**Decided in stage 1** (additive to the text above): rule 4b and the reason `dv-unsupported`; the type check in rule 3; `repackage` only with `canRepackage`; AVI is readable; no `ProbeDepth` (Media3's extractors give the same facts in one pass); decode verdicts are computed from the snapshot (`Hardware` means advertised, not proven; the trial configure is stage 2), their cache key adds the frame-rate bucket and the Dolby Vision profile, and a stream wider than 3840 counts as the 8K size class; AMR and G.711 joined the audio table because the probe emits them; `EnginePlayer.create` builds an ExoPlayer for a snapshot (hardware decoders first, frame-rate matching, optional tunnelling), the `PlaybackSession` of section 5 comes later.

**Provisional until the device reports return:** the Pad's Dolby Vision profile list (`hw-dv`), its Atmos path and `Spatializer` state (`hw-aud`); which Onn generation the owner has; every `Hardware` verdict (advertised, not measured); Dolby Vision profile numbers other than 5 and 7; the HDR10 base layer of profile 8 where the file does not say; the audio decoder rows and the H.264 rows of the device snapshots (assumed, listed in each snapshot's `assumed`).

**Exit gate.** Probe equals `manifest.json`: green in CI. Open until the owner runs the sample on both devices: fixtures play, P1 and P2 on the tablet, and the three recorded items.

**Proposed stage 2.** (1) Store each device report as `shared/devices/<device>.json` and make the vectors replay those instead of the provisional snapshots, next to the synthetic weak and strong ones. (2) Trial-configure verdicts, so `Hardware` is proven and cached by key. (3) Thermal and power rules that act on `shouldShedOptionalWork`, the HDR and Dolby Vision rules checked against the reports, the capability ladder, `hw-state` lines. (4) The Onn 4K Pro joins with its 32-bit build. (5) H1 to H4 and F1 to F12 on both devices.

## 6. Open decisions

| # | Decision | Recommendation |
|---|---|---|
| D1 | Leave Swift at the repo root and add `android/` and `shared/`, or move Swift under `apple/` | **Leave it.** Moving costs generator, script and workflow edits and buys nothing |
| D2 | Move the route planner into the engine, both platforms | **Yes**: a pure function with vectors; additive minor on Apple |
| D3 | Android minimum API | **API 29** (thermal status, performance points, hardware flag exist from there [A1][A2][A4]); below API 34 use `Display.HdrCapabilities` |
| D4 | Media3 version policy | **Pin exactly, stable only**: 1.11.1 now (2026-09-10) [M2]; move to 1.12 stable for the P7 fallback |
| D5 | Where Rust or C enters | **Kotlin plus FFmpeg `.so` through stage 4.** Add a shared native module (C ABI, Android first) only for the P7 to 8.1 rewrite or audio shaping DSP; Apple keeps its Swift version until it passes the same vectors |
| D6 | Real devices for the manual sheets | **Resolved: both named.** Xiaomi Pad 8 Pro (primary, from stage 1) and Onn 4K Pro (TV box: passthrough, refresh-rate matching, tunnelling, weak-device degradation, from stage 2). Open detail: which Onn generation (2024 S905X4 or 2026 S905X5M); stage 1 records it |
| D7 | Android distribution | **AAR as a release asset with a checksum**, as the XCFrameworks are; Maven later only if wanted |
| D8 | Containers Media3 cannot read (ASF/WMV, RealMedia, MXF; AVI is readable) | **Server transcode** through stage 4; on-device FFmpeg remux only on demand |
| D9 | Package and artifact id | `io.github.nphil.videoengine`; confirm |
| D10 | HDR source on an SDR display | **Server transcode** on both until a device test proves the platform's playback tone mapping |

## Sources

- **M1** [supported formats](https://developer.android.com/media/media3/exoplayer/supported-formats): containers (Matroska yes; AVI: `AviExtractor` is registered in 1.11.1's `DefaultExtractorsFactory`, checked in stage 1), decoder extensions, subtitle formats, HDR note.
- **M2** [Media3 release notes](https://github.com/androidx/media/blob/main/RELEASENOTES.md): 1.11.1 (2026-09-10) stable; P7 HEVC fallback in 1.12.0-beta01; DV P10, VobSub, preload, frame extractor history.
- **M3** [issue 3486](https://github.com/androidx/media/issues/3486): P7 sent to a P5 decoder on a DV TV, fixed by fallback; decoder names.
- **M4** [AudioCapabilities](https://developer.android.com/reference/androidx/media3/exoplayer/audio/AudioCapabilities): passthrough check. **M5** [track selection](https://developer.android.com/media/media3/exoplayer/track-selection) and **M6** [battery](https://developer.android.com/media/media3/exoplayer/battery-consumption): tunnelling, offload.
- **M7** [ExoPlayer](https://developer.android.com/reference/androidx/media3/exoplayer/ExoPlayer): frame-rate strategy, video effects, scrubbing mode, seek parameters. **M8** [VideoChangeFrameRateStrategy](https://developer.android.com/reference/androidx/media3/common/C.VideoChangeFrameRateStrategy).
- **M9** [inspector](https://developer.android.com/media/media3/inspector) and [FrameExtractor](https://developer.android.com/reference/kotlin/androidx/media3/inspector/frame/FrameExtractor): frames, HDR, thread rule.
- **M10** [DefaultPreloadManager](https://developer.android.com/reference/androidx/media3/exoplayer/source/preload/DefaultPreloadManager). **M11** [OkHttpDataSource.Factory](https://developer.android.com/reference/androidx/media3/datasource/okhttp/OkHttpDataSource.Factory). **M12** [SubtitleParser](https://developer.android.com/reference/androidx/media3/extractor/text/SubtitleParser): PGS, DVB, VobSub, SSA, SubRip. **M13** [Transformer formats](https://developer.android.com/media/media3/transformer/supported-formats): HDR, DV P8 transmux.
- **A1** [MediaCodecInfo](https://developer.android.com/reference/android/media/MediaCodecInfo), **A2** [VideoCapabilities](https://developer.android.com/reference/android/media/MediaCodecInfo.VideoCapabilities), **A3** [HdrCapabilities](https://developer.android.com/reference/android/view/Display.HdrCapabilities), **A4** [PowerManager](https://developer.android.com/reference/android/os/PowerManager), **A5** [network security config](https://developer.android.com/privacy-and-security/security-config), **A6** [PiP](https://developer.android.com/develop/ui/views/picture-in-picture), **A7** [16 KB pages](https://developer.android.com/guide/practices/page-sizes).
- **G1** [Ubuntu runner image](https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md): SDK and NDK. **G2** [KVM on Linux runners](https://github.blog/changelog/2024-04-02-github-actions-hardware-accelerated-android-virtualization-now-available).
- **X1** [Xiaomi Pad 8 Pro specs](https://www.mi.com/global/product/xiaomi-pad-8-pro/specs/) and [overview](https://www.mi.com/global/product/xiaomi-pad-8-pro) ("Dolby Vision and Dolby Atmos supported"). **X2** [Snapdragon 8 Elite product brief](https://www.qualcomm.com/content/dam/qcomm-martech/dm-assets/documents/Snapdragon-8-Elite-SM8750-3-AB-Product-Brief.pdf): decoders, HDR, Adreno APIs, display, NPU.
- **X3** [Spatializer](https://developer.android.com/reference/android/media/Spatializer) (API 32). **X4** [Snapdragon GSR](https://github.com/SnapdragonStudios/snapdragon-gsr) (BSD 3-Clause). **X5** [FidelityFX FSR 1.0](https://github.com/GPUOpen-Effects/FidelityFX-FSR) (MIT).
- **X6** [LiteRT Qualcomm NPU](https://ai.google.dev/edge/litert/android/npu/qualcomm). **X7** [NNAPI migration guide](https://developer.android.com/ndk/guides/neuralnetworks/migration-guide). **X8** [ADPF](https://developer.android.com/games/optimize/adpf). **X9** [PerformanceHintManager](https://developer.android.com/reference/android/os/PerformanceHintManager). **X10** [Media3 transformations and effects](https://developer.android.com/media/media3/transformer/transformations).
- **O1** [AFTVnews, Onn 4K Pro 2024](https://www.aftvnews.com/walmart-releases-50-onn-4k-pro-streamer-w-32gb-storage-3gb-ram-wifi-6-hands-free-voice-control-and-more/). **O2** [Android TV Guide, 2024 box](https://www.androidtv-guide.com/streaming-gaming/onn-walmart-4k-pro-gtv/). **O3** [AndroidPCtv, 2026 box](https://androidpctv.com/walmart-onn-4k-pro-streaming-device-2026). **O4** [AFTVnews passthrough test, 2026 box](https://www.aftvnews.com/2nd-gen-onn-4k-pro-does-not-support-lossless-dolby-truehd-and-dtsx-audio-passthrough-like-the-onn-4k-stick). **O5** [Lon.TV review, 2026 box](https://blog.lon.tv/2026/05/10/new-onn-4k-pro-streaming-box-review-2026-version). Walmart's own listing (snippet only) states 32 GB, 3 GB RAM, Dolby Vision and Atmos. These are reviews and spec aggregators, not Walmart or Google spec sheets: treat Onn rows as secondary until read on the box.

No GPL or LGPL player source was read. The *2.2.0* "design after" notes in ENGINE.md refer to a third-party LGPL project's
documentation only; the Android design here comes from Android's own documentation.
