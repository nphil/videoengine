package io.github.nphil.videoengine

import android.annotation.SuppressLint
import android.media.AudioDeviceInfo
import android.media.MediaCodecInfo.CodecProfileLevel
import android.os.PowerManager
import android.view.Display
import io.github.nphil.videoengine.HardwareCapabilities.Mime
import io.github.nphil.videoengine.HardwareCapabilities.Thermal

/**
 * The pure half of the live probe: how raw Android numbers become snapshot values. Nothing here touches a
 * system service, so the JVM tests cover it.
 */
internal object PlatformFacts {
    /** Frame rates tried for each size class, lowest first. */
    val FPS_LADDER: IntArray = intArrayOf(24, 25, 30, 50, 60, 100, 120, 240)

    /** The highest rung of [FPS_LADDER] [supports] accepts for each size class's reference size; absent when none. */
    fun maxFpsBySizeClass(supports: (width: Int, height: Int, fps: Int) -> Boolean): Map<SizeClass, Int> {
        val result = LinkedHashMap<SizeClass, Int>()
        for (sizeClass in SizeClass.entries) {
            var best = 0
            for (fps in FPS_LADDER) {
                if (!supports(sizeClass.width, sizeClass.height, fps)) break
                best = fps
            }
            if (best > 0) result[sizeClass] = best
        }
        return result
    }

    /** `PowerManager.THERMAL_STATUS_*` to the contract's four states. */
    fun thermal(status: Int): Thermal = when (status) {
        PowerManager.THERMAL_STATUS_NONE -> Thermal.Nominal
        PowerManager.THERMAL_STATUS_LIGHT, PowerManager.THERMAL_STATUS_MODERATE -> Thermal.Fair
        PowerManager.THERMAL_STATUS_SEVERE -> Thermal.Serious
        else -> Thermal.Critical // CRITICAL, EMERGENCY, SHUTDOWN; also any status a later release adds
    }

    /** `Display.HdrCapabilities.HDR_TYPE_*`; null for a type this engine has no name for. */
    fun hdrType(type: Int): HdrType? = when (type) {
        Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION -> HdrType.DolbyVision
        Display.HdrCapabilities.HDR_TYPE_HDR10 -> HdrType.Hdr10
        Display.HdrCapabilities.HDR_TYPE_HLG -> HdrType.Hlg
        Display.HdrCapabilities.HDR_TYPE_HDR10_PLUS -> HdrType.Hdr10Plus
        else -> null
    }

    /** The kind of output an `AudioDeviceInfo.TYPE_*` is, for the report. */
    @SuppressLint("InlinedApi")
    fun outputKind(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_HDMI, AudioDeviceInfo.TYPE_HDMI_ARC, AudioDeviceInfo.TYPE_HDMI_EARC -> "hdmi"
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_LINE_ANALOG,
        AudioDeviceInfo.TYPE_LINE_DIGITAL,
        -> "wired"
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_BLE_HEADSET,
        AudioDeviceInfo.TYPE_BLE_SPEAKER,
        -> "bluetooth"
        AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_USB_ACCESSORY -> "usb"
        else -> "other"
    }

    /** `android.media.Spatializer.SPATIALIZER_IMMERSIVE_LEVEL_*`. */
    fun immersiveLevel(level: Int): String = when (level) {
        0 -> "none"
        1 -> "multichannel"
        else -> "other"
    }

    /** An OpenGL ES version as the configuration reports it (`0x00030002`) to `3.2`. */
    fun gles(reqGlEsVersion: Int): String? =
        if (reqGlEsVersion == 0) null else "${reqGlEsVersion ushr 16}.${reqGlEsVersion and 0xffff}"

    /** A Vulkan API version as `FEATURE_VULKAN_HARDWARE_VERSION` reports it (major in bits 22 and up, minor in bits 12 to 21). */
    fun vulkan(version: Int): String? =
        if (version == 0) null else "${version ushr 22}.${(version ushr 12) and 0x3ff}"

