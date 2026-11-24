package io.github.nphil.videoengine

import io.github.nphil.videoengine.HardwareCapabilities.Battery
import io.github.nphil.videoengine.HardwareCapabilities.Power
import io.github.nphil.videoengine.HardwareCapabilities.Thermal
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HardwareCapabilitiesTest {
    private val strong = VectorJson.snapshot("synthetic-strong")
    private val weak = VectorJson.snapshot("synthetic-weak")

    @Test
    fun theReportIsOneLinePerGroupInAFixedOrder() {
        val lines = strong.reportLines()
        assertEquals(
            listOf("hw-id", "hw-cpu", "hw-gpu", "hw-dec", "hw-dv", "hw-fps", "hw-enc", "hw-disp", "hw-pwr", "hw-aud", "hw-eng"),
            lines.map { it.substringBefore(' ') },
        )
    }

    @Test
    fun everyReportLineIsATagAndKeyValuePairsWithNoSpacesInsideAValue() {
        val grammar = Regex("^hw-[a-z]+( [A-Za-z0-9_]+=\\S*)+$")
        for (snapshot in VectorJson.snapshots) {
            val capabilities = HardwareCapabilities.fromJson(snapshot.getJSONObject("capabilities"))
            for (line in capabilities.reportLines()) assertTrue("${snapshot.getString("id")}: $line", grammar.matches(line))
        }
    }

    @Test
    fun theDecoderLineSaysWhatTheSnapshotHolds() {
        val line = strong.reportLines().first { it.startsWith("hw-dec") }
        assertTrue(line, "h264=hw" in line && "hevc=hw" in line && "hevc10=hw" in line)
    }

    @Test
    fun optionalWorkIsShedWhenHotOrSavingPower() {
        fun power(thermal: Thermal, lowPower: Boolean) = Power(thermal, lowPower, Battery(level = null, charging = null))
        assertFalse(power(Thermal.Nominal, false).shouldShedOptionalWork)
        assertFalse(power(Thermal.Fair, false).shouldShedOptionalWork)
        assertTrue(power(Thermal.Serious, false).shouldShedOptionalWork)
        assertTrue(power(Thermal.Critical, false).shouldShedOptionalWork)
        assertTrue(power(Thermal.Nominal, true).shouldShedOptionalWork)
        assertFalse(strong.power.shouldShedOptionalWork)
        assertTrue(weak.power.shouldShedOptionalWork)
    }

    @Test
    fun sizeClassesUseTheAppleThresholds() {
        fun code(width: Int, height: Int) = SizeClass.of(width, height).code
        assertEquals("sd", code(1024, 576))
        assertEquals("720", code(1280, 720))
        assertEquals("1080", code(1920, 1080))
        assertEquals("1080", code(1920, 1088))
        assertEquals("1080", code(1080, 1920))
        assertEquals("1440", code(2560, 1440))
        assertEquals("2160", code(3840, 2160))
        assertEquals("4320", code(4096, 2160))
        assertEquals("4320", code(7680, 4320))
    }

    @Test
    fun theVerdictCacheKeySeparatesWhatChangesTheAnswer() {
        fun key(fps: Double?, dv: Int? = null) = VideoStreamFacts(
            codec = "hevc", width = 3840, height = 2160, bitDepth = 10, profile = "Main 10", level = 150,
            frameRate = fps, dolbyVisionProfile = dv,
        ).cacheKey
        assertEquals("hevc-Main 10-150-2160-10-30", key(23.976))
        assertEquals("hevc-Main 10-150-2160-10-60", key(59.94))
        assertEquals("hevc-Main 10-150-2160-10-120", key(119.88))
        assertEquals("hevc-Main 10-150-2160-10-240", key(240.0))
        assertEquals("hevc-Main 10-150-2160-10-?", key(null))
        assertEquals("hevc-Main 10-150-2160-10-30-dv8", key(23.976, dv = 8))
    }

    @Test
    fun verdictsFollowTheDecoderRows() {
        fun verdict(snapshot: HardwareCapabilities, codec: String, profile: String, w: Int, h: Int, fps: Double, bits: Int) =
            DecodeVerdicts.verdict(snapshot, VideoStreamFacts(codec, w, h, bits, profile, frameRate = fps))
        assertEquals(DecodeVerdict.Hardware, verdict(strong, "hevc", "Main 10", 3840, 2160, 59.94, 10))
        assertEquals(DecodeVerdict.Unsupported, verdict(strong, "hevc", "Main 10", 3840, 2160, 120.0, 10))
        assertEquals(DecodeVerdict.SoftwareOnly, verdict(weak, "hevc", "Main", 3840, 2160, 24.0, 8))
        assertEquals(DecodeVerdict.Unsupported, verdict(weak, "vp9", "Profile 0", 1920, 1080, 24.0, 8))
        assertEquals(DecodeVerdict.Unsupported, verdict(strong, "hevc", "Rext", 1920, 1080, 24.0, 12))
        assertEquals(DecodeVerdict.Unknown, DecodeVerdicts.verdict(strong.decode.copy(representative = false), VideoStreamFacts("h264", 1920, 1080)))
    }
}
