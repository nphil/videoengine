package io.github.nphil.videoengine.sample

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.ListView
import android.widget.TextView
import android.widget.Toast
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import io.github.nphil.videoengine.EngineDiagnostics
import io.github.nphil.videoengine.EngineLogger
import io.github.nphil.videoengine.EnginePlayer
import io.github.nphil.videoengine.HardwareCapabilities
import io.github.nphil.videoengine.LiveHardwareCapabilityProvider
import io.github.nphil.videoengine.MediaInfo
import io.github.nphil.videoengine.MediaProbe
import io.github.nphil.videoengine.PlaybackOptions
import io.github.nphil.videoengine.RoutePlanner
import io.github.nphil.videoengine.VideoEngineError
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Locale

/**
 * The stage 1 test bench. It lists the repository's fixtures, shows what the probe and the route planner make of
 * each one, plays them through [EnginePlayer], checks every probe against `manifest.json` and copies the device
 * report. Plain Views and D-pad friendly, so the same build runs on a tablet and on a TV box.
 */
class SampleActivity : Activity() {
    private val scope: CoroutineScope = MainScope()
    private val logger = EngineLogger.logcat("VideoEngineSample")
    private val provider by lazy { LiveHardwareCapabilityProvider(this, logger) }

    private lateinit var playerView: PlayerView
    private lateinit var detail: TextView
    private var player: ExoPlayer? = null
    private var capabilities: HardwareCapabilities? = null
    private var fixtures: List<String> = emptyList()
    private var selected: String? = null
    private var probeText = ""
    private var checkText = ""
    private var capabilityText = ""

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_sample)
        playerView = findViewById(R.id.player)
        detail = findViewById(R.id.detail)
        val list = findViewById<ListView>(R.id.fixtures)
        fixtures = assets.list(FIXTURE_DIR).orEmpty().filter { it.endsWith(".mkv") }.sorted()
        list.choiceMode = ListView.CHOICE_MODE_SINGLE
        list.adapter = ArrayAdapter(this, android.R.layout.simple_list_item_single_choice, fixtures)
        list.setOnItemClickListener { _, _, position, _ -> select(fixtures[position]) }
        findViewById<Button>(R.id.play).setOnClickListener { play() }
        findViewById<Button>(R.id.check).setOnClickListener { checkAll() }
        findViewById<Button>(R.id.copy).setOnClickListener { copyDeviceReport() }

        scope.launch {
            capabilityText = snapshot().reportLines().joinToString("\n")
            render()
        }
    }

    override fun onStop() {
        player?.pause()
        super.onStop()
    }

    override fun onDestroy() {
        scope.cancel()
        player?.release()
        player = null
        super.onDestroy()
    }

    private suspend fun snapshot(): HardwareCapabilities = capabilities ?: provider.snapshot().also { capabilities = it }

    private fun render() {
        detail.text = listOf(probeText, checkText, capabilityText).filter { it.isNotEmpty() }.joinToString("\n\n")
    }

    private fun uriOf(name: String): Uri = Uri.parse("asset:///$FIXTURE_DIR/$name")

    /** Probes the fixture and shows the probe and the route the planner picks for it on this device. */
    private fun select(name: String) {
        selected = name
        scope.launch {
            probeText = try {
                val info = MediaProbe.probe(this@SampleActivity, uriOf(name), logger = logger)
                val decision = RoutePlanner.decide(info, snapshot())
                logger.event("route", listOf("source" to name, "route" to decision.route.code, "reason" to decision.reason.code))
                describe(name, info) + decision.logLine
            } catch (error: VideoEngineError) {
                "$name\nprobe failed: ${error.message}"
            }
            render()
        }
    }

    private fun play() {
        val name = selected ?: return
        scope.launch {
            val exo = EnginePlayer.create(this@SampleActivity, snapshot(), PlaybackOptions(), logger)
            exo.addListener(
                object : Player.Listener {
                    override fun onPlayerError(error: PlaybackException) {
                        probeText += "\nplayback error: ${error.errorCodeName}"
                        render()
                    }
                },
            )
            player?.release()
            player = exo
            playerView.player = exo
            exo.setMediaItem(MediaItem.fromUri(uriOf(name)))
            exo.prepare()
            exo.playWhenReady = true
        }
    }

    /** The stage 1 exit gate: every fixture's probe has to equal what ffprobe says in `manifest.json`. */
    private fun checkAll() {
        scope.launch {
            val manifest = withContext(Dispatchers.IO) { FixtureManifest.load(this@SampleActivity) }
            val lines = ArrayList<String>()
            var failed = 0
            for (name in fixtures) {
                val expected = manifest.optJSONObject(name)
                if (expected == null) {
                    failed++
                    lines += "FAIL $name: not in manifest.json"
                    continue
                }
                val problems = try {
                    FixtureManifest.compare(expected, MediaProbe.probe(this@SampleActivity, uriOf(name), logger = logger))
                } catch (error: VideoEngineError) {
                    listOf("probe failed: ${error.message}")
                }
                if (problems.isEmpty()) {
                    lines += "PASS $name"
                } else {
                    failed++
                    lines += "FAIL $name"
                    problems.forEach { lines += "  $it" }
                }
            }
            lines += if (failed == 0) "probe equals manifest.json: PASS (${fixtures.size} files)" else "probe equals manifest.json: FAIL ($failed of ${fixtures.size})"
            checkText = lines.joinToString("\n")
            render()
        }
    }

    /** Puts the hardware lines, the recent diagnostics and the snapshot JSON on the clipboard and in a file `adb pull` can fetch. */
    private fun copyDeviceReport() {
        scope.launch {
            val caps = snapshot()
            val report = buildString {
                appendLine("VideoEngine device report, stage 1")
                caps.reportLines().forEach(::appendLine)
                appendLine()
                appendLine("-- diagnostics --")
                appendLine(EngineDiagnostics.report())
                appendLine()
                appendLine("-- snapshot json --")
                appendLine(caps.toJsonString())
            }
            val file = File(getExternalFilesDir(null) ?: filesDir, "device-report.txt")
            withContext(Dispatchers.IO) { file.writeText(report) }
            val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            clipboard.setPrimaryClip(ClipData.newPlainText("VideoEngine device report", report))
            Toast.makeText(this@SampleActivity, getString(R.string.report_copied, report.length, file.absolutePath), Toast.LENGTH_LONG).show()
        }
    }

    private fun describe(name: String, info: MediaInfo): String = buildString {
        appendLine("$name: ${info.container}, ${info.duration?.let { String.format(Locale.ROOT, "%.3f s", it) } ?: "no duration"}")
        for (v in info.video) {
            appendLine(
                "  video ${v.index} ${v.codec} ${v.profile ?: "-"} level ${v.level ?: "-"} ${v.width}x${v.height} " +
                    "${v.bitDepth ?: "-"}-bit ${v.frameRate?.let { String.format(Locale.ROOT, "%.3f fps", it) } ?: ""} " +
                    "transfer=${v.colorTransfer ?: "-"} primaries=${v.colorPrimaries ?: "-"} range=${v.colorRange ?: "-"}",
            )
        }
        for (a in info.audio) {
            appendLine("  audio ${a.index} ${a.codec} ${a.profile ?: "-"} ${a.channels} ch ${a.sampleRate} Hz ${a.language ?: "-"}")
        }
        for (s in info.subtitles) appendLine("  subtitle ${s.index} ${s.codec} ${s.language ?: "-"}")
    }

    private companion object {
        const val FIXTURE_DIR = "fixtures"
    }
}
