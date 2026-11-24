package io.github.nphil.videoengine

/** What to do with a source. */
public enum class Route(public val code: String) {
    /** The platform player opens the container and codecs as they are. */
    DirectPlay("directPlay"),

    /** Copy the streams into a container the player reads. Not offered by the Android engine before stage 5. */
    Repackage("repackage"),

    /** The media server converts what this device cannot play. */
    ServerTranscode("serverTranscode"),

    /** Nothing in the source can play (rule 1); callers surface [VideoEngineError.NoPlayableStreams]. */
    Error("error"),
}

/** Why a route was chosen: the reason codes of `docs/PLATFORMS.md` section 2.2, in the order the rules are tried. */
public enum class RouteReason(public val code: String) {
    NoStreams("no-streams"),
    UnsupportedVideo("unsupported-video"),
    HdrDisplayMissing("hdr-display-missing"),
    Dv5Unsupported("dv5-unsupported"),

    /** A Dolby Vision profile other than 5 that no decoder lists and the player cannot play through its base layer. */
    DvUnsupported("dv-unsupported"),
    SoftwareDecodeTooHeavy("software-decode-too-heavy"),
    AudioUnplayable("audio-unplayable"),
    Ok("ok"),
    ContainerUnreadable("container-unreadable"),
    ExternalPlayback("external-playback"),
    Fallback("fallback");

    public companion object {
        public fun fromCode(code: String): RouteReason? = entries.firstOrNull { it.code == code }
    }
}

public data class RouteDecision(public val route: Route, public val reason: RouteReason) {
    /** The log and report line: `route route=<r> reason=<code>`. */
    public val logLine: String get() = "route route=${route.code} reason=${reason.code}"
}

/** Inputs to the route choice that are neither the source nor the device. */
public data class RouteOptions(
    /** The audio stream the viewer chose; null picks the default stream, else the first. */
    public val audioIndex: Int? = null,
    /** Whether this build can copy streams into a readable container. False on Android until stage 5. */
    public val canRepackage: Boolean = false,
)

/**
 * Route choice as one pure function of the probe facts, the hardware snapshot and decode verdicts: no I/O, no
 * clock, no device query, so a JVM test replays every case from `shared/route-vectors.json`. First match wins;
 * the rule numbers are those of `docs/PLATFORMS.md` section 2.2.
 */
public object RoutePlanner {
    /**
     * @param verdicts decode verdicts by video stream index. A stream without one gets
     * [DecodeVerdicts.verdict] over [capabilities], so a caller passes only what it measured itself.
     */
    public fun decide(
        info: MediaInfo,
        capabilities: HardwareCapabilities,
        verdicts: Map<Int, DecodeVerdict> = emptyMap(),
        options: RouteOptions = RouteOptions(),
    ): RouteDecision {
        val video = info.video.firstOrNull()
        val audio = selectedAudio(info, options)

        // 1
        if (video == null && audio == null) return RouteDecision(Route.Error, RouteReason.NoStreams)

        if (video != null) {
            // 2
            val pixelFormat = video.pixelFormat
            if (pixelFormat != null && !isPlayablePixelFormat(pixelFormat)) return transcode(RouteReason.UnsupportedVideo)
            val verdict = verdicts[video.index] ?: DecodeVerdicts.verdict(capabilities, VideoStreamFacts.of(video))
            if (verdict == DecodeVerdict.Unsupported) return transcode(RouteReason.UnsupportedVideo)

            // 3
            val display = capabilities.display
            val hdr = video.hdrType
            if (hdr != null && !display.hdrPlaybackEligible) return transcode(RouteReason.HdrDisplayMissing)
            if ((hdr == HdrType.Hdr10 || hdr == HdrType.Hlg) && !display.accepts(hdr)) {
                return transcode(RouteReason.HdrDisplayMissing)
            }

            // 4, 4b
            video.dolbyVision?.let { record -> dolbyVisionDecision(record, video, capabilities)?.let { return it } }

            // 5
            if (verdict == DecodeVerdict.SoftwareOnly && isHeavy(video)) return transcode(RouteReason.SoftwareDecodeTooHeavy)
        }

        // 6
        if (audio != null && AudioPlanner.resolve(audio, capabilities).kind == AudioPathKind.None) {
            return transcode(RouteReason.AudioUnplayable)
        }

        // 7
        val container = info.container
        if (container in READABLE_CONTAINERS) return RouteDecision(Route.DirectPlay, RouteReason.Ok)

        // 8, 9
        if (container in UNREADABLE_CONTAINERS) {
            if (!options.canRepackage) return transcode(RouteReason.ContainerUnreadable)
            if (capabilities.display.externalPlaybackActive) return transcode(RouteReason.ExternalPlayback)
            return RouteDecision(Route.Repackage, RouteReason.ContainerUnreadable)
        }

        // 10
        return transcode(RouteReason.Fallback)
    }

