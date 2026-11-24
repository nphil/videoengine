# VideoEngine

The Swift layer over the FFmpeg binaries. One
library product, `VideoEngine`, with two targets, both Swift 6 with strict
concurrency, iOS 26 and later:

- **`LoopbackHLS`**: the 127.0.0.1 HTTP server, fragment index, playlists and
  WebVTT tracks. No FFmpeg dependency.
- **`VideoEngine`**: sources, probe, remux, transcode, subtitles, hardware
  facts and diagnostics. Depends on `LoopbackHLS` and the FFmpeg binaries.

The `FFmpeg` product (the raw `Libav*` modules) is unchanged. Apps pin the
package with `exactVersion`, because any breaking public API change is a major version; additive changes are a minor version (2.1.0 adds `FrameExtractor`).

Threading: every public type is `Sendable`. Each FFmpeg run owns one dedicated
thread; state shared with callers sits behind `OSAllocatedUnfairLock`. Nothing
in the engine is `@MainActor`, and no call blocks the caller's thread.

## API

### Sources

`ByteRangeSource` is what FFmpeg reads through a custom `AVIOContext`; FFmpeg
never opens a network URL itself.

- `HTTPRangeSource(url:headers:knownLength:readAheadBytes:requestTimeout:retryWindow:)`
  sends credentials as headers (`X-Plex-Token`, `ApiKey`), never in the URL.
  A reply counts only when it is 206 with a matching `Content-Range` (or 200
  from offset 0). A failed request is retried, 0.25 s apart doubling to 2 s,
  until `retryWindow` (30 s) has passed since the first failure, then reported
  as an error, never as the end of the file; the remux's stall timeout does
  not count that wait. A change of network (Wi-Fi to cellular, a VPN coming
  up) ends the requests in flight at once instead of leaving them hung until
  `requestTimeout`. `knownLength` (Plex `Part.size`) saves the size lookup. A
  read no request covers starts a 512 KiB request, so the header, the index
  at the end and the resume point each cost one round trip; a sequential run
  doubles each request up to `readAheadBytes` and keeps two in flight, three
  from 50 ms to the first byte and four from 150 ms, since one connection
  carries less over a far link. Reads return as bytes arrive and recent
  requests stay cached. `bytesPerSecond`, `latency` (shortest recent time to
  the first byte), `isReconnecting` and `outageSeconds` describe the link
  (`RemuxProgress.sourceBytesPerSecond`, `sourceLatency`, `isReconnecting`).
  `isFetching` (`RemuxProgress.isFetching`) is true while a read is under way:
  a player waiting on a run whose output stays put while it is false waits on
  nothing, which an app can treat as stuck at once rather than after a timer.
- `FileRangeSource(fileURL:)` reads local files.
- `ByteRangeSources.make(for:headers:readAheadBytes:)` picks one by scheme.

### Probe

`MediaProbe.probe(...)` returns `MediaInfo`: container, duration, streams with
codec, language, title and dispositions, and colour and HDR details (transfer,
primaries, mastering display, content light level, Dolby Vision record).

### Remux

`RemuxSession` plays what AVPlayer cannot open by copying the source into a
growing fragmented MP4 served as HLS on 127.0.0.1.

```swift
let session = RemuxSession(
    sourceFactory: { HTTPRangeSource(url: partURL, headers: ["X-Plex-Token": token], knownLength: part.size) },
    options: options, logger: logger
)
let url = try await session.start(at: resumeTime)   // master.m3u8
for await event in session.events { … }            // opened, headerWritten, timeline, progress, finished, failed, stopped
session.updatePlayhead(item.currentTime().seconds)   // paces production
session.setPlayerWaiting(player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
let seekURL = try await session.seek(to: target)     // a new run; replace the item
session.stop()
```

- **Timeline.** Each run's output starts at its origin, the first copied
  timestamp minus the container start time, reported as `.timeline(origin:)`
  and `timelineOrigin`. A position `t` on the item is movie time `t + origin`:
  the app shows `t + origin` and seeks the new item to `target - origin`.
