# VideoEngine

The Swift layer over the FFmpeg binaries. One
library product, `VideoEngine`, with two targets, both Swift 6 with strict
concurrency, iOS 27 and later:

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
  `RemuxProgress.isFinished` (v2.2.0+) is true once the run has written
  everything, with `.finished`, and stays true. A run started near the end
  finishes in a few seconds, before a frame shows, and its output no longer
  moves: a stall watch must treat `isFinished` as complete, never as stuck,
  and never restart a finished run.
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
- **Text from picture subtitles (v2.2.0+).** The overlay track does not
  show in Picture in Picture or over AirPlay, since AVPlayer draws only what
  is in the playlist. With `options.bitmapSubtitleText = true` (default off)
  each picture stream is also offered as a WebVTT rendition named
  "<name> (text from picture)", for example "English (text from picture)",
  next to its overlay entry in `session.subtitleStreams`; the two share
  `streamIndex`, and the rendition has `isRecognizedFromPicture == true`. Its
  cues are what Vision (`VNRecognizeTextRequest`, accurate level, language
  correction on, language from the stream's tag when Vision supports it,
  else detected) reads from each event's pictures, lines top to bottom,
  with the event's own start and end times. An event that reads as empty
  gets no cue. The rendition carries the stream's language and its default,
  forced and hearing-impaired flags; it is AUTOSELECT only when the stream
  is default or forced, so AVPlayer offers it but does not pick it for the
  viewer. An app that draws the overlay itself should not also select the
  rendition, or the text shows twice. Reading is lossy by design and the
  overlay stays the pixel-accurate rendering. It runs on one utility-priority
  queue per stream, off the remux thread, which only enqueues: production
  is never held up. At most 512 events wait per stream; later ones are
  dropped, which only leaves a cue missing, and the run logs the count as
  `subtitle-text-dropped`. Slots follow the usual rule, listed once the producer has
  read 5 s past them, with one addition: a slot is listed only after every
  event read so far has been recognised, and not while a picture of the
  stream is on screen without an end yet, so a listed slot never gains a
  cue. The rendition therefore trails the video by the reading time. Design
  after AetherEngine's documented feature (LGPL-3.0,
  github.com/superuser404notfound/AetherEngine); no code taken.
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

### Seek back without a restart (v2.2.0+)

`seek(to:)` always starts a new run: the item is replaced and the source read
again from the keyframe before the target. `seekReusing(to:)` is additive and
keeps the run when the target is already in what it sealed:

```swift
let seek = try await session.seekReusing(to: target)
if seek.reused {
    await item.seek(to: CMTime(seconds: seek.itemTime!, preferredTimescale: 600))   // same item, same URL
} else {
    // a new run, as after seek(to:): replace the item with seek.url, then seek it to
    // target - origin once .timeline(origin:) arrives
}
```

- **When it reuses.** The run is alive (not stopped, not failed), its origin is
  known, and `0 <= target - origin < sealed duration`, the sum of the segment
  durations in the playlist (`FragmentIndex.sealedDuration`). Nothing is
  downloaded or muxed again. A run that has finished counts too: its whole
  playlist is sealed.
- **Otherwise** it is `seek(to:)`: a target before the run's start (an earlier
  keyframe was never read), past what is sealed, or after a failed run. A
  target a few seconds past the sealed edge starts a new run rather than
  waiting for the old one.
- **Pacing.** `seekReusing` moves the run's playhead to `itemTime` at once, and
  the pace gate follows a playhead that moves back, so production does not wait
  for it. Keep calling `updatePlayhead`.
- **Limits.** Audio and subtitle choices are fixed per session by `options`, so
  every run matches them; an app that changes the audio stream starts a new
  session. No keyframe or sample-accurate seek: AVPlayer lands inside the
  listed segment as it does for any HLS seek.

Design after AetherEngine's documented seek-back behaviour; no code taken.

