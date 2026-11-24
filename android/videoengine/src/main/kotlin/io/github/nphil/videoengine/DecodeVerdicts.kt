package io.github.nphil.videoengine

import io.github.nphil.videoengine.HardwareCapabilities.Mime
import io.github.nphil.videoengine.HardwareCapabilities.VideoDecoder

/** Whether this device decodes a stream in hardware. */
public enum class DecodeVerdict(public val code: String) {
    /** A decoder the manufacturer marks hardware accelerated lists the stream's profile and size. */
    Hardware("hardware"),

    /** Only a software decoder does. */
    SoftwareOnly("softwareOnly"),

    /** No decoder lists it. */
    Unsupported("unsupported"),

    /** The decoder list says nothing true (an emulator). */
    Unknown("unknown");

    public companion object {
        public fun fromCode(code: String): DecodeVerdict? = entries.firstOrNull { it.code == code }
    }
}

/** The facts of one video stream that decide a decoder's answer. */
public data class VideoStreamFacts(
    /** FFmpeg codec name as [VideoStreamInfo.codec] reports it. */
    public val codec: String,
    public val width: Int,
    public val height: Int,
    public val bitDepth: Int = 8,
    /** FFmpeg profile name, such as `Main 10`. */
    public val profile: String? = null,
    public val level: Int? = null,
    public val frameRate: Double? = null,
    /** The Dolby Vision profile number when the stream carries a record. */
    public val dolbyVisionProfile: Int? = null,
) {
    /**
     * Codec, profile, level, size class and bit depth, as on Apple, plus the frame-rate bucket and the Dolby
     * Vision profile: an Android decoder's answer also depends on the rate and on the DV decoder.
     */
    internal val cacheKey: String
        get() {
            val fps = when {
                frameRate == null -> "?"
                frameRate <= 30.5 -> "30"
                frameRate <= 60.5 -> "60"
                frameRate <= 120.5 -> "120"
                else -> "240"
            }
            val dv = dolbyVisionProfile?.let { "-dv$it" }.orEmpty()
            return "$codec-${profile ?: -1}-${level ?: -1}-${SizeClass.of(width, height).code}-$bitDepth-$fps$dv"
        }

    public companion object {
        public fun of(stream: VideoStreamInfo): VideoStreamFacts = VideoStreamFacts(
            codec = stream.codec,
            width = stream.width,
            height = stream.height,
            bitDepth = stream.bitDepth ?: 8,
            profile = stream.profile,
            level = stream.level,
            frameRate = stream.frameRate,
            dolbyVisionProfile = stream.dolbyVision?.profile,
        )
    }
}

/**
 * The decode verdict as a pure function of the snapshot. A hardware verdict is what the decoder *advertises*:
 * `MediaCodecInfo.isHardwareAccelerated` is the manufacturer's word and Android offers no way to test it, so a
 * first decoded frame is the proof and a trial `configure` comes with stage 2.
 */
public object DecodeVerdicts {
    public fun verdict(capabilities: HardwareCapabilities, facts: VideoStreamFacts): DecodeVerdict =
        verdict(capabilities.decode, facts)

    /** The same from just the decoder list, the only part of a snapshot a verdict reads. */
    public fun verdict(decode: HardwareCapabilities.Decode, facts: VideoStreamFacts): DecodeVerdict {
        if (!decode.representative) return DecodeVerdict.Unknown
        val mime = androidMime(facts.codec) ?: return DecodeVerdict.Unsupported
        val required = requiredProfiles(facts)
        val dolbyVision = facts.dolbyVisionProfile?.let(::dolbyVisionProfileName)
        var best = DecodeVerdict.Unsupported
        for (row in decode.video) {
            val fits = when {
                row.mimeType == mime -> (required == null || row.profiles.any { it in required }) && sizeFits(row, facts)
                dolbyVision != null && row.mimeType == Mime.DOLBY_VISION -> dolbyVision in row.profiles && sizeFits(row, facts)
                else -> false
            }
            if (!fits) continue
            if (row.isHardware) return DecodeVerdict.Hardware
            best = DecodeVerdict.SoftwareOnly
        }
        return best
    }

