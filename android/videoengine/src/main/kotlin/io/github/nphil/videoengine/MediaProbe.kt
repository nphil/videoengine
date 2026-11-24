package io.github.nphil.videoengine

import android.content.Context
import android.net.Uri
import android.os.SystemClock
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.Format
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.HttpDataSource
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.UnrecognizedInputFormatException
import androidx.media3.inspector.MetadataRetriever
import java.io.FileNotFoundException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout

/**
 * Reads what a source contains, without playing it: container, duration and every stream's facts, through
 * Media3's own extractors (no FFmpeg). The result is in FFmpeg vocabulary, as on Apple.
 */
@OptIn(UnstableApi::class)
public object MediaProbe {
    /**
     * Probes [uri]: an `http(s)` URL, a `file`, `content` or `asset` URI.
     *
     * @param headers request headers for an `http(s)` source, sent exactly as given.
     * @param timeoutSeconds how long the whole probe may take.
     * @throws VideoEngineError when the source cannot be reached, is not a container the player reads, or times out.
     */
    public suspend fun probe(
        context: Context,
        uri: Uri,
        headers: Map<String, String> = emptyMap(),
        timeoutSeconds: Double = 8.0,
        logger: EngineLogger = EngineLogger.Silent,
    ): MediaInfo {
        val appContext = context.applicationContext
        val started = SystemClock.elapsedRealtime()
        val http = DefaultHttpDataSource.Factory().setDefaultRequestProperties(headers)
        val sources = DefaultMediaSourceFactory(DefaultDataSource.Factory(appContext, http))
        val retriever = MetadataRetriever.Builder(appContext, MediaItem.fromUri(uri)).setMediaSourceFactory(sources).build()
        try {
            val info = withTimeout((timeoutSeconds * 1000).toLong()) {
                val groups = retriever.retrieveTrackGroups().await()
                val durationUs = retriever.retrieveDurationUs().await()
                val formats = ArrayList<Format>(groups.length)
                for (i in 0 until groups.length) formats.add(groups[i].getFormat(0))
                ProbeMapper.map(formats, durationUs, uri.lastPathSegment)
            }
            logger.event(
                "probe",
                listOf(
                    "container" to info.container,
                    "video" to info.video.size.toString(),
                    "audio" to info.audio.size.toString(),
                    "subs" to info.subtitles.size.toString(),
                    "ms" to (SystemClock.elapsedRealtime() - started).toString(),
                ),
            )
            return info
        } catch (e: TimeoutCancellationException) {
            throw VideoEngineError.TimedOut(e)
        } catch (e: VideoEngineError) {
            throw e
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            throw map(e)
        } finally {
            retriever.close()
        }
    }

    internal fun map(error: Throwable): VideoEngineError {
        val chain = generateSequence(error) { it.cause }.toList()
        chain.firstNotNullOfOrNull { it as? HttpDataSource.InvalidResponseCodeException }
            ?.let { return VideoEngineError.SourceUnreachable(it.responseCode, error) }
        if (chain.any { it is HttpDataSource.HttpDataSourceException }) return VideoEngineError.SourceUnreachable(null, error)
        if (chain.any { it is UnrecognizedInputFormatException }) {
            return VideoEngineError.UnsupportedSource("no extractor reads this container", error)
        }
        if (chain.any { it is FileNotFoundException }) return VideoEngineError.OpenFailed("the file was not found", error)
        return VideoEngineError.OpenFailed(error.message ?: error.javaClass.simpleName, error)
    }
}
