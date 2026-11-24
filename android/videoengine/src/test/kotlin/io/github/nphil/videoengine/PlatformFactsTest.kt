package io.github.nphil.videoengine

import android.media.AudioDeviceInfo
import android.media.MediaCodecInfo.CodecProfileLevel
import android.os.PowerManager
import android.view.Display
import io.github.nphil.videoengine.HardwareCapabilities.Mime
import io.github.nphil.videoengine.HardwareCapabilities.Thermal
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PlatformFactsTest {
    @Test
    fun maxFpsIsTheHighestRungEachSizeClassAccepts() {
        val budget = 3840L * 2160 * 60
        val result = PlatformFacts.maxFpsBySizeClass { w, h, fps -> w.toLong() * h * fps <= budget }
        assertEquals(mapOf("sd" to 240, "720" to 240, "1080" to 240, "1440" to 120, "2160" to 60), result.mapKeys { it.key.code })
    }

    @Test
    fun theLadderStopsAtTheFirstRungThatFails() {
        val result = PlatformFacts.maxFpsBySizeClass { _, _, fps -> fps != 30 }
        assertTrue(result.values.all { it == 25 })
    }

    @Test
    fun aClassNothingFitsIsLeftOut() {
        assertTrue(PlatformFacts.maxFpsBySizeClass { _, _, _ -> false }.isEmpty())
    }

    @Test
    fun thermalStatusesMapToTheFourContractStates() {
        assertEquals(Thermal.Nominal, PlatformFacts.thermal(PowerManager.THERMAL_STATUS_NONE))
        assertEquals(Thermal.Fair, PlatformFacts.thermal(PowerManager.THERMAL_STATUS_LIGHT))
        assertEquals(Thermal.Fair, PlatformFacts.thermal(PowerManager.THERMAL_STATUS_MODERATE))
        assertEquals(Thermal.Serious, PlatformFacts.thermal(PowerManager.THERMAL_STATUS_SEVERE))
        assertEquals(Thermal.Critical, PlatformFacts.thermal(PowerManager.THERMAL_STATUS_CRITICAL))
        assertEquals(Thermal.Critical, PlatformFacts.thermal(PowerManager.THERMAL_STATUS_EMERGENCY))
        assertEquals(Thermal.Critical, PlatformFacts.thermal(PowerManager.THERMAL_STATUS_SHUTDOWN))
        assertEquals(Thermal.Critical, PlatformFacts.thermal(99))
    }

    @Test
    fun hdrTypesAreNamedAndUnknownOnesDropped() {
        assertEquals(HdrType.DolbyVision, PlatformFacts.hdrType(Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION))
        assertEquals(HdrType.Hdr10, PlatformFacts.hdrType(Display.HdrCapabilities.HDR_TYPE_HDR10))
        assertEquals(HdrType.Hlg, PlatformFacts.hdrType(Display.HdrCapabilities.HDR_TYPE_HLG))
        assertEquals(HdrType.Hdr10Plus, PlatformFacts.hdrType(Display.HdrCapabilities.HDR_TYPE_HDR10_PLUS))
        assertNull(PlatformFacts.hdrType(99))
    }

    @Test
    fun outputsAreGroupedByKind() {
        assertEquals("hdmi", PlatformFacts.outputKind(AudioDeviceInfo.TYPE_HDMI))
        assertEquals("hdmi", PlatformFacts.outputKind(AudioDeviceInfo.TYPE_HDMI_ARC))
        assertEquals("speaker", PlatformFacts.outputKind(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER))
        assertEquals("wired", PlatformFacts.outputKind(AudioDeviceInfo.TYPE_WIRED_HEADSET))
        assertEquals("bluetooth", PlatformFacts.outputKind(AudioDeviceInfo.TYPE_BLUETOOTH_A2DP))
        assertEquals("usb", PlatformFacts.outputKind(AudioDeviceInfo.TYPE_USB_HEADSET))
        assertEquals("other", PlatformFacts.outputKind(AudioDeviceInfo.TYPE_TELEPHONY))
    }

    @Test
    fun spatializerLevelsAndGraphicsVersionsAreReadable() {
        assertEquals("none", PlatformFacts.immersiveLevel(0))
        assertEquals("multichannel", PlatformFacts.immersiveLevel(1))
        assertEquals("other", PlatformFacts.immersiveLevel(2))
        assertEquals("3.2", PlatformFacts.gles(0x00030002))
        assertNull(PlatformFacts.gles(0))
        assertEquals("1.3", PlatformFacts.vulkan((1 shl 22) or (3 shl 12)))
        assertNull(PlatformFacts.vulkan(0))
    }

    @Test
    fun anEmulatorIsRecognisedByItsBuildAndNeverByDeviceName() {
        assertTrue(PlatformFacts.isEmulator("ranchu", "google/sdk_gphone64_x86_64/emu:16/BP1A:userdebug", "sdk_gphone64_x86_64"))
        assertTrue(PlatformFacts.isEmulator("goldfish", "x", "y"))
        assertFalse(PlatformFacts.isEmulator("qcom", "xiaomi/pad/pad:16/BP2A:user/release-keys", "pad"))
    }

    @Test
    fun profileNumbersBecomeNamesAndUnknownOnesKeepTheirHex() {
        assertEquals(
            listOf("Main", "Main10HDR10"),
            PlatformFacts.profileNames(Mime.HEVC, intArrayOf(CodecProfileLevel.HEVCProfileMain10HDR10, CodecProfileLevel.HEVCProfileMain, CodecProfileLevel.HEVCProfileMain)),
        )
        assertEquals(
            listOf("DvheSt", "DvheStn"),
            PlatformFacts.profileNames(Mime.DOLBY_VISION, intArrayOf(CodecProfileLevel.DolbyVisionProfileDvheStn, CodecProfileLevel.DolbyVisionProfileDvheSt)),
        )
        assertEquals(listOf("0x7777"), PlatformFacts.profileNames(Mime.HEVC, intArrayOf(0x7777)))
    }
}
