package io.github.nphil.videoengine

import android.util.Log

/**
 * Where the engine reports what it is doing, as on Apple: structured events (a tag and key/value fields) and
 * free-text lines. Both callbacks may run on engine worker threads.
 */
public class EngineLogger(
    /** A structured event: a short tag such as `route` and its key/value fields. */
    public val event: (tag: String, fields: List<Pair<String, String>>) -> Unit,
    /** A free-text line. */
    public val message: (String) -> Unit,
) {
    public companion object {
        /** Drops everything. */
        public val Silent: EngineLogger = EngineLogger(event = { _, _ -> }, message = { })

        /** Writes to logcat at info level under [tag]; events read `tag key=value key=value`. */
        public fun logcat(tag: String = "VideoEngine"): EngineLogger = EngineLogger(
            event = { name, fields -> Log.i(tag, reportLine(name, fields)) },
            message = { Log.i(tag, it) },
        )
    }
}

/** The report's line grammar: `tag key=value key=value`. */
internal fun reportLine(tag: String, fields: List<Pair<String, String>>): String =
    if (fields.isEmpty()) tag else fields.joinToString(" ", prefix = "$tag ") { "${it.first}=${it.second}" }

/** Logs a measurement and keeps it for [EngineDiagnostics.report]. */
internal fun EngineLogger.measurement(tag: String, fields: List<Pair<String, String>>) {
    event(tag, fields)
    EngineDiagnostics.note(reportLine(tag, fields))
}
