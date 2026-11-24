package io.github.nphil.videoengine

import java.util.Locale
import org.json.JSONObject

/**
 * What this device can do for playback: decoders, encoders, display, audio, compute and power, in one immutable
 * value a planner can take and a test can fix. The Android mirror of the Apple `HardwareCapabilities`.
 *
 * Every field is probed at run time. Nothing here, and nothing that reads it, tests a device name.
 */
public data class HardwareCapabilities(
    public val decode: Decode,
    public val encode: Encode,
    public val display: Display,
    public val audio: Audio,
    public val power: Power,
    public val compute: Compute,
    public val engine: Engine,
) {
    public enum class Support(public val code: String) {
        Hardware("hw"),
        SoftwareOnly("sw"),
        None("no"),
        Unknown("?"),
    }

    public enum class Thermal {
        Nominal,
        Fair,
        Serious,
        Critical;

        public val code: String get() = name.lowercase(Locale.ROOT)
    }

    /** A video decoder `MediaCodecList` offers, with what it advertises. */
    public data class VideoDecoder(
        /** The codec's name, such as `c2.qti.hevc.decoder`. */
        public val name: String,
        /** The Android MIME type it decodes: `video/hevc`, `video/dolby-vision`, ... */
        public val mimeType: String,
        /** `MediaCodecInfo.isHardwareAccelerated`: the manufacturer's word, which Android cannot verify. */
        public val hardwareAccelerated: Boolean,
        public val softwareOnly: Boolean,
        public val vendor: Boolean,
        /** Profile names as `MediaCodecInfo.CodecProfileLevel` spells them: `Main10`, `High`, `DvheStn`. */
        public val profiles: List<String>,
        /** The highest frame rate the decoder advertises for each size class; a missing class means unsupported. */
        public val maxFps: Map<SizeClass, Int>,
        /** True when [maxFps] comes from `getSupportedPerformancePoints`, false when it is estimated from size and rate ranges. */
        public val performancePoints: Boolean,
        /** `FEATURE_TunneledPlayback`. */
        public val tunneling: Boolean = false,
    ) {
        /** A decoder the manufacturer marks hardware accelerated and that is not a software codec. */
        public val isHardware: Boolean get() = hardwareAccelerated && !softwareOnly
    }

    /** An audio decoder `MediaCodecList` offers. */
    public data class AudioDecoder(
        public val name: String,
        public val mimeType: String,
        public val softwareOnly: Boolean,
        public val maxChannels: Int,
    )

    /**
     * The `MediaCodecList` decoders. A per-file answer comes from [DecodeVerdicts] over these rows.
     *
     * @property representative false on an emulator, whose decoders say nothing about real devices: every
     * summary is then [Support.Unknown].
     */
    public data class Decode(
        public val video: List<VideoDecoder>,
        public val audio: List<AudioDecoder>,
        public val representative: Boolean = true,
    ) {
        public val h264: Support get() = support(Mime.H264)
        public val hevc: Support get() = support(Mime.HEVC)
        public val hevc10: Support get() = support(Mime.HEVC, Profiles.HEVC_10_BIT)
        public val dolbyVision: Support get() = support(Mime.DOLBY_VISION)
        public val av1: Support get() = support(Mime.AV1)
        public val vp9: Support get() = support(Mime.VP9)
        public val mpeg2: Support get() = support(Mime.MPEG2)

        /** Hardware if a hardware decoder lists the MIME type (and, if given, one of [profiles]), software if only a software one does. */
        public fun support(mimeType: String, profiles: Set<String>? = null): Support {
            if (!representative) return Support.Unknown
            val rows = video.filter { row ->
                row.mimeType == mimeType && (profiles == null || row.profiles.any { it in profiles })
            }
            return when {
                rows.any { it.isHardware } -> Support.Hardware
                rows.isNotEmpty() -> Support.SoftwareOnly
                else -> Support.None
            }
        }

        /** The Dolby Vision profile names hardware and software decoders list, each sorted and without repeats. */
        internal fun dolbyVisionProfiles(hardware: Boolean): List<String> = video
            .filter { it.mimeType == Mime.DOLBY_VISION && it.isHardware == hardware }
            .flatMap { it.profiles }
            .distinct()
            .sorted()
    }

    /** Whether the device encodes, from the same list. */
    public data class Encode(public val hevc: Support, public val h264: Support)

    /** One mode a display offers. */
    public data class DisplayMode(public val width: Int, public val height: Int, public val refreshRate: Double)

    /** Display facts: the HDR formats it accepts and its modes. */
    public data class Display(
        /** The HDR formats the display accepts (`Display.HdrCapabilities`, `Display.Mode.getSupportedHdrTypes`). Empty for an SDR panel. */
        public val hdrTypes: Set<HdrType>,
        /** Every mode the display supports. */
        public val modes: List<DisplayMode> = emptyList(),
        /** The mode in use, when known. */
        public val currentMode: DisplayMode? = null,
        public val maxFramesPerSecond: Int = 60,
        /** P3 rather than sRGB. */
        public val wideGamut: Boolean = false,
        /** Android has no equivalent of EDR headroom; reported as 1, as the contract says. */
        public val edrHeadroomPotential: Double = 1.0,
        public val edrHeadroomCurrent: Double = 1.0,
        /** Android reports no scene-capture state; always false. */
        public val capturing: Boolean = false,
        /** Casting or an external display is in use. Not detected yet (Cast is out of scope), so false. */
        public val externalPlaybackActive: Boolean = false,
    ) {
        /** Whether the display shows any HDR; false sends HDR and Dolby Vision sources to a server transcode. */
        public val hdrPlaybackEligible: Boolean get() = hdrTypes.isNotEmpty()

        /** Whether [type] is shown correctly. HDR10+ displays also show plain HDR10. */
        public fun accepts(type: HdrType): Boolean =
            type in hdrTypes || (type == HdrType.Hdr10 && HdrType.Hdr10Plus in hdrTypes)

        public companion object {
            public val Unknown: Display = Display(hdrTypes = emptySet())
        }
    }

    /** Spatial audio state (`android.media.Spatializer`, API 32). */
    public data class Spatializer(
        /** `none`, `multichannel`, `other`, or `unsupported` below API 32. */
        public val immersiveLevel: String,
        public val available: Boolean,
        public val enabled: Boolean,
    ) {
        public companion object {
            public val Unsupported: Spatializer = Spatializer(immersiveLevel = "unsupported", available = false, enabled = false)
        }
    }

    /** What the audio output takes untouched, and the spatializer. */
    public data class Audio(
        /** Codes ([AudioFormats]) of the compressed formats the output accepts as a bitstream. */
        public val passthrough: Set<String>,
        /** The route in use, such as `hdmi`, `speaker` or `bluetooth`; for the report only. */
        public val output: String,
        public val maxChannelCount: Int,
        public val spatializer: Spatializer = Spatializer.Unsupported,
    ) {
        public companion object {
            public val Unknown: Audio = Audio(passthrough = emptySet(), output = "unknown", maxChannelCount = 2)
        }
    }

    /** Battery facts, null when the device has no battery (a TV box). */
    public data class Battery(public val level: Float? = null, public val charging: Boolean? = null)

    public data class Power(
        public val thermal: Thermal,
        public val lowPowerMode: Boolean,
        public val battery: Battery = Battery(),
    ) {
        /** Optional work (enhancement, interpolation, prefetch beyond the minimum, thumbnails) backs off. */
        public val shouldShedOptionalWork: Boolean get() = thermal >= Thermal.Serious || lowPowerMode
    }

    /** Identity and compute facts. [machine] and the OS labels are for the report, never for a decision. */
    public data class Compute(
        public val appVersion: String,
        public val osVersion: String,
        public val osBuild: String,
        public val machine: String,
        /** True on an emulator. */
        public val simulator: Boolean,
        public val logicalCores: Int?,
        public val performanceCores: Int? = null,
        public val efficiencyCores: Int? = null,
        public val memoryMB: Int,
        public val sdk: Int,
        public val soc: String? = null,
        public val abis: List<String> = emptyList(),
        /** `3.2` style OpenGL ES version, or null. */
        public val gles: String? = null,
        /** `1.3` style Vulkan API version, or null when the device has no Vulkan. */
        public val vulkan: String? = null,
    )

    /** What the bundled player and extensions offer. */
    public data class Engine(
        /** The player library and its exact version, such as `media3-1.11.1`. */
        public val player: String,
        /** Null while FFmpeg is not bundled (before stage 3). */
        public val ffmpegVersion: String? = null,
        public val dav1d: Boolean = false,
        /** Codes ([AudioFormats]) a bundled software audio decoder covers. */
        public val softwareAudio: Set<String> = emptySet(),
        /** Whether the player plays a backward-compatible profile 7 stream's HDR10 base layer when no decoder lists profile 7 (Media3 1.12 and later). */
        public val dolbyVision7Fallback: Boolean = false,
    )

    /** The `hw-*` lines of the field report, one fact group per line, with the Apple tags and keys. */
    public fun reportLines(): List<String> {
        val d = decode
        val dvHw = d.dolbyVisionProfiles(hardware = true)
        val dvSw = d.dolbyVisionProfiles(hardware = false)
        val machine = compute
        val lines = ArrayList<String>(12)
        lines += "hw-id v=1 app=${field(machine.appVersion)} os=${field(machine.osVersion)} build=${field(machine.osBuild)} " +
            "machine=${field(machine.machine)} sim=${flag(machine.simulator)} api=${machine.sdk} soc=${field(machine.soc)}"
        lines += "hw-cpu logical=${count(machine.logicalCores)} perf=${count(machine.performanceCores)} " +
            "eff=${count(machine.efficiencyCores)} ram_mb=${machine.memoryMB} abi=${list(machine.abis)}"
        lines += "hw-gpu gles=${field(machine.gles)} vulkan=${field(machine.vulkan)}"
        lines += "hw-dec h264=${d.h264.code} hevc=${d.hevc.code} hevc10=${d.hevc10.code} dv=${d.dolbyVision.code} " +
            "av1=${d.av1.code} vp9=${d.vp9.code} mpeg2=${d.mpeg2.code}"
        lines += "hw-dv hw=${list(dvHw)} sw=${list(dvSw)}"
        lines += "hw-fps ${FPS_REPORT_CODECS.joinToString(" ") { (key, mime) -> "$key=${bestFps(mime)}" }}"
        lines += "hw-enc hevc=${encode.hevc.code} h264=${encode.h264.code}"
        lines += "hw-disp hdr_ok=${flag(display.hdrPlaybackEligible)} hdr=${list(display.hdrTypes.map { it.code }.sorted())} " +
            "edr_pot=${one(display.edrHeadroomPotential)} edr_cur=${one(display.edrHeadroomCurrent)} " +
            "maxfps=${display.maxFramesPerSecond} gamut=${if (display.wideGamut) "p3" else "srgb"} " +
            "capture=${flag(display.capturing)} ext=${flag(display.externalPlaybackActive)} " +
            "mode=${display.currentMode?.let { "${it.width}x${it.height}@${rate(it.refreshRate)}" } ?: "?"} " +
            "rates=${list(ratesAtCurrentSize().map(::rate))}"
        lines += "hw-pwr thermal=${power.thermal.code} lpm=${flag(power.lowPowerMode)} " +
            "batt=${power.battery.level?.let { String.format(Locale.ROOT, "%.2f", it) } ?: "?"} " +
            "chg=${power.battery.charging?.let(::flag) ?: "?"}"
        lines += "hw-aud pt=${list(audio.passthrough.sorted())} out=${field(audio.output)} maxch=${audio.maxChannelCount} " +
            "spat=${audio.spatializer.immersiveLevel} spat_on=${flag(audio.spatializer.enabled)} " +
            "spat_avail=${flag(audio.spatializer.available)} dec=${list(AudioFormats.decoderCodes(d.audio))} " +
            "atmos=${AudioPlanner.resolve(AudioFormats.ATMOS_PROBE, this).summary}"
        lines += "hw-eng player=${field(engine.player)} ffmpeg=${engine.ffmpegVersion?.let(::field) ?: "none"} " +
            "dav1d=${flag(engine.dav1d)} hwaccel=mediacodec soft_audio=${list(engine.softwareAudio.sorted())} " +
            "dv7_fallback=${flag(engine.dolbyVision7Fallback)}"
        return lines
    }

    /** The snapshot as JSON, in the format [fromJson] reads and the files under `shared/devices` store. */
    public fun toJson(): JSONObject = CapabilitiesJson.encode(this)

    /** [toJson] as indented text, for a report a person pastes into a file. */
    public fun toJsonString(): String = toJson().toString(2)

    /** The `hw-state` line: what changes while the app runs. */
    internal val stateLine: String
        get() = "hw-state thermal=${power.thermal.code} lpm=${flag(power.lowPowerMode)} " +
            "hdr_ok=${flag(display.hdrPlaybackEligible)} ext=${flag(display.externalPlaybackActive)}"

    /** The best frame rate a hardware decoder of [mime] advertises, as `2160@60` for its largest size class, or `-`. */
    private fun bestFps(mime: String): String {
        val best = decode.video.filter { it.mimeType == mime && it.isHardware }
            .flatMap { row -> row.maxFps.entries.filter { it.value > 0 } }
            .maxWithOrNull(compareBy({ it.key.ordinal }, { it.value })) ?: return "-"
        return "${best.key.code}@${best.value}"
    }

    private fun ratesAtCurrentSize(): List<Double> {
        val current = display.currentMode ?: return emptyList()
        return display.modes.filter { it.width == current.width && it.height == current.height }
            .map { it.refreshRate }.distinct().sorted()
    }

    internal object Mime {
        const val H264 = "video/avc"
        const val HEVC = "video/hevc"
        const val AV1 = "video/av01"
        const val VP9 = "video/x-vnd.on2.vp9"
        const val VP8 = "video/x-vnd.on2.vp8"
        const val MPEG2 = "video/mpeg2"
        const val MPEG4 = "video/mp4v-es"
        const val DOLBY_VISION = "video/dolby-vision"
    }

    internal object Profiles {
        val HEVC_10_BIT = setOf("Main10", "Main10HDR10", "Main10HDR10Plus")
    }

    public companion object {
        private val FPS_REPORT_CODECS = listOf(
            "h264" to Mime.H264,
            "hevc" to Mime.HEVC,
            "av1" to Mime.AV1,
            "vp9" to Mime.VP9,
        )

        /** Reads a snapshot [toJson] wrote: a device report from the sample app, or a hand-written test snapshot. */
        public fun fromJson(json: JSONObject): HardwareCapabilities = CapabilitiesJson.decode(json)

        public fun fromJson(text: String): HardwareCapabilities = CapabilitiesJson.decode(JSONObject(text))

        internal fun flag(value: Boolean): String = if (value) "1" else "0"
        internal fun count(value: Int?): String = value?.toString() ?: "?"
        internal fun one(value: Double): String = String.format(Locale.ROOT, "%.1f", value)

        /** A report value: no spaces, which would split a `key=value` token; `?` when empty. */
        internal fun field(value: String?): String = value?.trim()?.replace(Regex("\\s+"), "_")?.ifEmpty { null } ?: "?"

        internal fun list(values: Collection<String>): String = if (values.isEmpty()) "-" else values.joinToString(",")

        /** `60`, `59.94`, `23.976`: at most three decimals, none when whole. */
        internal fun rate(value: Double): String {
            val text = String.format(Locale.ROOT, "%.3f", value).trimEnd('0').trimEnd('.')
            return text.ifEmpty { "0" }
        }
    }
}

/** The frame-size buckets verdicts and cache keys use. */
public enum class SizeClass(public val code: String, public val width: Int, public val height: Int) {
    Sd("sd", 1024, 576),
    P720("720", 1280, 720),
    P1080("1080", 1920, 1080),
    P1440("1440", 2560, 1440),
    P2160("2160", 3840, 2160),
    P4320("4320", 7680, 4320);

    public companion object {
        /** The class of a frame by its longer side, as the Apple cache key does it. */
        public fun of(width: Int, height: Int): SizeClass {
            val side = maxOf(width, height)
            return when {
                side <= 1024 -> Sd
                side <= 1280 -> P720
                side <= 1920 -> P1080
                side <= 2560 -> P1440
                side <= 3840 -> P2160
                else -> P4320
            }
        }

        public fun fromCode(code: String): SizeClass? = entries.firstOrNull { it.code == code }
    }
}