- **Segments** are sealed as each fragment closes, so the first listing
  follows the first keyframe interval. `EXT-X-TARGETDURATION` is fixed per run
  (at least 10, else the longest indexed keyframe gap).
- **Multivariant playlist** (`options.multivariantPlaylist`, on by default):
  `CODECS`, `RESOLUTION`, `FRAME-RATE`, `VIDEO-RANGE` (SDR, PQ, HLG) and
  `SUPPLEMENTAL-CODECS` for Dolby Vision 8.1/8.4, read from the init segment.
- **HEVC and Dolby Vision.** HEVC is written as `hvc1`. Profile 5 becomes
  `dvh1` with the record kept (or added from `dolbyVisionFallback`, for a
  server that reports the profile but the file lacks the box), colour left
  unspecified. Profile 8 with compatibility 1 or 4 keeps its record unless
  `dolbyVision = .baseLayerOnly`. Profile 7 is stripped to its HDR10 base
  layer. Any other record is dropped.
- **Audio** (`options.audio`, `AudioPolicy`): one stream, the viewer's pick
  (`preferredIndex`), else the default, else the first. Copied: AAC-LC with a
  channel configuration, explicit-SBR HE-AAC, AC-3, E-AC-3 (above 5.1 its core
  through `eac3_core`), FLAC and ALAC up to stereo, 96 kHz and 24 bits.
  Everything else is decoded, mixed down to 5.1(side) or stereo and encoded to
  AAC (192 kbit/s stereo, 384 kbit/s 5.1, `aac_at` where available). AC-3 and
  E-AC-3 copies use `delay_moov`. A copy that breaks the muxer before the first
  segment is retried once as a re-encode.
- **Subtitles.** Source subtitle streams are read alongside, never muxed. Text
  (SRT, ASS, WebVTT, mov_text) becomes WebVTT renditions of the multivariant
  playlist (`/subs/<n>/index.m3u8`, fixed 10 s slots), offered by AVPlayer
  under their names. A source stream's slot is listed once the producer is
  5 s past it, since its cues arrive as the file is read; a sidecar track's
  cues are all known, so its slots are listed as soon as the video reaches
  them. A subtitle playlist request waits until the playlist lists a slot:
  AVPlayer fails the item (CoreMediaErrorDomain -12888) when a rendition it
  selects at load answers an empty live playlist.
  `options.sidecarSubtitles` adds downloaded text tracks. Picture subtitles
  (PGS, VobSub, DVB) decode to `SubtitleOverlayTrack`, which the app draws:
  `session.subtitleStreams[i].overlay?.bitmaps(at: movieTime)`.
  `SubtitleFile.read(fileURL:forcedOnly:)` reads sidecar files (.srt, .vtt,
  .ass, .smi, .sup).