### Dolby Vision profile 7 as 8.1 (v2.2.0+)

By default profile 7 is cut to its HDR10 base layer. With
`options.dolbyVision = .profile7AsProfile8` it stays Dolby Vision as
single-layer profile 8.1 (opt-in; nothing else changes):

- The enhancement layer (NAL type 63, or any NAL with `nuh_layer_id` above 0)
  is dropped from every video packet.
- Each RPU (NAL type 62) is rewritten to profile 8.1, the conversion
  `dovi_tool` calls mode 2: the enhancement-layer mapping (NLQ) is removed,
  the residual flag is set, extension blocks are re-aligned and the CRC-32 is
  recomputed. `DolbyVisionRPU` does this in Swift, bit for bit, since FFmpeg's
  `dovi_rpu` filter can strip an RPU but not convert one. An RPU that cannot be
  followed (an unknown layout) is dropped, and the stream plays as HDR10 there;
  the run logs `remux-dv-profile81` with the counts.
- The record is written as profile 8, compatibility ID 1 (`dvvC` on an `hvc1`
  entry), at the source's level. The multivariant playlist then carries
  `SUPPLEMENTAL-CODECS="dvh1.08.xx/db1p"` with `VIDEO-RANGE=PQ`, the same as for
  a native 8.1 file.
- **Applies to** a profile 7 record with RPU and a base layer, from the file or
  from `dolbyVisionFallback`, in a stream whose RPUs travel in the video
  packets: single-track MKV and MP4, MEL or FEL. A dual-track file whose RPU
  exists only in the separate enhancement track has nothing to convert in the
  base track; it plays without Dolby Vision metadata.
- **Cost.** A full enhancement layer's detail is discarded, as in any 7 to 8.1
  conversion; a minimal one loses nothing. The rewrite touches only the video
  packets that carry an RPU or enhancement layer.
- **Tests.** The rewrite is checked byte for byte against real MEL and FEL RPUs
  and their `dovi_tool convert --mode 2` output (quietvoid/dovi_tool, MIT).
  Add the device sheet row F7 / F8 with the option on: Dolby Vision on a
  display that supports it, HDR10 elsewhere.

Design after AetherEngine's documented feature; no code taken.

### E-AC-3 for surround that is re-encoded (v2.2.0+)

Design after AetherEngine's documented feature; no code taken.

By default, surround the engine cannot copy (TrueHD, MLP, DTS and DTS-HD,
Opus or Vorbis in 5.1, multichannel FLAC and ALAC) is decoded, mixed to
5.1(side) and encoded to AAC at 384 kbit/s. With
`options.audio.surroundCodec = .eac3` the same audio is encoded to E-AC-3 5.1
at `options.audio.eac3BitRate` (640 kbit/s by default) with FFmpeg's own
`eac3` encoder instead, which keeps a Dolby surround track in place of AAC.

- Off by default: `surroundCodec` is `.aac`, and nothing changes for an
  existing caller.
- Only audio that is re-encoded and has more than two channels is affected.
  Mono and stereo stay AAC, and a stream that is copied (AC-3, E-AC-3, AAC)
  stays a copy.
- E-AC-3 output gets `delay_moov` like an E-AC-3 copy, since the muxer builds
  the `ec-3` sample entry from the first packet; the master playlist declares
  `ec-3`.
- If the muxer fails before the first segment, the run starts again once with
  AAC, as it does for a failed copy.
- The pinned FFmpeg n9.0.2 binaries carry the `eac3` encoder (`smoke.c`
  checks for it). It is not yet played back on a device: see T8.

### Audio shaping (v2.2.0+)

Design after AetherEngine's documented feature; no code taken.

`options.audio.shaping` is an `AudioShaping(delay:dialogueLift:nightMode:)`:

