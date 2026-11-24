package io.github.nphil.videoengine

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.display.DisplayManager
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.Spatializer
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import androidx.annotation.RequiresApi
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** Where the planner and the player get the device's facts: one snapshot per playback start, and a stream of changes. */
public interface HardwareCapabilityProvider {
    /** The device's capabilities now. */
    public suspend fun snapshot(): HardwareCapabilities

    /** Whether this device decodes [stream] in hardware. */
    public suspend fun decodeVerdict(stream: VideoStreamFacts): DecodeVerdict

    /** A new snapshot each time something that can change does: thermal state, power saving, display, audio route. */
    public fun changes(): Flow<HardwareCapabilities>
}

/**
 * A provider that returns what it was given, for tests and for replaying a recorded device report.
 *
 * @param verdict the answer for every stream; null derives it from [capabilities] like the live provider.
 */
public class FixedHardwareCapabilityProvider(
    private val capabilities: HardwareCapabilities,
    private val verdict: DecodeVerdict? = null,
) : HardwareCapabilityProvider {
    override suspend fun snapshot(): HardwareCapabilities = capabilities

    override suspend fun decodeVerdict(stream: VideoStreamFacts): DecodeVerdict =
        verdict ?: DecodeVerdicts.verdict(capabilities, stream)

    override fun changes(): Flow<HardwareCapabilities> = emptyFlow()
}

/**
 * Reads the device. The decoder and encoder lists and the identity are measured once, off the calling thread;
 * display, audio route and power are read for each snapshot. The first snapshot adds every `hw-*` line to
 * [EngineDiagnostics]; later ones add a `hw-state` line only when thermal, power saving, HDR or external
 * playback changed. Verdicts are cached per [VideoStreamFacts].
 */
public class LiveHardwareCapabilityProvider(
    context: Context,
    private val logger: EngineLogger = EngineLogger.Silent,
) : HardwareCapabilityProvider {
    private val appContext = context.applicationContext
    private val probe = PlatformProbe(appContext)
    private val fixedLock = Mutex()

    @Volatile
    private var fixed: PlatformProbe.Fixed? = null
    private val verdicts = ConcurrentHashMap<String, DecodeVerdict>()
    private var lastState: String? = null

    private suspend fun fixed(): PlatformProbe.Fixed = fixed ?: fixedLock.withLock {
        fixed ?: withContext(Dispatchers.IO) { probe.measureFixed() }.also { fixed = it }
    }

    override suspend fun snapshot(): HardwareCapabilities {
        val fixed = fixed()
        val snapshot = withContext(Dispatchers.IO) {
            HardwareCapabilities(
                decode = fixed.decode,
                encode = fixed.encode,
                display = probe.display(),
                audio = probe.audio(),
                power = probe.power(),
                compute = fixed.compute,
                engine = fixed.engine,
            )
        }
        note(snapshot)
        return snapshot
    }

    private fun note(snapshot: HardwareCapabilities) {
        val lines: List<String>
        synchronized(this) {
            val state = snapshot.stateLine
            lines = when {
                lastState == null -> snapshot.reportLines()
                state != lastState -> listOf(state)
                else -> emptyList()
            }
            lastState = state
        }
        for (line in lines) {
            EngineDiagnostics.note(line)
            logger.message(line)
        }
    }

    override suspend fun decodeVerdict(stream: VideoStreamFacts): DecodeVerdict {
        val key = stream.cacheKey
        verdicts[key]?.let { return it }
        val started = SystemClock.elapsedRealtime()
        val verdict = DecodeVerdicts.verdict(fixed().decode, stream)
        verdicts[key] = verdict
        val line = "hw-probe codec=${stream.codec} prof=${HardwareCapabilities.field(stream.profile)} " +
            "lvl=${stream.level ?: "-"} wh=${stream.width}x${stream.height} bits=${stream.bitDepth} " +
            "verdict=${verdict.code} err=- src=advertised ms=${SystemClock.elapsedRealtime() - started}"
        EngineDiagnostics.note(line)
        logger.message(line)
        return verdict
    }

    override fun changes(): Flow<HardwareCapabilities> = flow {
        var last = snapshot()
        triggers().collect {
            val now = snapshot()
            if (now != last) {
                last = now
                emit(now)
            }
        }
    }

    /** Fires when thermal state, power saving, the display or the audio route may have changed. */
    private fun triggers(): Flow<Unit> = callbackFlow {
        val main = Handler(Looper.getMainLooper())
        val executor = appContext.mainExecutor
        val power = appContext.getSystemService(PowerManager::class.java)
        val displays = appContext.getSystemService(DisplayManager::class.java)
        val audio = appContext.getSystemService(AudioManager::class.java)

        val thermal = PowerManager.OnThermalStatusChangedListener { trySend(Unit) }
        power.addThermalStatusListener(executor, thermal)

        val powerSave = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                trySend(Unit)
            }
        }
        val powerSaveFilter = IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
        if (Build.VERSION.SDK_INT >= 33) {
            appContext.registerReceiver(powerSave, powerSaveFilter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            appContext.registerReceiver(powerSave, powerSaveFilter)
        }

        val display = object : DisplayManager.DisplayListener {
            override fun onDisplayAdded(displayId: Int) {
                trySend(Unit)
            }

            override fun onDisplayRemoved(displayId: Int) {
                trySend(Unit)
            }

            override fun onDisplayChanged(displayId: Int) {
                trySend(Unit)
            }
        }
        displays.registerDisplayListener(display, main)

        val route = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) {
                trySend(Unit)
            }

            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) {
                trySend(Unit)
            }
        }
        audio.registerAudioDeviceCallback(route, main)

        val stopSpatializer = if (Build.VERSION.SDK_INT >= 32) SpatializerEvents.listen(audio, executor) { trySend(Unit) } else null

        awaitClose {
            stopSpatializer?.invoke()
            audio.unregisterAudioDeviceCallback(route)
            displays.unregisterDisplayListener(display)
            appContext.unregisterReceiver(powerSave)
            power.removeThermalStatusListener(thermal)
        }
    }.conflate()
}

/** Spatializer listeners exist from API 32; keeping them here keeps the older-API class loading clean. */
@RequiresApi(32)
private object SpatializerEvents {
    fun listen(audio: AudioManager, executor: java.util.concurrent.Executor, onChange: () -> Unit): () -> Unit {
        val spatializer = audio.spatializer
        val listener = object : Spatializer.OnSpatializerStateChangedListener {
            override fun onSpatializerEnabledChanged(spatializer: Spatializer, enabled: Boolean) = onChange()
            override fun onSpatializerAvailableChanged(spatializer: Spatializer, available: Boolean) = onChange()
        }
        spatializer.addOnSpatializerStateChangedListener(executor, listener)
        return { spatializer.removeOnSpatializerStateChangedListener(listener) }
    }
}