- **Pacing.** For sources above `paceMinSourceBytes`, production runs up to
  `paceLeadSeconds` ahead of the playhead (twice that from 100 ms to the
  first byte, or with less than twice the media's rate to spare), then keeps
  step with the playhead or the clock, whichever has moved further, one
  target duration ahead, instead of waiting for the playhead to catch up:
  AVPlayer stops loading the listed segments of a live playlist that has not
  grown for 1.5 target durations, and fails a paused item about 45 s later
  (-12888), so a playlist held still starves it. Paused, production goes on
  at real time, at most the pause's length ahead. A playhead that moves back
  starts the step again from there, and production runs on while
  `setPlayerWaiting(true)` says the player waits for data. The remux thread
  runs at user-initiated until a segment is listed and 8 s are ready, then at
  utility.
- **Suspension.** iOS takes a suspended app's listening socket away, and the
  loopback listener fails when the app runs again (a paused Picture in
  Picture is suspended). `LoopbackServer` then listens on the same port again,
  up to five attempts, so the URLs AVPlayer holds keep working.
- `RemuxSession.sweepStaleFiles(in:prefixes:)` removes temp files a killed
  process left behind; call it at launch.

### Transcode

`FileTranscoder` re-encodes a local file in one VideoToolbox pass;
`ChunkedTranscoder` works in chunks of about 20 s and resumes an interrupted
run. Both take `TranscodeSettings(codec:quality:maxLongEdge:bitrateOverride:)`
and report through `TranscodeObserver`.

### Hardware

- `HardwareDecodeProbe.shared.verdict(for: VideoStreamFacts)` answers
  `.hardware`, `.softwareOnly`, `.unsupported` or `.unknown` (simulator) by
  opening a VideoToolbox session that requires a hardware decoder. Verdicts are
  cached per codec, profile, level, size class and bit depth until the OS or
  device changes. Pass the container's `hvcC`/`avcC`/`av1C` record in
  `configurationAtoms`.
- `HardwareCapabilities` is one `Sendable` snapshot: decode and encode
  support, display (HDR eligibility, EDR headroom, frame rate, gamut, capture,
  external playback), power (thermal state, Low Power Mode, battery) and
  compute. `power.shouldShedOptionalWork` is true at `serious` heat or in Low
  Power Mode.
- `LiveHardwareCapabilityProvider(display:battery:)` reads the device; the
  closures run the UIKit and AVFoundation reads on the main actor, so the
  engine has no UIKit dependency. `snapshot()` at launch and at each playback
  start; `changes()` yields on heat, power and HDR eligibility changes.
  `FixedHardwareCapabilityProvider` serves tests and previews.

### Frame extraction (v2.1.0+)

`FrameExtractor` returns one still picture from a video, for scrub thumbnails
and previews. It reads through a `ByteRangeSource`, never through the player,
so it needs no playback session and does not touch `AVPlayer`, the loopback
server or a `RemuxSession`.

- `FrameExtractor(source: any ByteRangeSource, logger: EngineLogger = .silent)`:
  nothing is read until the first call. Keep one extractor per video while
  thumbnails are needed: the first call opens the video, and the open demuxer
  and decoder are reused, so a scrub costs one keyframe per call. Give it its
  own source, made with `ByteRangeSources.make(for:headers:readAheadBytes:)`
  for the same URL and headers as playback, never playback's source object.
  Separate sources share no connection or cache, but over a network they
  still share the link's bandwidth. The extractor never calls the source's
  `cancel()` (which is permanent); the source's owner does, to end a call stuck
  in a dead network read.
- `func frame(at seconds: Double, maxWidth: Int) async throws -> ExtractedFrame`
  seeks to the keyframe at or before `seconds` (clamped to 0 or later) and
  decodes only that picture; nothing is decoded forward. `ExtractedFrame`
  holds:
  - `image: CGImage`: 8 bits per channel, shrunk to at most `maxWidth` pixels
    wide and never enlarged.
  - `actualSeconds: Double`: the keyframe's time in seconds from the start,
    never later than the request. If there is no timestamped keyframe that
    early, the call throws rather than guessing a time.
  - `bytesRead: Int64`: bytes the source returned to the demuxer during this
    call; the first call also pays for opening the video. It is not network
    transfer: `HTTPRangeSource` read-ahead and its cache can fetch more or
    fewer bytes.
- Calls run one at a time, in order, on a `utility`-priority queue of the
  extractor's own.
- Cancellation: a cancelled task gets `CancellationError` at once; queued or
  running work for it is dropped, and the read in progress is failed so FFmpeg
  stops. The open video stays open for the next call. A call stuck inside the
  source's own read holds the queue until that read returns.
- Decoding uses VideoToolbox when the device and codec allow it, otherwise
  FFmpeg's decoders (libdav1d for AV1); the Simulator always uses FFmpeg. The
  video's own colour matrix, pixel aspect ratio and 90-degree rotation are
  applied. HDR is not tone mapped: HDR10 and HLG pictures come out as plain
  SDR (flat but recognisable), and Dolby Vision profile 5 colours are not
  corrected.
- Limits, whatever the caller asks for: at most 3840 pixels wide and
  3840 x 2160 in all (larger `maxWidth` is capped); videos with pictures
  larger than 8192 x 4608 are refused; a call making no progress for 30 s
  throws `VideoEngineError.timedOut` (outage time the source reports does not
  count); a keyframe must turn up within 64 MiB of reading after the seek.
  A non-finite `seconds` or `maxWidth <= 0` throws a `VideoEngineError`.
- Other failures are `VideoEngineError`, as elsewhere in the engine.

Example: a scrubber that keeps only the newest request.

```swift
import CoreGraphics
import Foundation
import VideoEngine

@MainActor
final class ScrubThumbnails {
    private let extractor: FrameExtractor
    private var pending: Task<Void, Never>?
    private(set) var image: CGImage?

    init(url: URL, headers: [String: String]) throws {
        // A distinct source (same URL and headers), never playback's object.
        let source = try ByteRangeSources.make(for: url, headers: headers)
        extractor = FrameExtractor(source: source)
    }

    /// Call on every scrub change. The previous request is cancelled.
    func scrub(to seconds: Double) {
        pending?.cancel()
        let extractor = extractor
        pending = Task { [weak self] in
            do {
                let result = try await extractor.frame(at: seconds, maxWidth: 320)
                guard !Task.isCancelled else { return }
                self?.image = result.image
                // result.actualSeconds: where the frame really is
                // result.bytesRead: IO cost of this thumbnail
            } catch is CancellationError {
                // superseded by a newer scrub position
            } catch {
                // keep the last image; log if wanted
            }
        }
    }
}
```

This is additive in 2.1.0: no existing type, signature or behaviour changed,
so apps on 2.0.0 move to 2.1.0 by changing the pinned version only.

### Prewarm (v2.2.0+)

`EnginePrewarm.prewarm(url:headers:byteBudget:)` fetches the opening bytes of
a remote file ahead of time, so the source made for it later opens without a
network round trip. Call it when a title is highlighted or about to start.
Design after AetherEngine's documented feature; no code taken.

- `await EnginePrewarm.prewarm(url:headers:byteBudget:)` (budget default
  2 MiB, at most `EnginePrewarm.maximumByteBudget`, 16 MiB) sends one `Range`
  request for the head of an `http(s)` file and holds the bytes in memory.
  It returns true when bytes are held afterwards, false for other schemes, a
  refused or failed request, or a cancelled task, which leave nothing behind.
  A prewarm that is still valid is not fetched again.
- The key is the URL plus the headers exactly as sent (header names are not
  case-sensitive, values are), so a token in a header that differs, or is
  missing, does not match.
- The first `HTTPRangeSource` made for the same URL and headers adopts the
  bytes when it is created: its length (unless `knownLength` is given) and
  every read inside them need no request, including re-reads of the head
  after the tail. Reads past them are requested as usual. Nothing in
  `HTTPRangeSource`'s signature or behaviour changes, and sources made by
  `ByteRangeSources.make`, `MediaProbe`, `RemuxSession` and `FrameExtractor`
  adopt the same way.
- Held bytes are dropped when a source takes them, after three minutes and
  when the system reports memory pressure; at most eight files are held.
  `EnginePrewarm.discardAll()` drops them at once (when leaving a screen).
- One source takes the bytes: a probe made first for the same URL and headers
  uses them up, so prewarm again before the source that matters, or let the
  probe be that source.

### Certificate trust (v2.2.0+)

`EngineTLS.serverTrustEvaluator` lets an app accept an HTTPS media server the
system does not trust: a self-signed certificate or one from a private
certificate authority. Design after AetherEngine's documented feature; no
code taken.

- `EngineTLS.serverTrustEvaluator: (@Sendable (_ host: String, _ trust: SecTrust) -> Bool)?`,
  `nil` by default, which leaves every decision to the system as before.
- When set, the engine's HTTP sessions (shared by `HTTPRangeSource` and
  `EnginePrewarm`) ask it on each server-trust challenge. `true` accepts the
  connection, `false` ends it. Other challenges are untouched.
