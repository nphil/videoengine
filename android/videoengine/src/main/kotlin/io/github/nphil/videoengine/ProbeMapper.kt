package io.github.nphil.videoengine

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.ColorInfo
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi

/**
 * Turns the formats Media3's extractors report into a [MediaInfo] in FFmpeg vocabulary. Pure: no I/O, so the
 * JVM tests run it over real extractor output.
 */
@OptIn(UnstableApi::class)
internal object ProbeMapper {
    /**
     * @param formats one entry per track, in container order; the position is the stream index.
     * @param durationUs the container duration, or [C.TIME_UNSET].
     * @param fileName the source's file name, used for the container name when no track states a container type.
     */
    fun map(formats: List<Format>, durationUs: Long, fileName: String? = null): MediaInfo {
        val video = ArrayList<VideoStreamInfo>()
        val audio = ArrayList<AudioStreamInfo>()
        val subtitles = ArrayList<SubtitleStreamInfo>()
        var declaredBitRate = 0L
        var allDeclared = true
        formats.forEachIndexed { index, format ->
            val mime = format.sampleMimeType ?: return@forEachIndexed
            val known = when {
                MimeTypes.isVideo(mime) -> video.add(videoStream(index, format))
                MimeTypes.isAudio(mime) -> audio.add(audioStream(index, format))
                MimeTypes.isText(mime) -> subtitles.add(subtitleStream(index, format))
                else -> false
            }
            if (known) {
                if (format.averageBitrate > 0) declaredBitRate += format.averageBitrate else allDeclared = false
            }
        }
        return MediaInfo(
            container = containerName(formats, fileName),
            duration = if (durationUs != C.TIME_UNSET && durationUs > 0) durationUs / 1_000_000.0 else null,
            bitRate = if (allDeclared && declaredBitRate in 1..Int.MAX_VALUE) declaredBitRate.toInt() else null,
            video = video,
            audio = audio,
            subtitles = subtitles,
        )
    }

    // MARK: Container

    fun containerName(formats: List<Format>, fileName: String?): String {
        val mime = formats.firstNotNullOfOrNull { it.containerMimeType }
        val byMime = when (mime) {
            null -> null
            MimeTypes.VIDEO_MATROSKA, MimeTypes.AUDIO_MATROSKA, MimeTypes.VIDEO_WEBM, MimeTypes.AUDIO_WEBM -> MATROSKA
            MimeTypes.VIDEO_MP4, MimeTypes.AUDIO_MP4, MimeTypes.APPLICATION_MP4, "video/quicktime" -> MP4
            MimeTypes.VIDEO_MP2T -> "mpegts"
            MimeTypes.VIDEO_PS -> "mpeg"
            MimeTypes.VIDEO_FLV -> "flv"
            MimeTypes.VIDEO_AVI -> "avi"
            MimeTypes.AUDIO_OGG -> "ogg"
            MimeTypes.AUDIO_WAV -> "wav"
            MimeTypes.AUDIO_FLAC -> "flac"
            MimeTypes.AUDIO_AMR -> "amr"
            MimeTypes.AUDIO_MPEG -> "mp3"
            MimeTypes.AUDIO_AC3 -> "ac3"
            MimeTypes.AUDIO_E_AC3 -> "eac3"
            else -> null
        }
        return byMime ?: byExtension(fileName) ?: "unknown"
    }

    private fun byExtension(fileName: String?): String? {
        val extension = fileName?.substringAfterLast('.', "")?.lowercase().orEmpty()
        return when (extension) {
            "mkv", "mka", "mk3d", "webm" -> MATROSKA
            "mp4", "m4v", "m4a", "mov", "3gp", "3g2", "mj2" -> MP4
            "ts", "m2ts", "mts" -> "mpegts"
            "mpg", "mpeg", "vob" -> "mpeg"
            "flv" -> "flv"
            "ogg", "oga", "ogv", "opus" -> "ogg"
            "avi" -> "avi"
            "wav" -> "wav"
            "flac" -> "flac"
            "mp3" -> "mp3"
            "aac" -> "aac"
            "ac3" -> "ac3"
            "eac3" -> "eac3"
            "amr" -> "amr"
            else -> null
        }
    }

    const val MATROSKA = "matroska,webm"
    const val MP4 = "mov,mp4,m4a,3gp,3g2,mj2"

    // MARK: Video

