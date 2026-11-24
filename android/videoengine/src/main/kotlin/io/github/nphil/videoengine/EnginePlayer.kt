package io.github.nphil.videoengine

import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaLibraryInfo
import androidx.media3.common.PlaybackException
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector

/**
 * What the app may ask of playback. Only options that change something are here.
 *
 * @param matchFrameRate ask the display to switch to the video's frame rate when the switch is seamless (no
 *   black screen); false never asks.
 * @param tunneling use tunnelled playback where a hardware decoder in the snapshot advertises it. Off by
 *   default: it is not trusted on either target device until a device report says it works.
 */
public data class PlaybackOptions(
    val matchFrameRate: Boolean = true,
    val tunneling: Boolean = false,
)

/**
 * Builds the ExoPlayer for one playback, set up from one capability snapshot:
 * - hardware decoders are tried before software ones, and a failing decoder falls back to the next;
 * - no FFmpeg or other extension renderer is attached, so Dolby Atmos (E-AC-3 JOC), AC-4 and every other
 *   object-audio stream goes to the platform decoder or, when the output takes it, straight through;
 * - tunnelling stays off unless [PlaybackOptions.tunneling] asks for it and a hardware decoder offers it.
 *
 * The app owns the player: hand it to a `PlayerView` and `release()` it. Decoder choices and playback errors
 * are logged through [EngineLogger] and kept for [EngineDiagnostics.report]. In stage 3 this grows into the
 * `PlaybackSession` the platform plan describes.
 */
@OptIn(UnstableApi::class)
public object EnginePlayer {
    /** Builds a player for [capabilities]. Call on the thread that will use the player (normally the main thread). */
    public fun create(
        context: Context,
        capabilities: HardwareCapabilities,
        options: PlaybackOptions = PlaybackOptions(),
        logger: EngineLogger = EngineLogger.Silent,
    ): ExoPlayer {
        val appContext = context.applicationContext
        val tunneling = options.tunneling && capabilities.decode.video.any { it.isHardware && it.tunneling }
        val renderers = DefaultRenderersFactory(appContext)
            .setMediaCodecSelector(HardwareFirstSelector())
            .setEnableDecoderFallback(true)
            .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_OFF)
        val trackSelector = DefaultTrackSelector(appContext)
        trackSelector.setParameters(trackSelector.buildUponParameters().setTunnelingEnabled(tunneling))
        val player = ExoPlayer.Builder(appContext, renderers)
            .setTrackSelector(trackSelector)
            .setAudioAttributes(
                AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(),
                /* handleAudioFocus = */ true,
            )
            .setHandleAudioBecomingNoisy(true)
            .setVideoChangeFrameRateStrategy(
                if (options.matchFrameRate) C.VIDEO_CHANGE_FRAME_RATE_STRATEGY_ONLY_IF_SEAMLESS else C.VIDEO_CHANGE_FRAME_RATE_STRATEGY_OFF,
            )
            .build()
        player.addAnalyticsListener(PlaybackLog(capabilities, logger))
        logger.event(
            "player",
            listOf(
                "engine" to "media3-${MediaLibraryInfo.VERSION}",
                "tunneling" to HardwareCapabilities.flag(tunneling),
                "match_fps" to HardwareCapabilities.flag(options.matchFrameRate),
            ),
        )
        return player
    }

    /** Takes a snapshot from [provider] and builds the player for it. */
    public suspend fun create(
        context: Context,
        provider: HardwareCapabilityProvider,
        options: PlaybackOptions = PlaybackOptions(),
        logger: EngineLogger = EngineLogger.Silent,
    ): ExoPlayer = create(context, provider.snapshot(), options, logger)
}

/** [MediaCodecSelector.DEFAULT]'s decoders with the hardware ones first, each group in its original order. */
@OptIn(UnstableApi::class)
internal class HardwareFirstSelector(private val base: MediaCodecSelector = MediaCodecSelector.DEFAULT) : MediaCodecSelector {
    override fun getDecoderInfos(
        mimeType: String,
        requiresSecureDecoder: Boolean,
        requiresTunnelingDecoder: Boolean,
    ): List<MediaCodecInfo> {
        val (hardware, other) = base.getDecoderInfos(mimeType, requiresSecureDecoder, requiresTunnelingDecoder)
            .partition { it.hardwareAccelerated && !it.softwareOnly }
        return hardware + other
    }
}

/** Logs which decoders and audio output the player actually opened, and why playback failed. */
@OptIn(UnstableApi::class)
private class PlaybackLog(
    private val capabilities: HardwareCapabilities,
    private val logger: EngineLogger,
) : AnalyticsListener {
    override fun onVideoDecoderInitialized(
        eventTime: AnalyticsListener.EventTime,
        decoderName: String,
        initializedTimestampMs: Long,
        initializationDurationMs: Long,
    ) {
        val hardware = capabilities.decode.video.firstOrNull { it.name == decoderName }?.isHardware
        logger.measurement(
            "play-dec",
            listOf(
                "kind" to "video",
                "name" to decoderName,
                "hw" to (hardware?.let(HardwareCapabilities::flag) ?: "?"),
                "init_ms" to initializationDurationMs.toString(),
            ),
        )
    }

    override fun onAudioDecoderInitialized(
        eventTime: AnalyticsListener.EventTime,
        decoderName: String,
        initializedTimestampMs: Long,
        initializationDurationMs: Long,
    ) {
        logger.measurement(
            "play-dec",
            listOf("kind" to "audio", "name" to decoderName, "hw" to "?", "init_ms" to initializationDurationMs.toString()),
        )
    }

    override fun onAudioTrackInitialized(eventTime: AnalyticsListener.EventTime, audioTrackConfig: AudioSink.AudioTrackConfig) {
        logger.measurement(
            "play-audio",
            listOf(
                "encoding" to audioTrackConfig.encoding.toString(),
                "rate" to audioTrackConfig.sampleRate.toString(),
                "channel_config" to audioTrackConfig.channelConfig.toString(),
                "tunneling" to HardwareCapabilities.flag(audioTrackConfig.tunneling),
                "offload" to HardwareCapabilities.flag(audioTrackConfig.offload),
            ),
        )
    }

    override fun onDroppedVideoFrames(eventTime: AnalyticsListener.EventTime, droppedFrames: Int, elapsedMs: Long) {
        logger.measurement("play-drop", listOf("frames" to droppedFrames.toString(), "ms" to elapsedMs.toString()))
    }

    override fun onPlayerError(eventTime: AnalyticsListener.EventTime, error: PlaybackException) {
        logger.measurement(
            "play-error",
            listOf("code" to error.errorCodeName, "detail" to HardwareCapabilities.field(error.message)),
        )
    }
}