- The system's verdict is not applied before the hook, so a hook that always
  returns `true` turns certificate checking off for every host. Accept only
  what the user approved: compare `host` and the leaf certificate (for
  example its SHA-256 fingerprint, saved when the user first accepted it)
  and call `SecTrustEvaluateWithError(trust, nil)` for every other host.
- It is a process-wide setting; set it before the first request.

### Diagnostics

- `EngineLogger` carries engine events to the app's log; `.silent` drops them.
- `EngineDiagnostics.report()` returns the recent measured lines for a support
  screen or bug report: `perf-remux` (start-up stages per run), `perf-run`
  (bytes, segments, lead, free memory, thermal state per run), `hw-id` to
  `hw-eng` (first snapshot), `hw-state` (on change) and `hw-probe` (per probe).
- Each stage is also an `os_signpost` interval, subsystem `VideoEngine`,
  category `stages`, for Instruments.

### Duties left to the app

- No permanent `AVPlayerItemVideoOutput`: attach one only for a feature that
  needs pixels and remove it on pause, in the background and from `fair` heat.
  A 32BGRA output at 4K copies about 33 MB per frame, 1 GB/s at 30 fps.
- Choose the route (direct play, remux, server transcode) from the probe, the
  decode verdict and the snapshot: an HDR or Dolby Vision source on a display
  that is not HDR-eligible goes to the server.