    private fun videoStream(index: Int, format: Format): VideoStreamInfo {
        val mime = format.sampleMimeType.orEmpty()
        val dolbyVision = if (mime == MimeTypes.VIDEO_DOLBY_VISION) parseDolbyVision(format.codecs) else null
        val codec = videoCodecName(mime, format.codecs)
        val (profile, level) = when (codec) {
            "h264" -> parseAvc(format.codecs)
            "hevc" -> parseHevc(format.codecs)
            "av1" -> parseAv1(format.codecs)
            "vp9" -> parseVp9(format.codecs)
            else -> null to null
        }
        val color = format.colorInfo
        return VideoStreamInfo(
            index = index,
            codec = codec,
            profile = profile,
            level = level,
            width = format.width.coerceAtLeast(0),
            height = format.height.coerceAtLeast(0),
            frameRate = format.frameRate.takeIf { it > 0f }?.let { Math.round(it * 1000.0) / 1000.0 },
            bitDepth = color?.lumaBitdepth?.takeIf { it > 0 } ?: bitDepthFromCodecs(codec, format.codecs),
            colorTransfer = color?.let(::transferName),
            colorPrimaries = color?.let(::primariesName),
            colorRange = color?.let(::rangeName),
            dolbyVision = dolbyVision,
            dispositions = dispositions(format),
        )
    }

    private fun videoCodecName(mime: String, codecs: String?): String = when (mime) {
        MimeTypes.VIDEO_H264 -> "h264"
        MimeTypes.VIDEO_H265 -> "hevc"
        MimeTypes.VIDEO_AV1 -> "av1"
        MimeTypes.VIDEO_VP9 -> "vp9"
        MimeTypes.VIDEO_VP8 -> "vp8"
        MimeTypes.VIDEO_MPEG2 -> "mpeg2video"
        MimeTypes.VIDEO_MPEG -> "mpeg1video"
        MimeTypes.VIDEO_MP4V -> "mpeg4"
        MimeTypes.VIDEO_H263 -> "h263"
        MimeTypes.VIDEO_VC1 -> "vc1"
        MimeTypes.VIDEO_MJPEG -> "mjpeg"
        MimeTypes.VIDEO_DOLBY_VISION -> when (codecs?.substringBefore('.')?.lowercase()) {
            "dvav", "dva1" -> "h264"
            "dav1" -> "av1"
            else -> "hevc"
        }
        else -> mime.substringAfter('/')
    }

    private fun transferName(color: ColorInfo): String? = when (color.colorTransfer) {
        C.COLOR_TRANSFER_ST2084 -> VideoStreamInfo.TRANSFER_PQ
        C.COLOR_TRANSFER_HLG -> VideoStreamInfo.TRANSFER_HLG
        C.COLOR_TRANSFER_LINEAR -> "linear"
        C.COLOR_TRANSFER_GAMMA_2_2 -> "gamma22"
        C.COLOR_TRANSFER_SRGB -> "iec61966-2-1"
        // C.COLOR_TRANSFER_SDR stands for BT.709, BT.601 and SMPTE 170M alike; naming one would be false precision.
        else -> null
    }

    private fun primariesName(color: ColorInfo): String? = when (color.colorSpace) {
        C.COLOR_SPACE_BT2020 -> "bt2020"
        C.COLOR_SPACE_BT709 -> "bt709"
        // C.COLOR_SPACE_BT601 covers two sets of primaries.
        else -> null
    }

    private fun rangeName(color: ColorInfo): String? = when (color.colorRange) {
        C.COLOR_RANGE_LIMITED -> "tv"
        C.COLOR_RANGE_FULL -> "pc"
        else -> null
    }

    /** H.264: `avc1.PPCCLL`, profile_idc, constraint flags and level_idc in hex. */
    fun parseAvc(codecs: String?): Pair<String?, Int?> {
        val hex = codecToken(codecs, "avc1.", "avc2.", "avc3.", "avc4.")?.substringAfter('.') ?: return null to null
        if (hex.length < 6) return null to null
        val profileIdc = hex.substring(0, 2).toIntOrNull(16) ?: return null to null
        val flags = hex.substring(2, 4).toIntOrNull(16) ?: 0
        val level = hex.substring(4, 6).toIntOrNull(16)
        val intra = flags and 0x10 != 0 // constraint_set3
        val name = when (profileIdc) {
            66 -> if (flags and 0x40 != 0) "Constrained Baseline" else "Baseline"
            77 -> "Main"
            88 -> "Extended"
            100 -> "High"
            110 -> if (intra) "High 10 Intra" else "High 10"
            122 -> if (intra) "High 4:2:2 Intra" else "High 4:2:2"
            244 -> if (intra) "High 4:4:4 Intra" else "High 4:4:4 Predictive"
            44 -> "CAVLC 4:4:4"
            118 -> "Multiview High"
            128 -> "Stereo High"
            else -> null
        }
        return name to level
    }

