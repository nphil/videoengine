package io.github.nphil.videoengine

import io.github.nphil.videoengine.HardwareCapabilities.Support
import org.json.JSONArray
import org.json.JSONObject

/**
 * The snapshot's JSON form: what the sample app's "copy device report" button writes and what
 * `shared/route-vectors.json` and the files under `shared/devices` store. Reading is lenient about the small groups
 * (`encode`, `audio`, `power`, `compute`, `engine`) so a hand-written test snapshot can leave out what it does
 * not exercise; `decode` and `display` are required.
 */
internal object CapabilitiesJson {
    const val SCHEMA = 1

    // MARK: Writing

    fun encode(c: HardwareCapabilities): JSONObject = JSONObject().apply {
        put("schema", SCHEMA)
        put(
            "decode",
            JSONObject().apply {
                put("representative", c.decode.representative)
                put("video", array(c.decode.video, ::videoDecoder))
                put("audio", array(c.decode.audio, ::audioDecoder))
            },
        )
        put("encode", JSONObject().put("hevc", supportName(c.encode.hevc)).put("h264", supportName(c.encode.h264)))
        put("display", display(c.display))
        put("audio", audio(c.audio))
        put("power", power(c.power))
        put("compute", compute(c.compute))
        put("engine", engine(c.engine))
    }

    private fun <T> array(items: List<T>, write: (T) -> JSONObject): JSONArray =
        JSONArray().also { array -> items.forEach { array.put(write(it)) } }

    private fun videoDecoder(d: HardwareCapabilities.VideoDecoder) = JSONObject().apply {
        put("name", d.name)
        put("mime", d.mimeType)
        put("hardware", d.hardwareAccelerated)
        put("softwareOnly", d.softwareOnly)
        put("vendor", d.vendor)
        put("profiles", JSONArray(d.profiles))
        put("maxFps", JSONObject().also { map -> d.maxFps.entries.sortedBy { it.key }.forEach { map.put(it.key.code, it.value) } })
        put("performancePoints", d.performancePoints)
        put("tunneling", d.tunneling)
    }

    private fun audioDecoder(d: HardwareCapabilities.AudioDecoder) = JSONObject().apply {
        put("name", d.name)
        put("mime", d.mimeType)
        put("softwareOnly", d.softwareOnly)
        put("maxChannels", d.maxChannels)
    }

    private fun mode(m: HardwareCapabilities.DisplayMode) = JSONObject().apply {
        put("w", m.width)
        put("h", m.height)
        put("hz", m.refreshRate)
    }

    private fun display(d: HardwareCapabilities.Display) = JSONObject().apply {
        put("hdrTypes", JSONArray(d.hdrTypes.map { it.code }.sorted()))
        put("modes", array(d.modes, ::mode))
        d.currentMode?.let { put("currentMode", mode(it)) }
        put("maxFps", d.maxFramesPerSecond)
        put("wideGamut", d.wideGamut)
        put("edrHeadroomPotential", d.edrHeadroomPotential)
        put("edrHeadroomCurrent", d.edrHeadroomCurrent)
        put("capturing", d.capturing)
        put("externalPlaybackActive", d.externalPlaybackActive)
    }

    private fun audio(a: HardwareCapabilities.Audio) = JSONObject().apply {
        put("passthrough", JSONArray(a.passthrough.sorted()))
        put("output", a.output)
        put("maxChannelCount", a.maxChannelCount)
        put(
            "spatializer",
            JSONObject()
                .put("immersiveLevel", a.spatializer.immersiveLevel)
                .put("available", a.spatializer.available)
                .put("enabled", a.spatializer.enabled),
        )
    }

    private fun power(p: HardwareCapabilities.Power) = JSONObject().apply {
        put("thermal", p.thermal.code)
        put("lowPowerMode", p.lowPowerMode)
        put(
            "battery",
            JSONObject().apply {
                p.battery.level?.let { put("level", it.toDouble()) }
                p.battery.charging?.let { put("charging", it) }
            },
        )
    }