## Adoption

### Integrating into a media app

| Step | Change | Gate |
|---|---|---|
| Package | Pin the package with `exactVersion` in the app's Swift package or XcodeGen configuration; add `VideoEngine` alongside `FFmpeg`. | CI |
| Playback | Replace app-owned remux, source, fragment index and loopback server implementations with `RemuxSession(sourceFactory:)`. Supply any server authentication headers through the source factory, call `RemuxSession.sweepStaleFiles` at an appropriate lifecycle point, and import the engine. | device |
| Transcoding | Adapt `FileTranscoder` and `ChunkedTranscoder` to the app's download workflow and forward `EngineLogger` to its logging system. | device |
| Cleanup | Remove replaced implementations and, if no longer needed, the `FFmpeg` product and remaining `Libav*` imports. Update app documentation. | CI |

After `seek(to:)`, the new item starts at the run's origin, so the scrubber
shows `t + origin`. Use `snapshot().decode.av1 == .hardware` for the AV1
hardware decode verdict.

For a remote media server, provide its authentication header to
`HTTPRangeSource` and a known length when available. Supply an `EngineLogger`,
list FFmpeg and its licence in the app's About screen, and configure
`NSAllowsLocalNetworking` when the app needs LAN HTTP access.

## Device test sheets

The simulator runs neither VideoToolbox nor AVPlayer playback, so these run on
a real iPhone (iOS 27, unplugged, Low Power Mode off, thermal nominal unless a
row says otherwise). Each accepted row records device, iOS build, fixture and
the receipt path (screenshot, video or `EngineDiagnostics.report()` text).

### Start and seek (performance)

| ID | Steps | Pass | Log |
|---|---|---|---|
| P1 | 1080p H.264 MKV, 4K HDR10 MKV (1 s and 10 s keyframes), Cues at end and none: 5 cold starts each | first frame within one keyframe interval of `playlist_ready` | `perf-remux` |
| P2 | 5 far seeks (10, 25, 50, 75, 90 %) and 3 near seeks per item | landing within 0.5 s of the target; the shown time includes the origin | `perf-remux`, `remux-start` |
| P3 | 10-minute play of the 4K item | no stall; thermal at most `fair`; `perf-run` lead stays positive | `perf-run` |
| P4 | Instruments or Console with subsystem `VideoEngine` | `open`, `find_stream_info`, `first_packet`, `first_fragment`, `playlist_ready` present per run | signposts |

### Hardware

