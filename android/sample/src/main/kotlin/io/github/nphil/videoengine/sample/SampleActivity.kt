package io.github.nphil.videoengine.sample

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.View
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
 * each one, plays them through [EnginePlayer], checks every probe against `manifest.json`, copies the device report
 * and can serve it to a phone or a computer on the local network ([ReportServer]). Plain Views, every control
 * reachable with a D-pad, so the same build runs on a tablet and on a TV box.
 */
class SampleActivity : Activity() {
    private val scope: CoroutineScope = MainScope()
    private val logger = EngineLogger.logcat("VideoEngineSample")
    private val provider by lazy { LiveHardwareCapabilityProvider(this, logger) }

    private lateinit var playerView: PlayerView
    private lateinit var detail: TextView
    private lateinit var shareButton: Button
    private lateinit var sharePanel: View
    private lateinit var shareUrl: TextView
    private lateinit var shareHint: TextView
    private var player: ExoPlayer? = null
    private var capabilities: HardwareCapabilities? = null
    private var fixtures: List<String> = emptyList()
    private var selected: String? = null
    // Read by the report server's threads as well, hence volatile.
    @Volatile private var probeText = ""
    @Volatile private var checkText = ""
    private var capabilityText = ""

    private val ui = Handler(Looper.getMainLooper())
    private var share: ReportServer? = null
    private var shareToken = 0
    private var shareDeadline = 0L
    private var shareAddressFound = false
    private val shareTick = Runnable { updateCountdown() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_sample)
        playerView = findViewById(R.id.player)
        detail = findViewById(R.id.detail)
        shareButton = findViewById(R.id.share)
        sharePanel = findViewById(R.id.share_panel)
        shareUrl = findViewById(R.id.share_url)
        shareHint = findViewById(R.id.share_hint)
        val list = findViewById<ListView>(R.id.fixtures)
        fixtures = assets.list(FIXTURE_DIR).orEmpty().filter { it.endsWith(".mkv") }.sorted()
        list.choiceMode = ListView.CHOICE_MODE_SINGLE
        list.adapter = ArrayAdapter(this, android.R.layout.simple_list_item_single_choice, fixtures)
        list.setOnItemClickListener { _, _, position, _ -> select(fixtures[position]) }
        findViewById<Button>(R.id.play).setOnClickListener { play() }
        findViewById<Button>(R.id.check).setOnClickListener { checkAll() }
        findViewById<Button>(R.id.copy).setOnClickListener { copyDeviceReport() }
        shareButton.setOnClickListener { toggleShare() }
        list.requestFocus() // a D-pad starts on the fixture list; a touch screen is not affected

        scope.launch {
            capabilityText = snapshot().reportLines().joinToString("\n")
            render()
        }
    }

    override fun onStop() {
        stopSharing()
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
            playerView.requestFocus() // a D-pad then drives playback; a touch screen is not affected
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
            val report = buildReport(caps)
            val file = File(getExternalFilesDir(null) ?: filesDir, "device-report.txt")
            withContext(Dispatchers.IO) { file.writeText(report) }
            val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            clipboard.setPrimaryClip(ClipData.newPlainText("VideoEngine device report", report))
            Toast.makeText(this@SampleActivity, getString(R.string.report_copied, report.length, file.absolutePath), Toast.LENGTH_LONG).show()
        }
    }

    /** The text behind both the clipboard and the page on the local network. */
    private fun buildReport(caps: HardwareCapabilities): String = buildString {
        appendLine("VideoEngine device report, stage 1")
        caps.reportLines().forEach(::appendLine)
        val results = listOf(probeText, checkText).filter { it.isNotEmpty() }
        if (results.isNotEmpty()) {
            appendLine()
            appendLine("-- on-screen results --")
            results.forEach(::appendLine)
        }
        appendLine()
        appendLine("-- diagnostics --")
        appendLine(EngineDiagnostics.report())
        appendLine()
        appendLine("-- snapshot json --")
        appendLine(caps.toJsonString())
    }

    private fun toggleShare() {
        if (share != null) stopSharing() else startSharing()
    }

    /**
     * Serves the report on this device's network address for [SHARE_MILLIS], for a box with no clipboard: the address
     * is shown in large text, to be opened in a browser on a phone or a computer on the same network.
     */
    private fun startSharing() {
        val caps = capabilities
        if (caps == null) {
            Toast.makeText(this, R.string.share_wait, Toast.LENGTH_SHORT).show()
            return
        }
        val token = ++shareToken
        val server = ReportServer(
            port = SHARE_PORT,
            durationMillis = SHARE_MILLIS,
            report = { buildReport(caps) },
            snapshot = { caps.toJsonString() },
            onStopped = { error -> runOnUiThread { if (token == shareToken) sharingEnded(error) } },
        )
        share = server
        shareDeadline = SystemClock.elapsedRealtime() + SHARE_MILLIS
        val address = LocalAddress.find(this)
        shareAddressFound = address != null
        shareUrl.text = if (address != null) "http://$address:$SHARE_PORT/" else getString(R.string.share_no_address)
        shareButton.setText(R.string.share_stop)
        sharePanel.visibility = View.VISIBLE
        updateCountdown()
        server.start()
    }

    /** Stops sharing now: on the button, and when the screen is left. */
    private fun stopSharing() {
        val server = share ?: return
        shareToken++ // the server's own stop notice is then ignored
        share = null
        server.stop()
        hideShare()
    }

    /** The server ended by itself: the time ran out, or it could not start (the port is busy, for example). */
    private fun sharingEnded(error: String?) {
        share = null
        if (error == null) {
            hideShare()
            Toast.makeText(this, R.string.share_ended, Toast.LENGTH_SHORT).show()
        } else {
            ui.removeCallbacks(shareTick)
            shareButton.setText(R.string.share)
            shareUrl.setText(R.string.share_failed)
            shareHint.text = error
        }
    }

    private fun hideShare() {
        ui.removeCallbacks(shareTick)
        shareButton.setText(R.string.share)
        sharePanel.visibility = View.GONE
    }

    private fun updateCountdown() {
        val seconds = maxOf(0L, (shareDeadline - SystemClock.elapsedRealtime() + 999) / 1000)
        val left = String.format(Locale.ROOT, "%d:%02d", seconds / 60, seconds % 60)
        shareHint.text = if (shareAddressFound) {
            getString(R.string.share_hint, left)
        } else {
            getString(R.string.share_hint_no_address, left, SHARE_PORT)
        }
        if (share != null) ui.postDelayed(shareTick, 1000)
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
        const val SHARE_PORT = 8765
        const val SHARE_MILLIS = 10 * 60 * 1000L
    }
}