    /** HEVC: `hvc1.2.4.L93.B0`, general_profile_idc and tier plus general_level_idc. */
    fun parseHevc(codecs: String?): Pair<String?, Int?> {
        val parts = codecToken(codecs, "hvc1.", "hev1.")?.split('.') ?: return null to null
        val profileIdc = parts.getOrNull(1)?.trimStart('A', 'B', 'C', 'a', 'b', 'c')?.toIntOrNull()
        val level = parts.getOrNull(3)?.drop(1)?.toIntOrNull()
        val name = when (profileIdc) {
            1 -> "Main"
            2 -> "Main 10"
            3 -> "Main Still Picture"
            4 -> "Rext"
            9 -> "SCC"
            else -> null
        }
        return name to level
    }

    /** AV1: `av01.0.08M.10`, seq_profile and seq_level_idx. */
    fun parseAv1(codecs: String?): Pair<String?, Int?> {
        val parts = codecToken(codecs, "av01.")?.split('.') ?: return null to null
        val name = when (parts.getOrNull(1)?.toIntOrNull()) {
            0 -> "Main"
            1 -> "High"
            2 -> "Professional"
            else -> null
        }
        return name to parts.getOrNull(2)?.takeWhile { it.isDigit() }?.toIntOrNull()
    }

    /** VP9: `vp09.02.10.10`, profile; the level is not one FFmpeg reports, so it stays null. */
    fun parseVp9(codecs: String?): Pair<String?, Int?> {
        val parts = codecToken(codecs, "vp09.")?.split('.') ?: return null to null
        val name = parts.getOrNull(1)?.toIntOrNull()?.takeIf { it in 0..3 }?.let { "Profile $it" }
        return name to null
    }

    /** AV1 (`av01.0.08M.10`) and VP9 (`vp09.02.10.10`) state the bit depth in their codecs string. */
    private fun bitDepthFromCodecs(codec: String, codecs: String?): Int? = when (codec) {
        "av1" -> codecToken(codecs, "av01.")?.split('.')?.getOrNull(3)?.toIntOrNull()
        "vp9" -> codecToken(codecs, "vp09.")?.split('.')?.getOrNull(3)?.toIntOrNull()
        else -> null
    }

    /** Dolby Vision: `dvhe.08.06`, profile and level; the compatibility id is not in a codecs string. */
    fun parseDolbyVision(codecs: String?): DolbyVisionRecord? {
        val parts = codecToken(codecs, "dvhe.", "dvh1.", "dvav.", "dva1.", "dav1.")?.split('.') ?: return null
        val profile = parts.getOrNull(1)?.toIntOrNull() ?: return null
        val level = parts.getOrNull(2)?.takeWhile { it.isDigit() }?.toIntOrNull() ?: return null
        return DolbyVisionRecord(profile = profile, level = level)
    }

    private fun codecToken(codecs: String?, vararg prefixes: String): String? =
        codecs?.split(',')?.map { it.trim() }?.firstOrNull { token -> prefixes.any { token.startsWith(it, ignoreCase = true) } }

    // MARK: Audio

    private fun audioStream(index: Int, format: Format): AudioStreamInfo {
        val mime = format.sampleMimeType.orEmpty()
        val channels = format.channelCount.coerceAtLeast(0)
        return AudioStreamInfo(
            index = index,
            codec = audioCodecName(format),
            profile = audioProfile(mime, format.codecs),
            channels = channels,
            channelLayout = channelLayout(channels),
            sampleRate = format.sampleRate.coerceAtLeast(0),
            language = language(format.language),
            title = format.label,
            bitRate = format.averageBitrate.takeIf { it > 0 },
            dispositions = dispositions(format),
        )
    }

    private fun audioCodecName(format: Format): String = when (val mime = format.sampleMimeType.orEmpty()) {
        MimeTypes.AUDIO_AAC -> "aac"
        MimeTypes.AUDIO_AC3 -> "ac3"
        MimeTypes.AUDIO_E_AC3, MimeTypes.AUDIO_E_AC3_JOC -> "eac3"
        MimeTypes.AUDIO_AC4 -> "ac4"
        MimeTypes.AUDIO_TRUEHD -> "truehd"
        MimeTypes.AUDIO_DTS, MimeTypes.AUDIO_DTS_HD, MimeTypes.AUDIO_DTS_EXPRESS, MimeTypes.AUDIO_DTS_UHD_P2 -> "dts"
        MimeTypes.AUDIO_OPUS -> "opus"
        MimeTypes.AUDIO_VORBIS -> "vorbis"
        MimeTypes.AUDIO_FLAC -> "flac"
        MimeTypes.AUDIO_MPEG -> "mp3"
        MimeTypes.AUDIO_MPEG_L2 -> "mp2"
        MimeTypes.AUDIO_MPEG_L1 -> "mp1"
        MimeTypes.AUDIO_ALAC -> "alac"
        MimeTypes.AUDIO_ALAW -> "pcm_alaw"
        MimeTypes.AUDIO_MLAW -> "pcm_mulaw"
        MimeTypes.AUDIO_AMR_NB -> "amr_nb"
        MimeTypes.AUDIO_AMR_WB -> "amr_wb"
        MimeTypes.AUDIO_RAW -> when (format.pcmEncoding) {
            C.ENCODING_PCM_8BIT -> "pcm_u8"
            C.ENCODING_PCM_16BIT -> "pcm_s16le"
            C.ENCODING_PCM_16BIT_BIG_ENDIAN -> "pcm_s16be"
            C.ENCODING_PCM_24BIT -> "pcm_s24le"
            C.ENCODING_PCM_24BIT_BIG_ENDIAN -> "pcm_s24be"
            C.ENCODING_PCM_32BIT -> "pcm_s32le"
            C.ENCODING_PCM_32BIT_BIG_ENDIAN -> "pcm_s32be"
            C.ENCODING_PCM_FLOAT -> "pcm_f32le"
            else -> "pcm"
        }
        else -> mime.substringAfter('/')
    }

