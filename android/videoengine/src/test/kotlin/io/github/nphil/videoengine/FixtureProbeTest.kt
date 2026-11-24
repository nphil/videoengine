package io.github.nphil.videoengine

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.DataReader
import androidx.media3.common.Format
import androidx.media3.common.util.ParsableByteArray
import androidx.media3.common.util.UnstableApi
import androidx.media3.extractor.DefaultExtractorInput
import androidx.media3.extractor.Extractor
import androidx.media3.extractor.ExtractorInput
import androidx.media3.extractor.ExtractorOutput
import androidx.media3.extractor.PositionHolder
import androidx.media3.extractor.SeekMap
import androidx.media3.extractor.TrackOutput
import androidx.media3.extractor.mkv.MatroskaExtractor
import androidx.media3.extractor.text.SubtitleParser
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.EOFException
import java.io.File
import java.io.RandomAccessFile
import java.util.Locale
import kotlin.math.abs

/**
 * Runs Media3's real Matroska extractor over each fixture, maps what it finds with [ProbeMapper] and compares the
 * result with `shared/fixtures/manifest.json`: the check the sample app runs on a device, minus the device.
 */
@OptIn(UnstableApi::class)
class FixtureProbeTest {
    @Test
    fun probeEqualsManifestForEveryFixture() {
        val manifest = JSONObject(File(System.getProperty("videoengine.shared"), "fixtures/manifest.json").readText()).getJSONObject("fixtures")
        val dir = File(System.getProperty("videoengine.fixtures"))
        val names = dir.listFiles { f -> f.name.endsWith(".mkv") }!!.map { it.name }.sorted()
        assertEquals("manifest.json and the fixture folder must list the same files", manifest.keys().asSequence().toList().sorted(), names)

        val problems = ArrayList<String>()
        for (name in names) {
            val output = extract(File(dir, name))
            val info = ProbeMapper.map(output.formats, output.durationUs, name)
            compare(name, manifest.getJSONObject(name), info, problems)
        }
        assertTrue(problems.joinToString("\n"), problems.isEmpty())
    }

    private class Collector : ExtractorOutput {
        val formats = ArrayList<Format>()
        var durationUs = C.TIME_UNSET

        override fun track(id: Int, type: Int): TrackOutput = object : TrackOutput {
            override fun format(format: Format) {
                formats += format
            }

            override fun sampleData(input: DataReader, length: Int, allowEndOfInput: Boolean, sampleDataPart: Int): Int {
                val count = minOf(length, 4096)
                val read = input.read(ByteArray(count), 0, count)
                if (read == C.RESULT_END_OF_INPUT && !allowEndOfInput) throw EOFException()
                return read
            }

            override fun sampleData(data: ParsableByteArray, length: Int, sampleDataPart: Int) {
                data.skipBytes(length)
            }

            override fun sampleMetadata(timeUs: Long, flags: Int, size: Int, offset: Int, cryptoData: TrackOutput.CryptoData?) = Unit
        }

        override fun endTracks() = Unit

        override fun seekMap(seekMap: SeekMap) {
            durationUs = seekMap.durationUs
        }
    }

    private fun extract(file: File): Collector {
        val output = Collector()
        val extractor = MatroskaExtractor(SubtitleParser.Factory.UNSUPPORTED, MatroskaExtractor.FLAG_EMIT_RAW_SUBTITLE_DATA)
        extractor.init(output)
        RandomAccessFile(file, "r").use { raf ->
            val length = raf.length()
            val reader = DataReader { buffer, offset, count -> raf.read(buffer, offset, count) }
            var input: ExtractorInput = DefaultExtractorInput(reader, 0, length)
            val position = PositionHolder()
            repeat(100_000) {
                when (extractor.read(input, position)) {
                    Extractor.RESULT_END_OF_INPUT -> return output
                    Extractor.RESULT_SEEK -> {
                        raf.seek(position.position)
                        input = DefaultExtractorInput(reader, position.position, length)
                    }
                }
            }
        }
        error("the extractor never finished ${file.name}")
    }

    private fun compare(name: String, expected: JSONObject, info: MediaInfo, problems: MutableList<String>) {
        if (expected.getString("container") != info.container) problems += "$name container: expected ${expected.getString("container")}, got ${info.container}"
        val duration = expected.getDouble("duration")
        val got = info.duration
        if (got == null || abs(got - duration) > 0.05) problems += "$name duration: expected $duration, got $got"
        streams(name, "video", expected.getJSONArray("video"), info.video.map {
            mapOf(
                "index" to it.index, "codec" to it.codec, "profile" to it.profile, "level" to it.level, "width" to it.width,
                "height" to it.height, "bitDepth" to it.bitDepth, "colorTransfer" to it.colorTransfer,
                "colorPrimaries" to it.colorPrimaries, "colorRange" to it.colorRange,
            )
        }, problems)
        streams(name, "audio", expected.getJSONArray("audio"), info.audio.map {
            mapOf("index" to it.index, "codec" to it.codec, "profile" to it.profile, "channels" to it.channels, "sampleRate" to it.sampleRate, "language" to it.language)
        }, problems)
        streams(name, "subtitle", expected.getJSONArray("subtitles"), info.subtitles.map {
            mapOf("index" to it.index, "codec" to it.codec, "language" to it.language)
        }, problems)
    }

    private fun streams(name: String, kind: String, expected: JSONArray, actual: List<Map<String, Any?>>, problems: MutableList<String>) {
        if (expected.length() != actual.size) {
            problems += "$name $kind streams: expected ${expected.length()}, got ${actual.size}"
            return
        }
        for (i in 0 until expected.length()) {
            val want = expected.getJSONObject(i)
            for (key in want.keys()) {
                val wanted = want.get(key).toString()
                val got = actual[i][key]?.toString()
                val equal = if (key == "language") got != null && Locale.forLanguageTag(got).isO3Language == wanted else got == wanted
                if (!equal) problems += "$name $kind $i $key: expected $wanted, got $got"
            }
        }
    }
}
