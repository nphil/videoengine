package io.github.nphil.videoengine.sample

import android.content.Context
import io.github.nphil.videoengine.AudioStreamInfo
import io.github.nphil.videoengine.MediaInfo
import io.github.nphil.videoengine.SubtitleStreamInfo
import io.github.nphil.videoengine.VideoStreamInfo
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale
import kotlin.math.abs

/**
 * `shared/fixtures/manifest.json` is what ffprobe reports for each fixture. A probe passes when it agrees on every
 * key the manifest lists; keys the manifest leaves out are not compared.
 */
internal object FixtureManifest {
    private const val DURATION_TOLERANCE_SECONDS = 0.05

    /** The manifest's entries by file name. */
    fun load(context: Context): JSONObject {
        val text = context.assets.open("fixtures/manifest.json").bufferedReader().use { it.readText() }
        return JSONObject(text).getJSONObject("fixtures")
    }

    /** What differs between [info] and the manifest entry [expected]; empty when they agree. */
    fun compare(expected: JSONObject, info: MediaInfo): List<String> {
        val problems = ArrayList<String>()
        val container = expected.optString("container")
        if (container.isNotEmpty() && container != info.container) problems += "container: expected $container, got ${info.container}"
        val duration = expected.optDouble("duration")
        if (!duration.isNaN()) {
            val got = info.duration
            if (got == null || abs(got - duration) > DURATION_TOLERANCE_SECONDS) problems += "duration: expected $duration, got $got"
        }
        streams(problems, "video", expected.optJSONArray("video"), info.video.map(::fields))
        streams(problems, "audio", expected.optJSONArray("audio"), info.audio.map(::fields))
        streams(problems, "subtitle", expected.optJSONArray("subtitles"), info.subtitles.map(::fields))
        return problems
    }

    private fun streams(problems: MutableList<String>, kind: String, expected: JSONArray?, actual: List<Map<String, Any?>>) {
        val count = expected?.length() ?: 0
        if (count != actual.size) {
            problems += "$kind streams: expected $count, got ${actual.size}"
            return
        }
        for (i in 0 until count) {
            val want = expected!!.getJSONObject(i)
            for (key in want.keys()) {
                val wanted = want.get(key).toString()
                val got = actual[i][key]?.toString()
                val equal = if (key == "language") sameLanguage(wanted, got) else got == wanted
                if (!equal) problems += "$kind $i $key: expected $wanted, got $got"
            }
        }
    }

    /** ffprobe prints ISO 639-2 (`eng`); Media3 reports the 2-letter tag (`en`). */
    private fun sameLanguage(expected: String, actual: String?): Boolean {
        if (actual == null) return false
        if (actual.equals(expected, ignoreCase = true)) return true
        return runCatching { Locale.forLanguageTag(actual).isO3Language.equals(expected, ignoreCase = true) }.getOrDefault(false)
    }

    private fun fields(s: VideoStreamInfo): Map<String, Any?> = mapOf(
        "index" to s.index, "codec" to s.codec, "profile" to s.profile, "level" to s.level, "width" to s.width,
        "height" to s.height, "bitDepth" to s.bitDepth, "colorTransfer" to s.colorTransfer,
        "colorPrimaries" to s.colorPrimaries, "colorRange" to s.colorRange,
    )

    private fun fields(s: AudioStreamInfo): Map<String, Any?> = mapOf(
        "index" to s.index, "codec" to s.codec, "profile" to s.profile, "channels" to s.channels,
        "sampleRate" to s.sampleRate, "language" to s.language,
    )

    private fun fields(s: SubtitleStreamInfo): Map<String, Any?> = mapOf(
        "index" to s.index, "codec" to s.codec, "language" to s.language,
    )
}
