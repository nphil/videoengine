# VideoEngine for Android (stage 1)

Native Kotlin on Media3. One library, `:videoengine` (package `io.github.nphil.videoengine`), and a small test bench,
`:sample`. The contract is `docs/PLATFORMS.md`; this file is how to build, use and test what stage 1 delivers.

| | |
|---|---|
| Player | Media3 **1.11.1**, pinned exactly in `gradle/libs.versions.toml` (ExoPlayer, Inspector, UI for the sample) |
| Min API / compile SDK | 29 / 36 |
| Build | Gradle 9.9.2 (wrapper), AGP 9.5.2, Kotlin 2.4.21, JDK 17 or newer (CI uses 21), Android SDK platform 36. No NDK yet |
| ABIs | `arm64-v8a` and `armeabi-v7a`, set once in `gradle.properties` (`videoengine.abis`). Stage 1 has **no native code**, so the AAR is the same for both; the filters are in place for the FFmpeg extension in stage 3 |
| Licence of what is linked | Apache-2.0 (Media3, AndroidX, kotlinx.coroutines). No FFmpeg, no GPL or LGPL code in stage 1 |

## Build and test

```sh
cd android
./gradlew :videoengine:testDebugUnitTest :videoengine:lintDebug :videoengine:assembleRelease :sample:assembleDebug
```

- Release AAR: `videoengine/build/outputs/aar/videoengine-release.aar` (a release asset, not published to a Maven repository).
- Sample APK: `sample/build/outputs/apk/debug/sample-debug.apk`.
- Unit tests are plain JVM tests, no emulator:
  - `RouteVectorsTest` replays every case of `../shared/route-vectors.json` through `RoutePlanner` (rules 1 to 10 and 4b, the two target devices, synthetic weak and strong snapshots) and checks that each snapshot survives a JSON round trip.
  - `FixtureProbeTest` runs Media3's real Matroska extractor over `../Tests/VideoEngineTests/Fixtures/*.mkv`, maps the result with the production `ProbeMapper` and compares it with `../shared/fixtures/manifest.json` (what ffprobe reports for those files).
  - `HardwareCapabilitiesTest`, `PlatformFactsTest`, `AudioPlannerTest` cover the report format, the power rule, the raw-number conversions and the audio chain.
- CI (`.github/workflows/android.yml`, ubuntu-latest) runs the same Gradle tasks and uploads the artifacts `videoengine-aar` and `videoengine-sample-debug-apk`. It starts only for changes under `android/`, `shared/` or the workflow itself; it never starts the Swift workflows. A change to the fixtures alone does not start it (they live under `Tests/`); the manifest that describes them does.

A rule change edits `docs/PLATFORMS.md` and its vector in `shared/route-vectors.json` in one commit.

## Use it

```kotlin
val provider = LiveHardwareCapabilityProvider(context)        // probes the device once; cached
val caps = provider.snapshot()                                // HardwareCapabilities
val info = MediaProbe.probe(context, uri)                     // suspend; MediaInfo in FFmpeg vocabulary
val verdict = provider.decodeVerdict(VideoStreamFacts("hevc", 3840, 2160, bitDepth = 10, profile = "Main 10"))
val decision = RoutePlanner.decide(info, caps, mapOf(0 to verdict), RouteOptions(audioIndex = null, canRepackage = false))
log(decision.logLine)                                         // route route=directPlay reason=ok
if (decision.route == Route.DirectPlay) {
    val player = EnginePlayer.create(context, caps, PlaybackOptions(matchFrameRate = true, tunneling = false))
    player.setMediaItem(MediaItem.fromUri(uri)); player.prepare(); player.play()
}
```

| Area | Public API |
|---|---|
| Snapshot | `HardwareCapabilities` (`decode`, `encode`, `display`, `audio`, `power`, `compute`, `engine`), `reportLines()`, `toJson()`, `toJsonString()`, `HardwareCapabilities.fromJson(...)`; `Power.shouldShedOptionalWork` (thermal serious or worse, or low-power mode) |
| Providers | `HardwareCapabilityProvider` (`snapshot()`, `decodeVerdict(...)`, `changes()`), `LiveHardwareCapabilityProvider(context, logger)`, `FixedHardwareCapabilityProvider(capabilities, verdict)` for tests |
| Probe | `MediaProbe.probe(context, uri, headers, timeoutSeconds, logger): MediaInfo`; `MediaInfo`, `VideoStreamInfo`, `AudioStreamInfo`, `SubtitleStreamInfo`, `DolbyVisionRecord`, `Dispositions` |
| Route | `RoutePlanner.decide(info, capabilities, verdicts, options): RouteDecision` (pure), `RouteOptions`, `Route` (`DirectPlay`, `Repackage`, `ServerTranscode`, `Error`), `RouteReason` codes, `RouteDecision.logLine` |
| Verdicts, audio | `DecodeVerdict` (`Hardware`, `SoftwareOnly`, `Unsupported`, `Unknown`), `VideoStreamFacts`, `DecodeVerdicts`; `AudioPlanner.resolve(stream, capabilities): AudioPath`, `AudioPathKind` |
| Player | `EnginePlayer.create(context, capabilities | provider, PlaybackOptions, logger): ExoPlayer` |
| Diagnostics | `EngineLogger` (`logcat(tag)`, `Silent`), `EngineDiagnostics.report()`, `VideoEngineError` |