| Setting | Effect |
|---|---|
| `delay` | seconds the sound moves later (positive) or earlier (negative), up to 2 either way, in whole milliseconds; for lip sync |
| `dialogueLift` | 0 to 12 dB added to speech: the centre channel on 5.1, the part of the mix both sides share on stereo (the sides stay) |
| `nightMode` | compressor (threshold about -24 dBFS, 4:1, 6 dB make-up) and a limiter at 0.9, so loud passages come closer to quiet ones |

- **Shaping runs only when the audio is re-encoded, and choosing any of it
  forces a re-encode.** A stream that would have been copied (AAC, AC-3,
  E-AC-3, FLAC, ALAC) is decoded and encoded again, to AAC or, for surround
  with `surroundCodec = .eac3`, to E-AC-3. Leave `shaping` at its default to
  keep copies.
- The chain is built from `pan` (lift), `acompressor` and `alimiter` (night
  mode), then `adelay` (later) or `atrim` (earlier), in that order. All are
  in the full non-GPL filter set the pinned binaries carry. The delay works in
  samples before the encoder, so timestamps and the video are untouched.
- A later delay adds its length of sound at the end; an earlier one drops the
  start.
- The retry after a muxer failure is AAC and keeps the shaping.

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
  `ByteRangeSources.make`, `MediaProbe` and `RemuxSession`
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

### Enhance picture (v3.0.0+)

Opt-in, real-time picture improvement for SDR video, run on the device's GPU while the video plays: a scaler, a
contrast-adaptive sharpen and a deband, each optional and changeable while playing. Every stage is off by default.
Design informed by AetherEngine's documented upscaling feature; no code taken. Each Apple API named here was checked
against Apple's iOS 27 documentation. CI compiles the package for the simulator and for a device and tests the
kernels, the planner and the chain on the simulator. The simulator's SDK has no MetalFX and none of VideoToolbox's
frame processors, so those two scalers are compiled into device builds only (the simulator's ladder is the engine's
own scalers) and only the device build compiles them. The first device run was on an iPhone 17 Pro (iOS 27.0.1); what
it showed is under "Measured on iPhone 17 Pro" below, and the device sheet is still open for the fixes that followed.

API (`PictureEnhancer` is `@MainActor`):

- `EnhanceOptions(upscaler:sharpen:deband:)`: `upscaler` is `.off`, `.automatic` or `.lineArt`; `sharpen` and `deband`
  are 0...1 and clamped. `EnhanceOptions.off` is the default; `isEnabled` says whether anything is on.
- `PictureEnhancer(options:logger:power:)` with:
  - `layer: AVSampleBufferDisplayLayer`: shows the enhanced picture, and is empty whenever the chain steps aside.
  - `options`: assign a new value at any time.
  - `displaySize: CGSize`: the pixels the picture covers on screen.
  - `state: EnhanceState` and `updates() -> AsyncStream<EnhanceState>` (the current state first): `.idle`,
    `.running(EnhancePlan)` (scaler, source and output size, sharpen, deband), `.paused(.powerSaving | .droppedFrames)`
    and `.unavailable(.highDynamicRange | .noGPU | .unsupportedPicture)`. `unsupportedPicture` is only for a picture the
    chain truly cannot draw (see the gates below); a crop, a turn, an odd size or a non-square pixel is drawn.
  - `attach(to: AVPlayerItem)`, `detach()` (call it before releasing the enhancer) and `setActive(_:)`.
  - `power`: reports the thermal state and Low Power Mode; the default reads the system's.
- Diagnostics, through `EngineLogger` and kept for `EngineDiagnostics.report()`: `enhance-gpu`, `enhance-picture` (once
  per change: `result=ok` with the coded size, the shown size, the crop when there is one, the turn and the pixel shape
  when it is not square, or `result=unsupported` with the reason), `enhance-probe` (per
  scaler: `result=ready`, `failed` or `skipped`, milliseconds, output size, scale factor, the pixel formats it
  reports and the ones used in and out, model status, or the reason), `enhance-rungs` (once every scaler has an answer
  and again when it changes: one line saying for each rung `chosen`, `failed: ...`, `skipped: ...`, `demoted: ...` or
  `not needed`, then `chosen=`), `enhance-plan` (every state change), `enhance-perf` (every 120 frames: shown, late,
  skipped and failed frames, GPU time average and maximum), `enhance-demote` (from which scaler to which, and why),
  `enhance-pause`, `enhance-resume` and `enhance-error`.
