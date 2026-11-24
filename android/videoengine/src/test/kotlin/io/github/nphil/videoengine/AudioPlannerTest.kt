package io.github.nphil.videoengine

import org.junit.Assert.assertEquals
import org.junit.Test

class AudioPlannerTest {
    private val strong = VectorJson.snapshot("synthetic-strong")
    private val atmos = AudioFormats.ATMOS_PROBE.copy(index = 1)
    private val dtsHd = AudioStreamInfo(index = 1, codec = "dts", profile = "DTS-HD MA", channels = 8, sampleRate = 48_000)
    private val plainDts = dtsHd.copy(profile = "DTS")

    private fun stream(codec: String, channels: Int = 2, sampleRate: Int = 48_000, profile: String? = null) =
        AudioStreamInfo(index = 1, codec = codec, profile = profile, channels = channels, sampleRate = sampleRate)

    /** The strong snapshot with only [codes] passing through and no platform audio decoders. */
    private fun passing(vararg codes: String): HardwareCapabilities =
        strong.copy(audio = strong.audio.copy(passthrough = codes.toSet()), decode = strong.decode.copy(audio = emptyList()))

    @Test
    fun theBitstreamGoesThroughWhenTheOutputTakesIt() {
        assertEquals(AudioPath(AudioPathKind.Passthrough), AudioPlanner.resolve(atmos, passing("eac3joc", "eac3")))
        assertEquals(AudioPath(AudioPathKind.Passthrough), AudioPlanner.resolve(dtsHd, passing("dtshd", "dts")))
    }

    @Test
    fun atmosFallsBackToItsE_AC3CoreAndDtsHdToItsDtsCore() {
        assertEquals(AudioPath(AudioPathKind.Passthrough, degraded = true), AudioPlanner.resolve(atmos, passing("eac3")))
        assertEquals(AudioPath(AudioPathKind.Passthrough, degraded = true), AudioPlanner.resolve(dtsHd, passing("dts")))
        assertEquals("core", AudioPlanner.resolve(atmos, passing("eac3")).summary)
    }

    @Test
    fun aPlatformDecoderPlaysWhatCannotPassThrough() {
        val withDecoder = passing().let { it.copy(decode = it.decode.copy(audio = strong.decode.audio)) }
        assertEquals(AudioPath(AudioPathKind.PlatformDecoder), AudioPlanner.resolve(stream("aac", profile = "LC"), withDecoder))
        assertEquals(AudioPath(AudioPathKind.PlatformDecoder, degraded = true), AudioPlanner.resolve(atmos, withDecoder))
    }

    @Test
    fun nothingPlaysWhenNothingIsAvailable() {
        assertEquals(AudioPath(AudioPathKind.None), AudioPlanner.resolve(atmos, passing()))
        assertEquals("none", AudioPlanner.resolve(atmos, passing()).summary)
    }

    @Test
    fun theSoftwareExtensionDecodesPlainAudioButNeverObjectAudio() {
        val withExtension = passing().let { it.copy(engine = it.engine.copy(softwareAudio = setOf("dts", "eac3joc", "truehd"))) }
        assertEquals(AudioPath(AudioPathKind.ExtensionDecoder), AudioPlanner.resolve(plainDts, withExtension))
        assertEquals(AudioPath(AudioPathKind.None), AudioPlanner.resolve(atmos, withExtension))
        assertEquals(AudioPath(AudioPathKind.None), AudioPlanner.resolve(stream("ac4", channels = 6), withExtension))
    }

    @Test
    fun pcmNeedsNoDecoderButG711Does() {
        assertEquals(AudioPath(AudioPathKind.Builtin), AudioPlanner.resolve(stream("pcm_s24le"), passing()))
        val g711 = stream("pcm_alaw", channels = 1, sampleRate = 8_000)
        assertEquals(AudioPath(AudioPathKind.None), AudioPlanner.resolve(g711, passing()))
        val withDecoder = passing().let {
            it.copy(decode = it.decode.copy(audio = listOf(HardwareCapabilities.AudioDecoder("c2.android.g711alaw.decoder", "audio/g711-alaw", true, 1))))
        }
        assertEquals(AudioPath(AudioPathKind.PlatformDecoder), AudioPlanner.resolve(g711, withDecoder))
    }

    @Test
    fun everySnapshotUsesOnlyKnownPassthroughCodes() {
        val known = AudioFormats.passthroughCodes.toSet()
        for (snapshot in VectorJson.snapshots) {
            val capabilities = HardwareCapabilities.fromJson(snapshot.getJSONObject("capabilities"))
            assertEquals(snapshot.getString("id"), emptySet<String>(), capabilities.audio.passthrough - known)
        }
    }
}
