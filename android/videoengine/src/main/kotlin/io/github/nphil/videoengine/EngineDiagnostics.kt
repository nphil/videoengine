package io.github.nphil.videoengine

/**
 * What the engine measured recently, for a support screen or a bug report: the last 100 lines, each
 * `tag key=value ...`, with the same tags and keys as the Apple engine (`hw-id`, `hw-dec`, `route`, ...).
 */
public object EngineDiagnostics {
    private const val CAPACITY = 100
    private val lines = ArrayDeque<String>(CAPACITY)

    /** The recent lines, oldest first, one per line. */
    public fun report(): String = synchronized(lines) { lines.joinToString("\n") }

    internal fun note(line: String) {
        synchronized(lines) {
            if (lines.size == CAPACITY) lines.removeFirst()
            lines.addLast(line)
        }
    }

    internal fun clear() {
        synchronized(lines) { lines.clear() }
    }
}