- Changing `options` while playing: a slider dragged in steps is fine. Strength (sharpen, deband) changes that come
  faster than ten a second are held back and only the newest applies, within a tenth of a second; a change of strength
  never rebuilds the scaler or restarts the ladder, and the governor keeps its record. Only a different `upscaler`, or
  turning the chain on or off, starts the ladder over.

```swift
let enhancer = PictureEnhancer(options: EnhanceOptions(upscaler: .automatic, sharpen: 0.3), logger: logger)
enhancer.layer.frame = playerLayer.frame          // same frame and videoGravity as the player's layer
enhancer.layer.videoGravity = playerLayer.videoGravity
playerLayer.superlayer?.insertSublayer(enhancer.layer, above: playerLayer)
enhancer.displaySize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
enhancer.attach(to: item)
// when playback pauses or the app backgrounds: enhancer.setActive(false); when it plays again: setActive(true)
```

How it works:

- The app owns the player. It attaches the enhancer to its `AVPlayerItem` and puts the enhancer's layer above its
  player layer. The enhancer pulls frames with an `AVPlayerItemVideoOutput` on a display link (24 to 60 Hz while frames
  come, a few times a second otherwise), runs the chain and draws the result in its own layer. AVPlayer keeps audio,
  sync and seeking, and the plain picture shows underneath whenever the chain steps aside.
- The chain: NV12 frame to BGRA with the video's own matrix, the scaler, then one pass that debands, sharpens and
  dithers into the buffer the layer shows. Memory is bounded: pooled IOSurface buffers shared with Metal without a
  copy, at most two frames in flight, nothing large allocated per frame, output capped at 2560x1440.
- Gates, in order. Nothing asked for, or no frame yet: idle. No GPU, HDR or Dolby Vision, or a picture that cannot be
  drawn (below): unavailable, and the plain picture plays. Low Power Mode or
  thermal `serious`: paused. About a quarter of recent frames missed: step down one scaler, then pause for 10, 20 and
  40 s, then stay off; a pause ends by itself. A source that is not at least 1.1x smaller than the display skips the
  scaler. The player's frames are taken only while the chain runs, and while it waits for the first frame to learn
  what the picture is; the app also stops them with `setActive(false)`. The gate here is `serious`, where the app rule
  above says `fair`: pass a stricter `power` closure for that.

| Option | Scaler, tried best first | Runs on | iOS | Picked when |
|---|---|---|---|---|
| `.automatic` | VideoToolbox super resolution, `VTSuperResolutionScalerConfiguration` | Apple's machine-learning model; Apple does not say which compute unit | 26+ | `isSupported`, a factor from `supportedScaleFactors` is within the live-video budget (the output is at most 2560x1440; a scaler that offers only a factor above that, such as 4x of 720p, is skipped and `enhance-probe` says `skipped: only 4x, too costly for live video`), its model is already downloaded, a format the engine converts is accepted and the session starts |
| | VideoToolbox low-latency super resolution, `VTLowLatencySuperResolutionScalerConfiguration` | Apple's real-time machine-learning scaler | 26+ (27 adds 1.5x and size limits) | `isSupported`, a factor from `supportedScaleFactors(frameWidth:frameHeight:)` fits and the frame is within `maximumDimension` and `maximumPixelCount`, a format the engine converts is accepted (BGRA, otherwise 420v) and the session starts |
| | MetalFX spatial scaler, `MTLFXSpatialScaler` | GPU | 16+ | `supportsDevice` |
| | Lanczos-3, the engine's own kernels | GPU | 27+ (package floor) | always: the floor |
| `.lineArt` | the engine's own line-art scaler: Lanczos-3, then edge steepening | GPU | 27+ (package floor) | always; steps down to Lanczos |