    private fun compute(c: HardwareCapabilities.Compute) = JSONObject().apply {
        put("appVersion", c.appVersion)
        put("osVersion", c.osVersion)
        put("osBuild", c.osBuild)
        put("machine", c.machine)
        put("simulator", c.simulator)
        c.logicalCores?.let { put("logicalCores", it) }
        c.performanceCores?.let { put("performanceCores", it) }
        c.efficiencyCores?.let { put("efficiencyCores", it) }
        put("memoryMB", c.memoryMB)
        put("sdk", c.sdk)
        c.soc?.let { put("soc", it) }
        put("abis", JSONArray(c.abis))
        c.gles?.let { put("gles", it) }
        c.vulkan?.let { put("vulkan", it) }
    }

    private fun engine(e: HardwareCapabilities.Engine) = JSONObject().apply {
        put("player", e.player)
        e.ffmpegVersion?.let { put("ffmpegVersion", it) }
        put("dav1d", e.dav1d)
        put("softwareAudio", JSONArray(e.softwareAudio.sorted()))
        put("dolbyVision7Fallback", e.dolbyVision7Fallback)
    }

    private fun supportName(s: Support): String = when (s) {
        Support.Hardware -> "hardware"
        Support.SoftwareOnly -> "softwareOnly"
        Support.None -> "none"
        Support.Unknown -> "unknown"
    }

    // MARK: Reading

    fun decode(json: JSONObject): HardwareCapabilities {
        val schema = json.optInt("schema", SCHEMA)
        require(schema == SCHEMA) { "unsupported snapshot schema $schema" }
        val decode = json.getJSONObject("decode")
        return HardwareCapabilities(
            decode = HardwareCapabilities.Decode(
                video = objects(decode, "video").map(::readVideoDecoder),
                audio = objects(decode, "audio").map(::readAudioDecoder),
                representative = decode.optBoolean("representative", true),
            ),
            encode = json.optJSONObject("encode")?.let {
                HardwareCapabilities.Encode(hevc = supportOf(it.optString("hevc")), h264 = supportOf(it.optString("h264")))
            } ?: HardwareCapabilities.Encode(Support.Unknown, Support.Unknown),
            display = readDisplay(json.getJSONObject("display")),
            audio = json.optJSONObject("audio")?.let(::readAudio) ?: HardwareCapabilities.Audio.Unknown,
            power = json.optJSONObject("power")?.let(::readPower)
                ?: HardwareCapabilities.Power(HardwareCapabilities.Thermal.Nominal, lowPowerMode = false),
            compute = json.optJSONObject("compute")?.let(::readCompute) ?: HardwareCapabilities.Compute(
                appVersion = "", osVersion = "", osBuild = "", machine = "", simulator = false, logicalCores = null,
                memoryMB = 0, sdk = 0,
            ),
            engine = json.optJSONObject("engine")?.let(::readEngine) ?: HardwareCapabilities.Engine(player = "unknown"),
        )
    }

    private fun objects(parent: JSONObject, name: String): List<JSONObject> {
        val array = parent.optJSONArray(name) ?: return emptyList()
        return List(array.length()) { array.getJSONObject(it) }
    }

    private fun strings(parent: JSONObject, name: String): List<String> {
        val array = parent.optJSONArray(name) ?: return emptyList()
        return List(array.length()) { array.getString(it) }
    }

    private fun JSONObject.stringOrNull(name: String): String? = if (has(name) && !isNull(name)) getString(name) else null
    private fun JSONObject.intOrNull(name: String): Int? = if (has(name) && !isNull(name)) getInt(name) else null

    private fun readVideoDecoder(o: JSONObject): HardwareCapabilities.VideoDecoder {
        val fps = o.optJSONObject("maxFps")
        val maxFps = LinkedHashMap<SizeClass, Int>()
        if (fps != null) {
            for (key in fps.keys()) {
                val sizeClass = requireNotNull(SizeClass.fromCode(key)) { "unknown size class '$key'" }
                maxFps[sizeClass] = fps.getInt(key)
            }
        }
        return HardwareCapabilities.VideoDecoder(
            name = o.getString("name"),
            mimeType = o.getString("mime"),
            hardwareAccelerated = o.getBoolean("hardware"),
            softwareOnly = o.optBoolean("softwareOnly", false),
            vendor = o.optBoolean("vendor", false),
            profiles = strings(o, "profiles"),
            maxFps = maxFps,
            performancePoints = o.optBoolean("performancePoints", false),
            tunneling = o.optBoolean("tunneling", false),
        )
    }