    private fun audioProfile(mime: String, codecs: String?): String? = when (mime) {
        MimeTypes.AUDIO_AAC -> codecToken(codecs, "mp4a.40.")?.substringAfterLast('.')?.toIntOrNull()?.let { aot ->
            when (aot) {
                1 -> "Main"
                2 -> "LC"
                3 -> "SSR"
                4 -> "LTP"
                5 -> "HE-AAC"
                23 -> "LD"
                29 -> "HE-AACv2"
                39 -> "ELD"
                42 -> "xHE-AAC"
                else -> null
            }
        }
        MimeTypes.AUDIO_E_AC3_JOC -> "Dolby Digital Plus + Dolby Atmos"
        MimeTypes.AUDIO_DTS_HD -> "DTS-HD MA"
        MimeTypes.AUDIO_DTS_EXPRESS -> "DTS Express"
        MimeTypes.AUDIO_DTS_UHD_P2 -> "DTS-UHD"
        MimeTypes.AUDIO_DTS -> "DTS"
        else -> null
    }

    /** FFmpeg's layout name for the common channel counts. The container's channel mask is not exposed. */
    fun channelLayout(channels: Int): String? = when (channels) {
        0 -> null
        1 -> "mono"
        2 -> "stereo"
        3 -> "3.0"
        4 -> "4.0"
        5 -> "5.0"
        6 -> "5.1"
        7 -> "6.1"
        8 -> "7.1"
        else -> "$channels channels"
    }

    // MARK: Subtitles

    private fun subtitleStream(index: Int, format: Format): SubtitleStreamInfo {
        // With parsing during extraction the sample type is Media3's cue type and the file's own type moves to `codecs`.
        val mime = (if (format.sampleMimeType == MimeTypes.APPLICATION_MEDIA3_CUES) format.codecs else format.sampleMimeType).orEmpty()
        return SubtitleStreamInfo(
            index = index,
            codec = subtitleCodecName(mime),
            language = language(format.language),
            title = format.label,
            dispositions = dispositions(format),
            isBitmap = mime == MimeTypes.APPLICATION_PGS || mime == MimeTypes.APPLICATION_VOBSUB ||
                mime == MimeTypes.APPLICATION_DVBSUBS,
        )
    }

    private fun subtitleCodecName(mime: String): String = when (mime) {
        MimeTypes.APPLICATION_SUBRIP -> "subrip"
        // FFmpeg tells SSA from ASS; Media3 reports both as one type.
        MimeTypes.TEXT_SSA -> "ass"
        MimeTypes.TEXT_VTT -> "webvtt"
        MimeTypes.APPLICATION_TX3G -> "mov_text"
        MimeTypes.APPLICATION_PGS -> "hdmv_pgs_subtitle"
        MimeTypes.APPLICATION_VOBSUB -> "dvd_subtitle"
        MimeTypes.APPLICATION_DVBSUBS -> "dvb_subtitle"
        MimeTypes.APPLICATION_TTML -> "ttml"
        MimeTypes.APPLICATION_CEA608 -> "eia_608"
        else -> mime.substringAfter('/')
    }

    // MARK: Shared

    /** Media3 reports "und" for an undetermined language; the contract says null. */
    private fun language(language: String?): String? =
        language?.takeIf { it.isNotBlank() && it != C.LANGUAGE_UNDETERMINED }

    private fun dispositions(format: Format): Dispositions = Dispositions(
        isDefault = format.selectionFlags and C.SELECTION_FLAG_DEFAULT != 0,
        isForced = format.selectionFlags and C.SELECTION_FLAG_FORCED != 0,
        isCommentary = format.roleFlags and C.ROLE_FLAG_COMMENTARY != 0,
        isHearingImpaired = format.roleFlags and (C.ROLE_FLAG_CAPTION or C.ROLE_FLAG_TRANSCRIBES_DIALOG) != 0,
        isVisualImpaired = format.roleFlags and C.ROLE_FLAG_DESCRIBES_VIDEO != 0,
    )
}