    private fun transcode(reason: RouteReason) = RouteDecision(Route.ServerTranscode, reason)

    private fun selectedAudio(info: MediaInfo, options: RouteOptions): AudioStreamInfo? =
        options.audioIndex?.let { wanted -> info.audio.firstOrNull { it.index == wanted } }
            ?: info.audio.firstOrNull { it.isDefault }
            ?: info.audio.firstOrNull()

    /**
     * Rules 4 and 4b. Native Dolby Vision needs a decoder that lists the profile and a DV display. Without it
     * profile 5, which has no base layer, goes to the server; profile 8 (and profile 7 where the player falls back
     * to the HEVC base layer) plays its base layer if the display shows it; anything else cannot play.
     */
    private fun dolbyVisionDecision(
        record: DolbyVisionRecord,
        video: VideoStreamInfo,
        capabilities: HardwareCapabilities,
    ): RouteDecision? {
        val display = capabilities.display
        if (DecodeVerdicts.hasDolbyVisionDecoder(capabilities, record.profile) && display.accepts(HdrType.DolbyVision)) return null
        if (record.profile == 5) return transcode(RouteReason.Dv5Unsupported)
        val playsBaseLayer = when (record.profile) {
            7 -> capabilities.engine.dolbyVision7Fallback
            8 -> true
            else -> false
        }
        if (!playsBaseLayer) return transcode(RouteReason.DvUnsupported)
        return if (baseLayerShows(record, video, display)) null else transcode(RouteReason.HdrDisplayMissing)
    }

    /**
     * Whether the display shows the base layer correctly. A profile 8 file that does not state its base layer is
     * taken as 8.1 (HDR10), the common case, unless its transfer says HLG.
     */
    private fun baseLayerShows(record: DolbyVisionRecord, video: VideoStreamInfo, display: HardwareCapabilities.Display): Boolean =
        when {
            record.profile == 7 -> display.accepts(HdrType.Hdr10)
            record.compatibilityId == 2 -> true
            record.compatibilityId == 4 -> display.accepts(HdrType.Hlg)
            record.compatibilityId == 1 -> display.accepts(HdrType.Hdr10)
            video.colorTransfer == VideoStreamInfo.TRANSFER_HLG -> display.accepts(HdrType.Hlg)
            else -> display.accepts(HdrType.Hdr10)
        }

    /** Rule 5: above 1080p or 30 fps; a stream that states no frame rate is within the limit. */
    private fun isHeavy(video: VideoStreamInfo): Boolean =
        video.width > 1920 || video.height > 1080 || (video.frameRate ?: 0.0) > 30.01

    /** 4:2:0 at 8 or 10 bit, in FFmpeg's pixel format vocabulary. */
    private fun isPlayablePixelFormat(name: String): Boolean = PLAYABLE_PIXEL_FORMAT.matches(name)

    private val PLAYABLE_PIXEL_FORMAT = Regex("^(yuvj?420p(10(le|be))?|nv12|nv21|p010(le|be)?)$")

    /** FFmpeg demuxer names Media3's extractors read (`DefaultExtractorsFactory`, 1.11.1, which includes AVI). */
    internal val READABLE_CONTAINERS: Set<String> = setOf(
        "matroska,webm",
        "mov,mp4,m4a,3gp,3g2,mj2",
        "mpegts",
        "mpeg",
        "flv",
        "ogg",
        "wav",
        "mp3",
        "flac",
        "aac",
        "ac3",
        "eac3",
        "amr",
        "avi",
    )

    /** Containers the player does not read and the engine knows by name. */
    internal val UNREADABLE_CONTAINERS: Set<String> = setOf("asf", "rm", "mxf", "nut", "swf")
}