Things worth knowing:

- **Nothing is tuned to a device.** Every capability is read at runtime into one snapshot; `Build.MODEL` only appears in the `hw-id` line. Every decision is a pure function of that snapshot.
- **Decode verdicts come from the snapshot.** `Hardware` means the decoder advertises the stream (codec, profile, size class, frame rate), not that a trial decode worked; the trial configure is stage 2. A stream wider than 3840 counts as the 8K size class (DCI 4K is judged conservatively).
- **`ProbeDepth` is not offered.** Media3's extractors give the same facts in one pass. Media3 does not report the pixel format, so `pixelFormat` is null on Android and rule 2 uses profile and bit depth. Languages come back as the 2-letter tag (`en`), and Media3 may report 8 bit where a Matroska file does not state a depth.
- **`repackage` needs `canRepackage`.** Android has no remux until stage 5, so a container Media3 cannot read (ASF, RealMedia, MXF, NUT, SWF) goes to `serverTranscode` with the reason `container-unreadable`. AVI is read natively.
- Dolby Vision profile 7 plays only through a decoder that lists it; Media3 1.11.1 has no base-layer fallback (`engine.dolbyVision7Fallback` is false in the snapshot).

## Run the sample on a device

1. Install: `adb install -r sample-debug.apk`. For the Onn box connect first (`adb connect <box-ip>:5555`, with developer options and network debugging on). The app is called **VideoEngine sample** and appears in the app list (Google TV: under Apps).
2. The bottom text already shows the capability report, one `hw-*` line per group (`hw-id`, `hw-cpu`, `hw-gpu`, `hw-dec`, `hw-dv`, `hw-fps`, `hw-enc`, `hw-disp`, `hw-pwr`, `hw-aud`, `hw-eng`).
3. Pick each of the three fixtures in the list: it shows the probe and the route the planner picks on this device. **Play** plays it through `EnginePlayer`.
4. **Check probe against manifest** compares every fixture with `manifest.json` and ends with `probe equals manifest.json: PASS (3 files)` or the differences.
5. **Copy device report** copies the report to the clipboard (hardware lines, recent diagnostics, the snapshot as JSON) and also saves it as `/sdcard/Android/data/io.github.nphil.videoengine.sample/files/device-report.txt`.

**Send back:** on the tablet paste the clipboard into a message. On the Onn box (no paste target) run

```sh
adb pull /sdcard/Android/data/io.github.nphil.videoengine.sample/files/device-report.txt
```

and send the file. Also note, from the screen: did each fixture play (picture, sound, subtitles on `hevc10-opus-srt.mkv`), and did the check say PASS. The report answers the open questions of the stage 1 exit gate: Dolby Vision profiles the decoder advertises (`hw-dv`), the Atmos path and `Spatializer` state (`hw-aud`), which Onn generation (`hw-id`, `hw-cpu`).

## Provisional until the device reports are back

`shared/route-vectors.json` contains snapshots of the Xiaomi Pad 8 Pro and the two Onn 4K Pro generations built **only from the facts in `docs/PLATFORMS.md`** and marked `provisional`; each lists what it assumes and what it does not know. The reports replace them in stage 2. Until then a vector on those snapshots shows what the planner would do if the spec sheets are right, nothing more.

## Layout

```
videoengine/src/main/kotlin/...   the library (one file per concern: HardwareCapabilities, PlatformProbe, MediaProbe, ProbeMapper, RoutePlanner, AudioPlanner, EnginePlayer, ...)
videoengine/src/test/             JVM tests; java/android/{os,util} are two small stand-ins for framework classes the unit-test stub leaves empty
sample/                           the test bench; a Gradle copy task puts Tests/VideoEngineTests/Fixtures and shared/fixtures/manifest.json into its assets, so no video is duplicated in git
../shared/route-vectors.json      platform-neutral route vectors and the snapshots they run on (Swift adopts them later)
../shared/fixtures/manifest.json  what ffprobe reports for the fixtures
```