Each scaler is set up off the main thread when first needed, the floor first so a picture shows at once, then the
better ones one at a time. The result, the formats and scale factors the device reports and the time taken go to
diagnostics as `enhance-probe`. A scaler that fails to start or fails on a frame is dropped and the next one down
takes over; one that cannot keep up makes the chain step down (`enhance-demote` names the scaler it left). A scaler
that works but is not worth running live on this picture is `skipped`, not `failed`. Both last until the item, the
picture size or the display size changes. The engine never starts Apple's model download:
`VTSuperResolutionScalerConfiguration.configurationModelStatus` says whether the model is there, and the app
downloads it with the user's knowledge.

Pixel formats: the formats a VideoToolbox scaler takes are read from it at run time (`supportedPixelFormats` and the
pixel buffer attributes of its configuration), never assumed. BGRA is used when it is offered, since the chain's own
passes work in it. Otherwise 420v (two-plane 4:2:0, video range, which is also what the player's frames are) is used:
the player's planes are cropped and turned upright into a buffer made to the scaler's requirements (two small GPU
passes), the scaler writes 420v, and one GPU pass turns that into BGRA with the video's own matrix for the rest of
the chain. A format the engine cannot convert on either side fails the scaler with the reason.

Pictures of any size and shape: the player's frames come in the order the video was coded, so the first pass of the
chain (the NV12 to BGRA pass, or the two plane passes for a 420v scaler) also cuts the picture to its clean aperture
and turns it upright by the track's `preferredTransform` (read once when the item is attached; the chain waits for it,
and the plain picture shows until then). Everything after that, the scalers, the size math and the output, sees the
upright picture, so a phone clip shot upright and coded sideways (a 90 or 270 degree transform), a half turn, a mirror,
a cropped 1088-row 1080p picture, a portrait 720x1280 or 1080x1920 clip, a 4:3 clip such as 1440x1080 and small
amateur sizes such as 320x176, 426x240, 854x480, 960x544 and 1016x572 all take the same path. Sizes are made even
(4:2:0 chroma, and scalers that want even sizes, need it): an odd last row or column is cut off and a crop's corner and
size move to even numbers, so at most one pixel a side is lost and nothing is refused for being odd. A quarter turn
inverts the pixel shape (the display buffer's pixel-aspect tag is turned with it), and the fit to the display uses the
upright, even picture with its pixel shape. The matrix guess for an untagged picture looks at the longer and the
shorter side, so a portrait clip gets the same matrix as its landscape twin. What is still refused, with the reason on
the `enhance-picture` line: frames that are not 8-bit 4:2:0 (video range and full range are both drawn), a track transform that is not a
quarter turn or a mirror (a scale or a skew), a turn the track does not explain (the player shows the frames turned and
the track says upright), a frame smaller than 2x2, and HDR (its own reason).

Measured on iPhone 17 Pro (A19 Pro, iOS 27.0.1), a 1280x720 picture on a 2556x1179 display, `.automatic`:

- `vt-super-resolution` offers only 4x (`supportedScaleFactors` is `[4]`); 4x of 720p is 5120x2880, four times the
  engine's output budget. It is not credible at video rate on a phone (Apple publishes no figure), so the engine skips
  it with `skipped: only 4x, too costly for live video` rather than counting it as a failure. A 4x factor is still used
  when the source is small enough that the result fits 2560x1440 (for example 640x360).
- `vt-low-latency` failed before the fix with "it does not take BGRA pictures (it takes 420v)". It now gets 420v, as
  described above. Its speed on the phone is not measured yet.
- `metalfx-spatial` was ready and chosen: 1280x720 to 2144x1206, GPU time 6.9 ms average and 15.2 ms at worst, no late
  frames. It remains the fallback when the VideoToolbox scalers are skipped or fail.
- Dragging a strength slider re-planned on every 0.05 step and, through the governor reset, lost demotions; this is
  fixed as described under API.

**Output layer: `AVSampleBufferDisplayLayer`.** Picture in Picture can take frames from this layer
(`AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:playbackDelegate:)`); a `CAMetalLayer` cannot do
Picture in Picture at all. The chain's BGRA buffers are wrapped in sample buffers marked display-immediately and
enqueued through `sampleBufferRenderer`. To wire Picture in Picture the app can either (1, recommended) keep building
it from its plain `AVPlayerLayer` with `ContentSource(playerLayer:)` and call `setActive(false)` when Picture in
Picture or the background starts, so the window shows the plain picture; or (2) use the enhancer's layer with a
playback delegate that forwards play, pause, skipping and the time range to the AVPlayer. Neither is verified on a
device (E2). Also for the app: give both layers the same frame and `videoGravity`, and tell the enhancer the picture
area in pixels (`displaySize`; empty means the layer's bounds times its `contentsScale`, and an unknown size means no
upscale). A clip the player turns by its `preferredTransform` is recognised from the player item's `presentationSize`
and keeps the plain picture (E3).

Looked at and not used:

- MetalFX temporal, denoised and frame-interpolation scalers, and Metal 4 `MTL4FXSpatialScaler`: they need game data
  (depth, motion) or Metal 4, where the classic spatial scaler works on every supported device.
- VideoToolbox frame-rate conversion, low-latency frame interpolation, motion blur, optical flow and temporal noise
  filter: outside the three stages.
- Core AI, Core ML and MPSGraph upscalers: they need a model the app supplies; none ships in the engine.
- `VTPixelTransferSession`, `MPSImageLanczosScale` and Core Image scaling: no quality gain over the engine's own
  Lanczos, which keeps one pipeline and can be tested on small textures.
- `AVPlayerVideoOutput` (built for stereo content) and `AVPlayerLayer.displayedPixelBuffer()` (deprecated in iOS 27).
- A switch on AVPlayer or `AVPlayerLayer` that enhances for you: none exists. Apple's super-resolution scalers work on
  pixel buffers the app feeds in and draws itself.
- `AVSampleBufferVideoRenderer.recommendedPixelBufferAttributes`: the engine's IOSurface BGRA buffers display
  directly; revisit if device logs show a copy.
- NV12 fed straight from the player to a VideoToolbox scaler without a copy: the scaler wants buffers made to its own
  attributes, and the picture has to be cropped and turned anyway, so the player's planes are read by one GPU pass
  into them (BGRA first when the scaler takes it, 420v only when it does not).
- `AVSampleBufferVideoRenderer.Receiver` (iOS 27): the documentation does not say how to get one, so the engine uses
  the renderer's `enqueue` and `flush`, which iOS 27 still documents (marked deprecated). Switch when the gap closes.

Credits: the sharpen follows the published idea of contrast-adaptive sharpening, the line-art pass the published
shock-filter and Anime4K-style descriptions of edge steepening, and the scaler the textbook Lanczos filter. No
third-party shader source is used, so there are no licence notices to add.

### Diagnostics

- `EngineLogger` carries engine events to the app's log; `.silent` drops them.
- `EngineDiagnostics.report()` returns the recent measured lines for a support
  screen or bug report: `perf-remux` (start-up stages per run), `perf-run`
  (bytes, segments, lead, free memory, thermal state per run), `hw-id` to
  `hw-eng` (first snapshot), `hw-state` (on change) and `hw-probe` (per probe).
- The enhancer's `enhance-*` lines are listed under Enhance picture.
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
| T8 | TrueHD and DTS family with `surroundCodec = .eac3`, one tone per channel | master `CODECS` has `ec-3`; plays from the first segment; each tone on its speaker; AirPods Pro report Dolby |
| T9 | flash-and-beep clip with `shaping.delay` of -0.2, 0 and +0.2 s; then `dialogueLift` 6 and `nightMode` | the beep moves 200 ms earlier and later against the flash; speech louder against effects; loud passages quieter |

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
| S10 | PGS or VobSub MKV with `bitmapSubtitleText` on | "<name> (text from picture)" is listed in `AVPlayerViewController`; its cues match the pictures' text and timing; stays visible in Picture in Picture; with the option off no such track exists |

### Enhance picture

| ID | Steps | Pass |
|---|---|---|
| E1 | 720p SDR on a 1179x2556 phone, `.automatic`, 2 minutes; then 1080p on the same screen | picture stays in step with the audio (within one frame); `enhance-probe` lines show each scaler's result and `enhance-plan` the one in use; the 1080p run skips the scaler |
| E2 | Picture in Picture from the app's player layer while the enhancer runs; then with `ContentSource(sampleBufferDisplayLayer:)` | the window opens and keeps playing; coming back restores the enhanced picture with no frozen frame |
| E3 | rotate the device; play a clip with a rotation transform | the enhancer's layer follows the player layer; the rotated clip is not shown sideways (see E10 for every orientation) |
| E4 | 10 minutes at 60 fps with every stage on, then with the device warmed to `serious` and with Low Power Mode on | audio never breaks; `enhance-perf` shows late and skipped frames; heat or Low Power Mode pauses the chain within a second and the plain picture shows; it resumes when clear |
| E5 | `.automatic` before and after the super-resolution model is downloaded | not downloaded: a lower scaler runs and `enhance-probe` says why; the engine never starts the download |
| E6 | each device class: `enhance-probe` for `vt-super-resolution` and `vt-low-latency`, and the `enhance-rungs` line | `isSupported`, scale factors, pixel formats and start-up time recorded; a scaler that offers only factors above the budget is `skipped` with that reason; a scaler that takes BGRA gets BGRA, one that takes only 420v gets 420v in and out with correct colour and range, otherwise it is skipped with the reason. iPhone 17 Pro (measured): `vt-super-resolution` offers `[4]` and is skipped; `vt-low-latency` took 420v only (to re-run on the fixed build); `metalfx-spatial` 6.9 ms average, 15.2 ms at worst, no late frames |
| E7 | HDR10 and Dolby Vision files with the chain on; pause, resume, seek, background | `unavailable(highDynamicRange)` and no change to the picture; the plain picture is back at once after a seek; the background stops GPU work with no error |
| E8 | 30 minutes at 1080p scaled to 1440p, Instruments allocations | memory flat after the first minute; buffer counts stay within the pool limits; detach frees the pools |
| E9 | on a device where `vt-low-latency` is ready, 2 minutes of 720p, then drag the sharpen slider over its range | `enhance-rungs` says `chosen=vt-low-latency` (or why not); `enhance-perf` GPU time compared with MetalFX; the picture's colours and range match the plain picture; dragging causes no new `enhance-probe` lines and no flicker |
| E10 | a phone clip shot upright (90 or 270 degree transform), one shot upside down (180), a mirrored front-camera clip, a 1088-row clip with a 1080 clean aperture, an odd-sized clip (for example 853x481), and amateur sizes 320x176, 426x240, 854x480, 960x544, 1016x572, 1440x1080 and 720x1280, each with every stage on | every clip is enhanced (not `unavailable`), upright, not stretched, not mirrored, with the right crop; the `enhance-picture` line says coded, shown, crop, turn and pixel shape; the colours match the plain picture; with `vt-low-latency` chosen the rotated clip is also right (the 420v path); a clip with a skewed transform or 10-bit frames is `unavailable(unsupportedPicture)` with the reason on the `enhance-picture` line. To confirm on the device: that the player's frames really arrive in coded order with a transform set, and that a clean-aperture frame carries its aperture and is not already cropped |