    private fun readAudioDecoder(o: JSONObject) = HardwareCapabilities.AudioDecoder(
        name = o.getString("name"),
        mimeType = o.getString("mime"),
        softwareOnly = o.optBoolean("softwareOnly", false),
        maxChannels = o.optInt("maxChannels", 2),
    )

    private fun readMode(o: JSONObject) =
        HardwareCapabilities.DisplayMode(width = o.getInt("w"), height = o.getInt("h"), refreshRate = o.getDouble("hz"))

    private fun readDisplay(o: JSONObject) = HardwareCapabilities.Display(
        hdrTypes = strings(o, "hdrTypes").map { requireNotNull(HdrType.fromCode(it)) { "unknown HDR type '$it'" } }.toSet(),
        modes = objects(o, "modes").map(::readMode),
        currentMode = o.optJSONObject("currentMode")?.let(::readMode),
        maxFramesPerSecond = o.optInt("maxFps", 60),
        wideGamut = o.optBoolean("wideGamut", false),
        edrHeadroomPotential = o.optDouble("edrHeadroomPotential", 1.0),
        edrHeadroomCurrent = o.optDouble("edrHeadroomCurrent", 1.0),
        capturing = o.optBoolean("capturing", false),
        externalPlaybackActive = o.optBoolean("externalPlaybackActive", false),
    )

    private fun readAudio(o: JSONObject) = HardwareCapabilities.Audio(
        passthrough = strings(o, "passthrough").toSet(),
        output = o.optString("output", "unknown"),
        maxChannelCount = o.optInt("maxChannelCount", 2),
        spatializer = o.optJSONObject("spatializer")?.let {
            HardwareCapabilities.Spatializer(
                immersiveLevel = it.optString("immersiveLevel", "unsupported"),
                available = it.optBoolean("available", false),
                enabled = it.optBoolean("enabled", false),
            )
        } ?: HardwareCapabilities.Spatializer.Unsupported,
    )

    private fun readPower(o: JSONObject): HardwareCapabilities.Power {
        val name = o.optString("thermal", "nominal")
        val thermal = requireNotNull(HardwareCapabilities.Thermal.entries.firstOrNull { it.code == name }) {
            "unknown thermal state '$name'"
        }
        val battery = o.optJSONObject("battery")
        return HardwareCapabilities.Power(
            thermal = thermal,
            lowPowerMode = o.optBoolean("lowPowerMode", false),
            battery = HardwareCapabilities.Battery(
                level = battery?.takeIf { it.has("level") }?.getDouble("level")?.toFloat(),
                charging = battery?.takeIf { it.has("charging") }?.getBoolean("charging"),
            ),
        )
    }

    private fun readCompute(o: JSONObject) = HardwareCapabilities.Compute(
        appVersion = o.optString("appVersion", ""),
        osVersion = o.optString("osVersion", ""),
        osBuild = o.optString("osBuild", ""),
        machine = o.optString("machine", ""),
        simulator = o.optBoolean("simulator", false),
        logicalCores = o.intOrNull("logicalCores"),
        performanceCores = o.intOrNull("performanceCores"),
        efficiencyCores = o.intOrNull("efficiencyCores"),
        memoryMB = o.optInt("memoryMB", 0),
        sdk = o.optInt("sdk", 0),
        soc = o.stringOrNull("soc"),
        abis = strings(o, "abis"),
        gles = o.stringOrNull("gles"),
        vulkan = o.stringOrNull("vulkan"),
    )

    private fun readEngine(o: JSONObject) = HardwareCapabilities.Engine(
        player = o.optString("player", "unknown"),
        ffmpegVersion = o.stringOrNull("ffmpegVersion"),
        dav1d = o.optBoolean("dav1d", false),
        softwareAudio = strings(o, "softwareAudio").toSet(),
        dolbyVision7Fallback = o.optBoolean("dolbyVision7Fallback", false),
    )

    private fun supportOf(name: String): Support = when (name) {
        "hardware" -> Support.Hardware
        "softwareOnly" -> Support.SoftwareOnly
        "none" -> Support.None
        else -> Support.Unknown
    }
}
