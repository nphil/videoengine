package io.github.nphil.videoengine

/** An HDR format, for a stream or for what a display accepts. HDR10+ is only ever reported for a display. */
public enum class HdrType(public val code: String) {
    DolbyVision("dv"),
    Hdr10("hdr10"),
    Hlg("hlg"),
    Hdr10Plus("hdr10plus");

    public companion object {
        public fun fromCode(code: String): HdrType? = entries.firstOrNull { it.code == code }
    }
}

/** A Dolby Vision configuration record: the `dvcC` or `dvvC` box, or the `dvhe.08.06` part of a codecs string. */
public data class DolbyVisionRecord(
    /** 5 is single layer with no base layer, 7 dual layer with an HDR10 base, 8 single layer with a cross-compatible base, 10 is AV1. */
    public val profile: Int,
    public val level: Int,
    /** `dv_bl_signal_compatibility_id`: 0 none, 1 HDR10, 2 SDR, 4 HLG. Null when the source does not state it. */
    public val compatibilityId: Int? = null,
)

/** The disposition flags a container states for a stream. */
public data class Dispositions(
    public val isDefault: Boolean = false,
    public val isForced: Boolean = false,
    public val isCommentary: Boolean = false,
    public val isHearingImpaired: Boolean = false,
    /** Audio description for viewers who cannot see the picture. */
    public val isVisualImpaired: Boolean = false,
)

public data class VideoStreamInfo(
    /** Stream index in the container. */
    public val index: Int,
    /** FFmpeg codec name, such as `hevc`, `h264` or `av1`. A Dolby Vision stream reports its base codec. */
    public val codec: String,
    /** FFmpeg profile name, such as `Main 10` or `High`. */
    public val profile: String? = null,
    /** The codec's own level number: H.264 `level_idc` (41 is 4.1), HEVC `general_level_idc` (120 is 4.0). */
    public val level: Int? = null,
    /** FFmpeg pixel format name, such as `yuv420p10le`. Media3 does not state it, so the Android probe leaves it null. */
    public val pixelFormat: String? = null,
    public val width: Int,
    public val height: Int,
    /** Frames per second the container declares. */
    public val frameRate: Double? = null,
    public val bitDepth: Int? = null,
    /** FFmpeg transfer name, `smpte2084` (PQ) or `arib-std-b67` (HLG); null for SDR or when unspecified. */
    public val colorTransfer: String? = null,
    /** FFmpeg primaries name, `bt2020` or `bt709`; null when unspecified. */
    public val colorPrimaries: String? = null,
    /** `tv` (limited) or `pc` (full); null when unspecified. */
    public val colorRange: String? = null,
    public val dolbyVision: DolbyVisionRecord? = null,
    public val dispositions: Dispositions = Dispositions(),
) {
    public val isDefault: Boolean get() = dispositions.isDefault

    /** The HDR format the stream is mastered in; null for SDR. Dolby Vision wins over its HDR10 or HLG base layer. */
    public val hdrType: HdrType?
        get() = when {
            dolbyVision != null -> HdrType.DolbyVision
            colorTransfer == TRANSFER_PQ -> HdrType.Hdr10
            colorTransfer == TRANSFER_HLG -> HdrType.Hlg
            else -> null
        }

    internal companion object {
        const val TRANSFER_PQ = "smpte2084"
        const val TRANSFER_HLG = "arib-std-b67"
    }
}

public data class AudioStreamInfo(
    public val index: Int,
    /** FFmpeg codec name: `aac`, `ac3`, `eac3`, `truehd`, `dts`, `opus`, ... */
    public val codec: String,
    /** FFmpeg profile name, such as `LC`, `DTS-HD MA` or `Dolby Digital Plus + Dolby Atmos`. */
    public val profile: String? = null,
    public val channels: Int,
    /** FFmpeg layout name, such as `stereo` or `5.1`, derived from the channel count. */
    public val channelLayout: String? = null,
    public val sampleRate: Int,
    /** BCP 47 tag as Media3 normalises it (`en`, where FFmpeg says `eng`); null when undetermined. */
    public val language: String? = null,
    public val title: String? = null,
    public val bitRate: Int? = null,
    public val dispositions: Dispositions = Dispositions(),
) {
    public val isDefault: Boolean get() = dispositions.isDefault

    /** Dolby Atmos (E-AC-3 JOC, TrueHD Atmos) or AC-4: handed to the platform untouched, never decoded by the engine. */
    public val isObjectAudio: Boolean
        get() = when (codec) {
            "ac4" -> true
            "eac3", "truehd" -> profile?.contains("Atmos", ignoreCase = true) == true
            else -> false
        }
}

public data class SubtitleStreamInfo(
    public val index: Int,
    /** FFmpeg codec name, such as `subrip`, `ass`, `webvtt` or `hdmv_pgs_subtitle`. */
    public val codec: String,
    public val language: String? = null,
    public val title: String? = null,
    public val dispositions: Dispositions = Dispositions(),
    /** True for picture subtitles (PGS, VobSub, DVB), which are drawn from bitmaps, not text. */
    public val isBitmap: Boolean = false,
) {
    public val isDefault: Boolean get() = dispositions.isDefault
    public val isForced: Boolean get() = dispositions.isForced
}

/** What a probe found in one source, in FFmpeg vocabulary on every platform. */
public data class MediaInfo(
    /** FFmpeg demuxer name, such as `matroska,webm` or `mov,mp4,m4a,3gp,3g2,mj2`. */
    public val container: String,
    /** Seconds; null when the container does not say. */
    public val duration: Double? = null,
    /** Overall bit rate in bits per second, when every stream declares one. */
    public val bitRate: Int? = null,
    public val video: List<VideoStreamInfo> = emptyList(),
    public val audio: List<AudioStreamInfo> = emptyList(),
    public val subtitles: List<SubtitleStreamInfo> = emptyList(),
)