| ID | Steps | Pass | Log |
|---|---|---|---|
| H1 | Settings, Developer, Hardware report, Share | every `hw-*` group present, `machine=iPhoneNN,N`, under 3.8 KB | `hw-id` to `hw-eng` |
| H2 | the HDR sheet below plus VP9, MPEG-2 1080i, VC-1, HEVC 4:2:2, HEVC 4:4:4, Hi10P H.264, AV1 10-bit | verdict agrees with AVPlayer showing a first frame within 5 s; no `hardware` verdict that then fails | `hw-probe` |
| H3 | an A16-class and an A17 Pro-or-newer phone; AV1 8 and 10-bit 1080p | A16: `av1=no`, routed to the server; A17 Pro: `av1=hw`, plays directly | `hw-probe` |
| H4 | Low Power Mode on, then a 10-minute 4K play until `serious` heat | `hw-state` lines follow; optional work stops | `hw-state` |

### HDR and Dolby Vision

| # | Clip | Expected |
|---|---|---|
| F1 / F2 | HDR10 MKV 4K24 with mastering and CLL / the same as MP4 `hvc1` | HDR; init segment `hvc1`, `colr` 9/16/9, `mdcv`, `clli`; same look |
| F3 / F4 | HLG MKV / HDR10+ MKV | HLG (`colr` 9/18/9) / HDR10 |
| F5 / F6 | DV P5 MKV with `dvcC` / without (server-reported record via `dolbyVisionFallback`) | `dvh1`, correct colours, no decoder error; F6 = F5 |
| F7 / F8 / F9 | DV P7 MEL / FEL single-track / dual-track MKV | HDR10 base layer, no stutter; dual-track copies the base layer only |
| F10 / F11 | DV P8.1 MKV / P8.4 (iPhone .MOV remuxed to MKV) | Dolby Vision with HDR10 fallback; `SUPPLEMENTAL-CODECS` in the master |
| F12 | 4K60 10-bit HDR10, level 5.1 | smooth, no decoder error |

Per clip: check the master's `VIDEO-RANGE` and `CODECS`, watch
`AVPlayerItem.error` (-11833, -12906), see `currentEDRHeadroom` rise above 1
while playing, then seek twice.

### Audio

| ID | Steps | Pass |
|---|---|---|
| T1 | AC-3 5.1 copy | plays from the first segment (`delay_moov`); lip sync within 40 ms on the flash-and-beep clip |
| T2 | E-AC-3 5.1 and JOC on AirPods Pro | Atmos engages for JOC |
| T3 | E-AC-3 7.1 | the 5.1 core plays; compare with an AAC re-encode |
| T4 | TrueHD and DTS family with one tone per channel | AAC 5.1: each tone on its speaker, no clipping |
| T5 / T6 | FLAC/ALAC stereo copy; MP3, Opus, Vorbis, MP2 re-encode | plays; record any silence or error |
| T7 | AAC-LC, HE-AAC, AAC with a program config element | the first two copy, the third re-encodes; all play |

### Subtitles

| ID | Steps | Pass |
|---|---|---|
| S1 | MKV with SRT en/fr and forced SRT: cues at 10 s, 10 min, 60 min | within 100 ms of mpv |
| S2 | 10 seeks, including past the produced range and to a non-keyframe | right cue within 0.5 s, no duplicates |
| S3 | track names, languages and flags in the app and in `AVPlayerViewController` | names as listed by `subtitleStreams`; selection survives a seek restart; system caption style applies |
| S4 | Picture in Picture | WebVTT visible; picture overlays absent |
| S5 | styled ASS | italics and bold kept, positioning dropped, drawings absent |
| S6 | PGS (1080p canvas on 2160p video) and BD `.m2ts` | placement in both orientations, forced-only, pause, 2x, seek |
| S7 | MKV VobSub with and without palette | pictures shown; none without a palette |
| S8 | a 12 s GOP file with long cues | long cues repeat across slots without flicker; the subtitle playlist may trail the video |
| S9 | AirPlay with the loopback URL | expected unreachable: the app falls back |
