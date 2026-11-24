package io.github.nphil.videoengine

/**
 * Why an engine operation failed. The names mirror the Apple `VideoEngineError`; only the cases stage 1 can
 * raise exist so far. A coroutine cancel surfaces as `CancellationException`, never as one of these.
 */
public sealed class VideoEngineError(message: String, cause: Throwable? = null) : Exception(message, cause) {
    /** The server refused the request ([status] set) or could not be reached ([status] null). */
    public class SourceUnreachable(public val status: Int?, cause: Throwable? = null) : VideoEngineError(
        if (status != null) "The video server answered with HTTP $status." else "The video server could not be reached.",
        cause,
    )

    /** The source is not a container the player can read. */
    public class UnsupportedSource(public val reason: String, cause: Throwable? = null) :
        VideoEngineError("The video source is not supported: $reason.", cause)

    /** The source was reached but could not be opened. */
    public class OpenFailed(public val detail: String, cause: Throwable? = null) :
        VideoEngineError("The video could not be opened: $detail.", cause)

    /** The source has no playable audio or video. */
    public class NoPlayableStreams : VideoEngineError("The video has no playable audio or video.")

    /** The source stopped responding. */
    public class TimedOut(cause: Throwable? = null) : VideoEngineError("The video stopped responding.", cause)
}