    /**
     * True when a decoder in the snapshot lists Dolby Vision [profile], in hardware or software. The planner
     * uses it for rules 4 and 4b: a DV-capable decoder, not a DV-capable display, is what plays the layers.
     */
    internal fun hasDolbyVisionDecoder(capabilities: HardwareCapabilities, profile: Int): Boolean {
        val name = dolbyVisionProfileName(profile) ?: return false
        return capabilities.decode.video.any { it.mimeType == Mime.DOLBY_VISION && name in it.profiles }
    }

    private fun sizeFits(row: VideoDecoder, facts: VideoStreamFacts): Boolean {
        val max = row.maxFps[SizeClass.of(facts.width, facts.height)] ?: return false
        if (max <= 0) return false
        val fps = facts.frameRate ?: return true
        return fps <= max + 0.5
    }

    /** The Android MIME type of a decoder for an FFmpeg codec name; null when Android names none. */
    internal fun androidMime(codec: String): String? = when (codec) {
        "h264" -> Mime.H264
        "hevc" -> Mime.HEVC
        "av1" -> Mime.AV1
        "vp9" -> Mime.VP9
        "vp8" -> Mime.VP8
        "mpeg2video" -> Mime.MPEG2
        "mpeg4" -> Mime.MPEG4
        "h263" -> "video/3gpp"
        "vc1" -> "video/wvc1"
        "mpeg1video" -> "video/mpeg"
        "mjpeg" -> "video/mjpeg"
        else -> null
    }

    /**
     * The decoder profiles that can decode a stream beyond the baseline every decoder of its codec has: null means
     * no check, an empty set means no decoder profile exists for it. Profile names are `CodecProfileLevel`'s.
     */
    internal fun requiredProfiles(facts: VideoStreamFacts): Set<String>? {
        if (facts.bitDepth >= 12) return emptySet()
        val profile = facts.profile.orEmpty()
        val tenBit = facts.bitDepth >= 10
        return when (facts.codec) {
            "h264" -> when {
                profile.startsWith("High 4:4:4") || profile.startsWith("CAVLC 4:4:4") -> setOf("High444")
                profile.startsWith("High 4:2:2") -> setOf("High422", "High444")
                profile.startsWith("High 10") || (facts.profile == null && tenBit) -> setOf("High10", "High422", "High444")
                else -> null
            }
            "hevc" -> when {
                profile == "Main 10" || (facts.profile == null && tenBit) -> HardwareCapabilities.Profiles.HEVC_10_BIT
                profile == "Main" || profile == "Main Still Picture" || facts.profile == null -> null
                else -> emptySet() // Rext, SCC: 4:2:2, 4:4:4 and screen content have no profile constant here
            }
            "av1" -> when {
                profile == "High" || profile == "Professional" -> emptySet()
                tenBit -> setOf("Main10", "Main10HDR10", "Main10HDR10Plus")
                else -> null
            }
            "vp9" -> when {
                profile == "Profile 1" -> setOf("Profile1")
                profile == "Profile 3" -> setOf("Profile3", "Profile3HDR", "Profile3HDR10Plus")
                profile == "Profile 2" || tenBit -> setOf("Profile2", "Profile2HDR", "Profile2HDR10Plus")
                else -> null
            }
            else -> null
        }
    }

    /**
     * The `CodecProfileLevel.DolbyVisionProfile*` name for a Dolby Vision profile number. Only profiles 5
     * (`DvheStn`) and 7 (`DvheDtb`) are confirmed against a real device report so far; the rest follow Dolby's
     * numbering and are provisional until a device lists them.
     */
    internal fun dolbyVisionProfileName(profile: Int): String? = when (profile) {
        4 -> "DvheDtr"
        5 -> "DvheStn"
        6 -> "DvheDth"
        7 -> "DvheDtb"
        8 -> "DvheSt"
        9 -> "DvavSe"
        10 -> "Dvav110"
        else -> null
    }
}