    /**
     * Whether the build identifiers are an Android emulator's. This only decides whether decoder answers are
     * trustworthy; it is never a device-name check.
     */
    fun isEmulator(hardware: String, fingerprint: String, product: String): Boolean =
        hardware == "goldfish" || hardware == "ranchu" ||
            fingerprint.startsWith("generic") || fingerprint.contains("emulator") ||
            product.startsWith("sdk_gphone") || product.startsWith("sdk_google") || product == "sdk"

    /** The `CodecProfileLevel` profile names for a decoder's profile numbers; a number without a name keeps its hex value. */
    fun profileNames(mime: String, profiles: IntArray): List<String> =
        profiles.map { profileName(mime, it) ?: "0x" + Integer.toHexString(it) }.distinct().sorted()

    @SuppressLint("InlinedApi")
    private fun profileName(mime: String, profile: Int): String? = when (mime) {
        Mime.H264 -> when (profile) {
            CodecProfileLevel.AVCProfileBaseline -> "Baseline"
            CodecProfileLevel.AVCProfileConstrainedBaseline -> "ConstrainedBaseline"
            CodecProfileLevel.AVCProfileMain -> "Main"
            CodecProfileLevel.AVCProfileExtended -> "Extended"
            CodecProfileLevel.AVCProfileHigh -> "High"
            CodecProfileLevel.AVCProfileConstrainedHigh -> "ConstrainedHigh"
            CodecProfileLevel.AVCProfileHigh10 -> "High10"
            CodecProfileLevel.AVCProfileHigh422 -> "High422"
            CodecProfileLevel.AVCProfileHigh444 -> "High444"
            else -> null
        }
        Mime.HEVC -> when (profile) {
            CodecProfileLevel.HEVCProfileMain -> "Main"
            CodecProfileLevel.HEVCProfileMain10 -> "Main10"
            CodecProfileLevel.HEVCProfileMainStill -> "MainStill"
            CodecProfileLevel.HEVCProfileMain10HDR10 -> "Main10HDR10"
            CodecProfileLevel.HEVCProfileMain10HDR10Plus -> "Main10HDR10Plus"
            else -> null
        }
        Mime.AV1 -> when (profile) {
            CodecProfileLevel.AV1ProfileMain8 -> "Main8"
            CodecProfileLevel.AV1ProfileMain10 -> "Main10"
            CodecProfileLevel.AV1ProfileMain10HDR10 -> "Main10HDR10"
            CodecProfileLevel.AV1ProfileMain10HDR10Plus -> "Main10HDR10Plus"
            else -> null
        }
        Mime.VP9 -> when (profile) {
            CodecProfileLevel.VP9Profile0 -> "Profile0"
            CodecProfileLevel.VP9Profile1 -> "Profile1"
            CodecProfileLevel.VP9Profile2 -> "Profile2"
            CodecProfileLevel.VP9Profile3 -> "Profile3"
            CodecProfileLevel.VP9Profile2HDR -> "Profile2HDR"
            CodecProfileLevel.VP9Profile3HDR -> "Profile3HDR"
            CodecProfileLevel.VP9Profile2HDR10Plus -> "Profile2HDR10Plus"
            CodecProfileLevel.VP9Profile3HDR10Plus -> "Profile3HDR10Plus"
            else -> null
        }
        Mime.DOLBY_VISION -> when (profile) {
            CodecProfileLevel.DolbyVisionProfileDvavPer -> "DvavPer"
            CodecProfileLevel.DolbyVisionProfileDvavPen -> "DvavPen"
            CodecProfileLevel.DolbyVisionProfileDvheDer -> "DvheDer"
            CodecProfileLevel.DolbyVisionProfileDvheDen -> "DvheDen"
            CodecProfileLevel.DolbyVisionProfileDvheDtr -> "DvheDtr"
            CodecProfileLevel.DolbyVisionProfileDvheStn -> "DvheStn"
            CodecProfileLevel.DolbyVisionProfileDvheDth -> "DvheDth"
            CodecProfileLevel.DolbyVisionProfileDvheDtb -> "DvheDtb"
            CodecProfileLevel.DolbyVisionProfileDvheSt -> "DvheSt"
            CodecProfileLevel.DolbyVisionProfileDvavSe -> "DvavSe"
            CodecProfileLevel.DolbyVisionProfileDvav110 -> "Dvav110"
            else -> null
        }
        else -> null
    }
}
