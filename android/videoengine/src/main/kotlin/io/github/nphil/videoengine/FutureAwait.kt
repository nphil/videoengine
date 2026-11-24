package io.github.nphil.videoengine

import com.google.common.util.concurrent.ListenableFuture
import java.util.concurrent.CancellationException
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executor
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine

private val DirectExecutor = Executor { it.run() }

/** Suspends until the future completes; cancelling the coroutine cancels the future. */
internal suspend fun <T> ListenableFuture<T>.await(): T = suspendCancellableCoroutine { continuation ->
    addListener(
        {
            try {
                continuation.resume(get())
            } catch (e: ExecutionException) {
                continuation.resumeWithException(e.cause ?: e)
            } catch (e: CancellationException) {
                continuation.cancel(e)
            }
        },
        DirectExecutor,
    )
    continuation.invokeOnCancellation { cancel(false) }
}
