package io.github.nphil.videoengine

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.display.DisplayManager
import android.media.AudioAttributes as PlatformAudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.view.Display
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.MediaLibraryInfo
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.audio.AudioCapabilities
import io.github.nphil.videoengine.HardwareCapabilities.Support
import java.util.Locale

/**
 * Reads this device's facts from the Android services. Each read is plain; turning the numbers into snapshot
 * values is [PlatformFacts], which the JVM tests cover. Blocking: call off the main thread.
 */
@OptIn(UnstableApi::class)
internal class PlatformProbe(private val context: Context) {
    /** What does not change while the app runs: the decoder and encoder lists, identity, engine build. */
    class Fixed(
        val decode: HardwareCapabilities.Decode,
        val encode: HardwareCapabilities.Encode,
        val compute: HardwareCapabilities.Compute,
        val engine: HardwareCapabilities.Engine,
    )

    fun measureFixed(): Fixed {
        val compute = compute()
        val video = ArrayList<HardwareCapabilities.VideoDecoder>()
        val audio = ArrayList<HardwareCapabilities.AudioDecoder>()
        var hevcEncoder = Support.None
        var h264Encoder = Support.None
        for (info in MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos) {
            if (info.isAlias) continue
            for (type in info.supportedTypes) {
                val mime = type.lowercase(Locale.ROOT)
                when {
                    info.isEncoder -> {
                        val support = if (info.isHardwareAccelerated && !info.isSoftwareOnly) Support.Hardware else Support.SoftwareOnly
                        if (mime == HardwareCapabilities.Mime.HEVC) hevcEncoder = best(hevcEncoder, support)
                        if (mime == HardwareCapabilities.Mime.H264) h264Encoder = best(h264Encoder, support)
                    }
                    mime.startsWith("video/") -> videoDecoder(info, type, mime)?.let(video::add)
                    mime.startsWith("audio/") -> audioDecoder(info, type, mime)?.let(audio::add)
                }
            }
        }
        return Fixed(
            decode = HardwareCapabilities.Decode(video, audio, representative = !compute.simulator),
            encode = HardwareCapabilities.Encode(hevc = hevcEncoder, h264 = h264Encoder),
            compute = compute,
            engine = HardwareCapabilities.Engine(player = "media3-${MediaLibraryInfo.VERSION}"),
        )
    }

    private fun best(current: Support, candidate: Support): Support =
        if (current == Support.Hardware || candidate == Support.Hardware) Support.Hardware else candidate

