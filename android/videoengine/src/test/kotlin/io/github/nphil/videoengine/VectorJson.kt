package io.github.nphil.videoengine

import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** Reads `shared/route-vectors.json`, which the Gradle test task points at through a system property. */
internal object VectorJson {
    val root: JSONObject by lazy { JSONObject(File(System.getProperty("videoengine.shared"), "route-vectors.json").readText()) }

    fun objects(array: JSONArray): List<JSONObject> = List(array.length()) { array.getJSONObject(it) }

    val snapshots: List<JSONObject> by lazy { objects(root.getJSONArray("snapshots")) }
    val vectors: List<JSONObject> by lazy { objects(root.getJSONArray("vectors")) }

    fun snapshot(id: String): HardwareCapabilities =
        HardwareCapabilities.fromJson(snapshots.first { it.getString("id") == id }.getJSONObject("capabilities"))

    fun mediaInfo(o: JSONObject): MediaInfo = MediaInfo(
        container = o.getString("container"),
        duration = o.doubleOrNull("duration"),
        video = objects(o.getJSONArray("video")).map(::video),
        audio = objects(o.getJSONArray("audio")).map(::audio),
        subtitles = objects(o.getJSONArray("subtitles")).map(::subtitle),
    )

    private fun dispositions(o: JSONObject) = Dispositions(isDefault = o.optBoolean("isDefault", false), isForced = o.optBoolean("isForced", false))

    private fun video(o: JSONObject) = VideoStreamInfo(
        index = o.getInt("index"),
        codec = o.getString("codec"),
        profile = o.stringOrNull("profile"),
        level = o.intOrNull("level"),
        pixelFormat = o.stringOrNull("pixelFormat"),
        width = o.getInt("width"),
        height = o.getInt("height"),
        frameRate = o.doubleOrNull("frameRate"),
        bitDepth = o.intOrNull("bitDepth"),
        colorTransfer = o.stringOrNull("colorTransfer"),
        colorPrimaries = o.stringOrNull("colorPrimaries"),
        colorRange = o.stringOrNull("colorRange"),
        dolbyVision = o.optJSONObject("dolbyVision")?.let {
            DolbyVisionRecord(profile = it.getInt("profile"), level = it.getInt("level"), compatibilityId = it.intOrNull("compatibilityId"))
        },
        dispositions = dispositions(o),
    )

    private fun audio(o: JSONObject) = AudioStreamInfo(
        index = o.getInt("index"),
        codec = o.getString("codec"),
        profile = o.stringOrNull("profile"),
        channels = o.getInt("channels"),
        sampleRate = o.getInt("sampleRate"),
        language = o.stringOrNull("language"),
        dispositions = dispositions(o),
    )

    private fun subtitle(o: JSONObject) = SubtitleStreamInfo(
        index = o.getInt("index"),
        codec = o.getString("codec"),
        language = o.stringOrNull("language"),
        dispositions = dispositions(o),
        isBitmap = o.optBoolean("isBitmap", false),
    )
}

internal fun JSONObject.stringOrNull(name: String): String? = if (has(name) && !isNull(name)) getString(name) else null
internal fun JSONObject.intOrNull(name: String): Int? = if (has(name) && !isNull(name)) getInt(name) else null
internal fun JSONObject.doubleOrNull(name: String): Double? = if (has(name) && !isNull(name)) getDouble(name) else null
