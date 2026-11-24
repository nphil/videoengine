package io.github.nphil.videoengine.sample

import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * A tiny read-only HTTP server for the device report, so a box with no clipboard can hand it to a phone or a computer
 * on the same network: `GET /` answers the text report, `GET /snapshot.json` the capability snapshot. One plain
 * [ServerSocket] accepts on a background thread and every request is answered on its own short-lived thread, so an
 * idle speculative connection from a browser never holds the others up. It stops after [durationMillis] or on
 * [stop], and then calls [onStopped] once, on the server thread, with the failure message if it could not run.
 * Plain HTTP on purpose: this is for the local network, and a certificate would only get in the way.
 *
 * [report] and [snapshot] run on the request threads, so they must be safe to call from any thread.
 */
class ReportServer(
    private val port: Int,
    private val durationMillis: Long,
    private val report: () -> String,
    private val snapshot: () -> String,
    private val onStopped: (error: String?) -> Unit,
) {
    private val running = AtomicBoolean(false)
    private val clients = AtomicInteger()

    @Volatile
    private var listener: ServerSocket? = null

    /** Starts the server thread. The port is bound on that thread, so a port already in use comes back through [onStopped]. */
    fun start() {
        check(running.compareAndSet(false, true)) { "The report server was already started" }
        Thread({ serve() }, "ve-report-server").apply { isDaemon = true }.start()
    }

    /** Stops accepting. Safe from any thread, and more than once. */
    fun stop() {
        running.set(false)
        closeQuietly(listener)
    }

    private fun serve() {
        var error: String? = null
        var server: ServerSocket? = null
        try {
            val bound = ServerSocket()
            server = bound
            bound.reuseAddress = true
            bound.soTimeout = POLL_MILLIS
            bound.bind(InetSocketAddress(port))
            listener = bound
            val deadline = System.nanoTime() + durationMillis * 1_000_000
            while (running.get() && System.nanoTime() - deadline < 0) {
                val client = try {
                    bound.accept()
                } catch (_: SocketTimeoutException) {
                    continue // wake up to look at the stop flag and the clock
                }
                if (clients.incrementAndGet() > MAX_CLIENTS) {
                    clients.decrementAndGet()
                    closeQuietly(client)
                    continue
                }
                Thread({ handle(client) }, "ve-report-client").apply { isDaemon = true }.start()
            }
        } catch (e: IOException) {
            if (running.get()) error = e.message ?: e.javaClass.simpleName
        } finally {
            running.set(false)
            closeQuietly(server)
            onStopped(error)
        }
    }

    private fun handle(client: Socket) {
        try {
            client.use {
                it.soTimeout = CLIENT_TIMEOUT_MILLIS
                answer(it)
            }
        } catch (_: IOException) {
            // The client left or was too slow; the other clients are unaffected.
        } finally {
            clients.decrementAndGet()
        }
    }

    private fun answer(client: Socket) {
        val input = client.getInputStream().buffered()
        val request = readLine(input) ?: return
        var headerBytes = 0
        while (true) { // the answer does not depend on the headers, so they are only read past
            val header = readLine(input) ?: break
            if (header.isEmpty()) break
            headerBytes += header.length
            if (headerBytes > MAX_HEADER_BYTES) throw IOException("The request headers are too large")
        }
        val parts = request.split(' ')
        val method = parts[0]
        val path = parts.getOrElse(1) { "/" }.substringBefore('?')
        val response = try {
            route(method, path)
        } catch (e: RuntimeException) {
            Response("500 Internal Server Error", TEXT, "Could not build the answer: $e\n")
        }
        val body = response.body.toByteArray(Charsets.UTF_8)
        val head = "HTTP/1.1 ${response.status}\r\n" +
            "Content-Type: ${response.type}\r\n" +
            "Content-Length: ${body.size}\r\n" +
            "Allow: GET, HEAD\r\n" +
            "Cache-Control: no-store\r\n" +
            "Connection: close\r\n\r\n"
        val out = client.getOutputStream()
        out.write(head.toByteArray(Charsets.ISO_8859_1))
        if (method != "HEAD") out.write(body)
        out.flush()
    }

    private fun route(method: String, path: String): Response = when {
        method != "GET" && method != "HEAD" -> Response("405 Method Not Allowed", TEXT, "This server is read-only.\n")
        path == "/" -> Response("200 OK", TEXT, report())
        path == "/snapshot.json" -> Response("200 OK", JSON, snapshot())
        else -> Response("404 Not Found", TEXT, "Not found. Try / or /snapshot.json\n")
    }

    /** One line without its line end; null at the end of the stream. Lines are short, so a long one ends the request. */
    private fun readLine(input: InputStream): String? {
        val line = StringBuilder()
        while (true) {
            val b = input.read()
            if (b < 0) return if (line.isEmpty()) null else line.toString()
            if (b == '\n'.code) return line.toString().trimEnd('\r')
            if (line.length >= MAX_LINE) throw IOException("The request line is too long")
            line.append(b.toChar())
        }
    }

    private fun closeQuietly(closeable: Closeable?) {
        try {
            closeable?.close()
        } catch (_: IOException) {
            // Closing only releases the socket; there is nothing to recover.
        }
    }

    private class Response(val status: String, val type: String, val body: String)

    private companion object {
        const val POLL_MILLIS = 500
        const val CLIENT_TIMEOUT_MILLIS = 3000
        const val MAX_CLIENTS = 8
        const val MAX_LINE = 4096
        const val MAX_HEADER_BYTES = 16 * 1024
        const val TEXT = "text/plain; charset=utf-8"
        const val JSON = "application/json; charset=utf-8"
    }
}
