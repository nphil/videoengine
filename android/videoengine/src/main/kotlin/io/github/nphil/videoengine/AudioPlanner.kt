package io.github.nphil.videoengine

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi

/**
 * The audio formats the snapshot and the planner talk about, by a short code that is the same on every
 * platform and in the JSON files: `ac3`, `eac3`, `eac3joc` (E-AC-3 with Dolby Atmos), `ac4`, `truehd`, `dts`,
 * `dtshd`, `dtsuhd` (DTS:X profile 2), plus the decode-only codes below.
 */
@OptIn(UnstableApi::class)
public object AudioFormats {
    internal class Entry(val code: String, val mimeType: String, val encoding: Int?)

    private val entries: List<Entry> = listOf(
        Entry("ac3", MimeTypes.AUDIO_AC3, C.ENCODING_AC3),
        Entry("eac3", MimeTypes.AUDIO_E_AC3, C.ENCODING_E_AC3),
        Entry("eac3joc", MimeTypes.AUDIO_E_AC3_JOC, C.ENCODING_E_AC3_JOC),
        Entry("ac4", MimeTypes.AUDIO_AC4, C.ENCODING_AC4),
        Entry("truehd", MimeTypes.AUDIO_TRUEHD, C.ENCODING_DOLBY_TRUEHD),
        Entry("dts", MimeTypes.AUDIO_DTS, C.ENCODING_DTS),
        Entry("dtshd", MimeTypes.AUDIO_DTS_HD, C.ENCODING_DTS_HD),
        Entry("dtsuhd", MimeTypes.AUDIO_DTS_UHD_P2, C.ENCODING_DTS_UHD_P2),
        Entry("aac", MimeTypes.AUDIO_AAC, null),
        Entry("opus", MimeTypes.AUDIO_OPUS, null),
        Entry("vorbis", MimeTypes.AUDIO_VORBIS, null),
        Entry("flac", MimeTypes.AUDIO_FLAC, null),
        Entry("mp3", MimeTypes.AUDIO_MPEG, null),
        Entry("mp2", MimeTypes.AUDIO_MPEG_L2, null),
        Entry("alac", MimeTypes.AUDIO_ALAC, null),
        Entry("amrnb", MimeTypes.AUDIO_AMR_NB, null),
        Entry("amrwb", MimeTypes.AUDIO_AMR_WB, null),
        Entry("alaw", MimeTypes.AUDIO_ALAW, null),
        Entry("mulaw", MimeTypes.AUDIO_MLAW, null),
    )

    /** The codes of formats an audio output can take as a bitstream, in the order a report lists them. */
    public val passthroughCodes: List<String> = entries.filter { it.encoding != null }.map { it.code }

    internal val passthroughEntries: List<Entry> get() = entries.filter { it.encoding != null }

    /** The code of a stream, or null for a codec the planner knows no code for (PCM has none). */
    internal fun codeFor(stream: AudioStreamInfo): String? = when (stream.codec) {
        "aac" -> "aac"
        "ac3" -> "ac3"
        "eac3" -> if (stream.profile?.contains("Atmos", ignoreCase = true) == true) "eac3joc" else "eac3"
        "ac4" -> "ac4"
        "truehd" -> "truehd"
        "dts" -> when (stream.profile) {
            "DTS-UHD" -> "dtsuhd"
            "DTS-HD MA", "DTS-HD MA + DTS:X", "DTS-HD HRA", "DTS Express" -> "dtshd"
            else -> "dts"
        }
        "opus" -> "opus"
        "vorbis" -> "vorbis"
        "flac" -> "flac"
        "mp3" -> "mp3"
        "mp2" -> "mp2"
        "alac" -> "alac"
        "amr_nb" -> "amrnb"
        "amr_wb" -> "amrwb"
        "pcm_alaw" -> "alaw"
        "pcm_mulaw" -> "mulaw"
        else -> null
    }

    /** Codes of the platform decoders in [decoders], sorted. Decoders for other MIME types are not listed. */
    internal fun decoderCodes(decoders: List<HardwareCapabilities.AudioDecoder>): List<String> {
        val byMime = entries.associate { it.mimeType to it.code }
        return decoders.mapNotNull { byMime[it.mimeType] }.distinct().sorted()
    }

    internal fun mimeTypeOf(code: String): String? = entries.firstOrNull { it.code == code }?.mimeType

    /** An E-AC-3 stream with Atmos, the probe for the report's `atmos=` field. */
    internal val ATMOS_PROBE = AudioStreamInfo(
        index = 0,
        codec = "eac3",
        profile = "Dolby Digital Plus + Dolby Atmos",
        channels = 6,
        channelLayout = "5.1",
        sampleRate = 48_000,
    )
}

/** How audio reaches the speakers. */
public enum class AudioPathKind(public val code: String) {
    /** The compressed bitstream goes to the output untouched. */
    Passthrough("passthrough"),

    /** A decoder the platform provides turns it into PCM. */
    PlatformDecoder("decoder"),

    /** The player reads it as PCM itself: no decoder. */
    Builtin("builtin"),

    /** A decoder the engine bundles (FFmpeg, from stage 3). */
    ExtensionDecoder("extension"),

    /** Nothing on this device plays it. */
    None("none"),
}

/**
 * The path one audio stream takes, and whether it arrives whole. [degraded] is true when the path drops part
 * of the stream: Dolby Atmos objects reduced to the E-AC-3 core, or DTS-HD to its DTS core.
 */
public data class AudioPath(public val kind: AudioPathKind, public val degraded: Boolean = false) {
    /** The `atmos=` token of the report: the path name, `core` when only the core plays, `none` when nothing does. */
    internal val summary: String
        get() = when {
            kind == AudioPathKind.None -> "none"
            degraded -> "core"
            else -> kind.code
        }
}

/**
 * Rule 6 of the route table: which path plays an audio stream on this device, keeping the bitstream whenever
 * the output can take it. Dolby Atmos (E-AC-3 JOC, AC-4, TrueHD) only ever goes to passthrough or a platform
 * decoder and is never decoded by the engine's own software decoders.
 */
public object AudioPlanner {
    public fun resolve(stream: AudioStreamInfo, capabilities: HardwareCapabilities): AudioPath {
        if (stream.codec.startsWith("pcm_") && stream.codec != "pcm_alaw" && stream.codec != "pcm_mulaw") {
            return AudioPath(AudioPathKind.Builtin)
        }
        val code = AudioFormats.codeFor(stream) ?: return AudioPath(AudioPathKind.None)
        val passthrough = capabilities.audio.passthrough
        val decoders = AudioFormats.decoderCodes(capabilities.decode.audio).toSet()
        // Best first: the stream's own format, then the core it carries.
        val chain = when (code) {
            "eac3joc" -> listOf("eac3joc", "eac3")
            "dtsuhd" -> listOf("dtsuhd", "dts")
            "dtshd" -> listOf("dtshd", "dts")
            else -> listOf(code)
        }
        chain.forEachIndexed { position, candidate ->
            val degraded = position > 0
            if (candidate in passthrough) return AudioPath(AudioPathKind.Passthrough, degraded)
            if (candidate in decoders) return AudioPath(AudioPathKind.PlatformDecoder, degraded)
        }
        if (!stream.isObjectAudio && code in capabilities.engine.softwareAudio) {
            return AudioPath(AudioPathKind.ExtensionDecoder)
        }
        return AudioPath(AudioPathKind.None)
    }
}