    private fun videoDecoder(info: MediaCodecInfo, type: String, mime: String): HardwareCapabilities.VideoDecoder? {
        val capabilities = try {
            info.getCapabilitiesForType(type)
        } catch (_: IllegalArgumentException) {
            return null // a codec that lists a type it cannot describe
        }
        val video = capabilities.videoCapabilities ?: return null
        val points = video.supportedPerformancePoints?.takeIf { it.isNotEmpty() }
        val maxFps = PlatformFacts.maxFpsBySizeClass { width, height, fps ->
            if (points != null) {
                val wanted = MediaCodecInfo.VideoCapabilities.PerformancePoint(width, height, fps)
                points.any { it.covers(wanted) }
            } else {
                video.areSizeAndRateSupported(width, height, fps.toDouble())
            }
        }
        return HardwareCapabilities.VideoDecoder(
            name = info.name,
            mimeType = mime,
            hardwareAccelerated = info.isHardwareAccelerated,
            softwareOnly = info.isSoftwareOnly,
            vendor = info.isVendor,
            profiles = PlatformFacts.profileNames(mime, capabilities.profileLevels.map { it.profile }.toIntArray()),
            maxFps = maxFps,
            performancePoints = points != null,
            tunneling = capabilities.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_TunneledPlayback),
        )
    }

    private fun audioDecoder(info: MediaCodecInfo, type: String, mime: String): HardwareCapabilities.AudioDecoder? {
        val capabilities = try {
            info.getCapabilitiesForType(type)
        } catch (_: IllegalArgumentException) {
            return null
        }
        return HardwareCapabilities.AudioDecoder(
            name = info.name,
            mimeType = mime,
            softwareOnly = info.isSoftwareOnly,
            maxChannels = capabilities.audioCapabilities?.maxInputChannelCount ?: 0,
        )
    }

    private fun compute(): HardwareCapabilities.Compute {
        val activityManager = context.getSystemService(ActivityManager::class.java)
        val memory = ActivityManager.MemoryInfo().also { activityManager.getMemoryInfo(it) }
        val vulkan = context.packageManager.systemAvailableFeatures
            .firstOrNull { it.name == PackageManager.FEATURE_VULKAN_HARDWARE_VERSION }?.version
        return HardwareCapabilities.Compute(
            appVersion = appVersion(),
            osVersion = Build.VERSION.RELEASE,
            osBuild = Build.ID,
            machine = Build.MODEL,
            simulator = PlatformFacts.isEmulator(Build.HARDWARE, Build.FINGERPRINT, Build.PRODUCT),
            logicalCores = Runtime.getRuntime().availableProcessors(),
            memoryMB = (memory.totalMem / (1024 * 1024)).toInt(),
            sdk = Build.VERSION.SDK_INT,
            soc = if (Build.VERSION.SDK_INT >= 31) Build.SOC_MODEL.takeIf { it != Build.UNKNOWN } else null,
            abis = Build.SUPPORTED_ABIS.toList(),
            gles = PlatformFacts.gles(activityManager.deviceConfigurationInfo.reqGlEsVersion),
            vulkan = vulkan?.let(PlatformFacts::vulkan),
        )
    }

    private fun appVersion(): String = try {
        val packages = context.packageManager
        val info = if (Build.VERSION.SDK_INT >= 33) {
            packages.getPackageInfo(context.packageName, PackageManager.PackageInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            packages.getPackageInfo(context.packageName, 0)
        }
        info.versionName ?: "?"
    } catch (_: PackageManager.NameNotFoundException) {
        "?"
    }

    // MARK: Changing facts

    fun display(): HardwareCapabilities.Display {
        val display = context.getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY)
            ?: return HardwareCapabilities.Display.Unknown
        val modes = display.supportedModes.map {
            HardwareCapabilities.DisplayMode(it.physicalWidth, it.physicalHeight, it.refreshRate.toDouble())
        }
        val current = display.mode.let {
            HardwareCapabilities.DisplayMode(it.physicalWidth, it.physicalHeight, it.refreshRate.toDouble())
        }
        return HardwareCapabilities.Display(
            hdrTypes = hdrTypes(display),
            modes = modes,
            currentMode = current,
            maxFramesPerSecond = modes.maxOfOrNull { it.refreshRate }?.let { Math.round(it).toInt() } ?: 60,
            wideGamut = display.isWideColorGamut,
        )
    }

    @Suppress("DEPRECATION")
    private fun hdrTypes(display: Display): Set<HdrType> {
        val types: IntArray = if (Build.VERSION.SDK_INT >= 34) {
            display.mode.supportedHdrTypes
        } else {
            display.hdrCapabilities?.supportedHdrTypes ?: IntArray(0)
        }
        return types.toList().mapNotNull(PlatformFacts::hdrType).toSet()
    }

    fun audio(): HardwareCapabilities.Audio {
        val capabilities = AudioCapabilities.getCapabilities(context, AudioAttributes.DEFAULT, null, emptyList())
        val manager = context.getSystemService(AudioManager::class.java)
        return HardwareCapabilities.Audio(
            passthrough = AudioFormats.passthroughEntries.filter { capabilities.supportsEncoding(it.encoding!!) }.map { it.code }.toSet(),
            output = outputKind(manager),
            maxChannelCount = capabilities.maxChannelCount,
            spatializer = spatializer(manager),
        )
    }

    private fun outputKind(manager: AudioManager): String {
        val devices: List<AudioDeviceInfo> = if (Build.VERSION.SDK_INT >= 33) {
            val attributes = PlatformAudioAttributes.Builder()
                .setUsage(PlatformAudioAttributes.USAGE_MEDIA)
                .setContentType(PlatformAudioAttributes.CONTENT_TYPE_MOVIE)
                .build()
            manager.getAudioDevicesForAttributes(attributes)
        } else {
            manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).toList()
        }
        val kinds = devices.map { PlatformFacts.outputKind(it.type) }
        return OUTPUT_PRIORITY.firstOrNull { it in kinds } ?: kinds.firstOrNull() ?: "none"
    }

    private fun spatializer(manager: AudioManager): HardwareCapabilities.Spatializer {
        if (Build.VERSION.SDK_INT < 32) return HardwareCapabilities.Spatializer.Unsupported
        val spatializer = manager.spatializer
        return HardwareCapabilities.Spatializer(
            immersiveLevel = PlatformFacts.immersiveLevel(spatializer.immersiveAudioLevel),
            available = spatializer.isAvailable,
            enabled = spatializer.isEnabled,
        )
    }

    fun power(): HardwareCapabilities.Power {
        val power = context.getSystemService(PowerManager::class.java)
        return HardwareCapabilities.Power(
            thermal = PlatformFacts.thermal(power.currentThermalStatus),
            lowPowerMode = power.isPowerSaveMode,
            battery = battery(),
        )
    }

    /** The sticky battery broadcast; a TV box states no battery. */
    private fun battery(): HardwareCapabilities.Battery {
        val intent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            ?: return HardwareCapabilities.Battery()
        if (!intent.getBooleanExtra(BatteryManager.EXTRA_PRESENT, false)) return HardwareCapabilities.Battery()
        val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, BatteryManager.BATTERY_STATUS_UNKNOWN)
        return HardwareCapabilities.Battery(
            level = if (level >= 0 && scale > 0) level.toFloat() / scale else null,
            charging = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL,
        )
    }

    private companion object {
        val OUTPUT_PRIORITY = listOf("hdmi", "bluetooth", "usb", "wired", "speaker")
    }
}
