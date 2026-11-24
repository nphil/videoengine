package io.github.nphil.videoengine

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Replays `shared/route-vectors.json`: the platform-neutral cases every RoutePlanner has to agree on. */
class RouteVectorsTest {
    @Test
    fun everyVectorGetsItsExpectedRoute() {
        val snapshots = VectorJson.snapshots.associate {
            it.getString("id") to HardwareCapabilities.fromJson(it.getJSONObject("capabilities"))
        }
        val failures = ArrayList<String>()
        for (vector in VectorJson.vectors) {
            val options = vector.optJSONObject("options")
            val decision = RoutePlanner.decide(
                info = VectorJson.mediaInfo(vector.getJSONObject("media")),
                capabilities = snapshots.getValue(vector.getString("snapshot")),
                verdicts = verdicts(vector.optJSONObject("verdicts")),
                options = RouteOptions(
                    audioIndex = options?.intOrNull("audioIndex"),
                    canRepackage = options?.optBoolean("canRepackage", false) ?: false,
                ),
            )
            val expect = vector.getJSONObject("expect")
            val expected = "${expect.getString("route")} / ${expect.getString("reason")}"
            val actual = "${decision.route.code} / ${decision.reason.code}"
            if (expected != actual) failures += "${vector.getString("id")} (rule ${vector.get("rule")}): expected $expected, got $actual"
        }
        assertTrue("${failures.size} of ${VectorJson.vectors.size} vectors failed:\n" + failures.joinToString("\n"), failures.isEmpty())
    }

    @Test
    fun everyRuleOfTheTableHasAVector() {
        val covered = VectorJson.vectors.map { it.get("rule").toString() }.toSet()
        val missing = ((1..10).map(Int::toString) + "4b").filter { it !in covered }
        assertTrue("rules without a vector: $missing", missing.isEmpty())
    }

    @Test
    fun deviceSnapshotsAreProvisionalAndSaySoWhatIsMissing() {
        for (snapshot in VectorJson.snapshots) {
            val id = snapshot.getString("id")
            if (id.startsWith("synthetic-")) {
                assertEquals("$id is hand-written, not provisional", false, snapshot.getBoolean("provisional"))
            } else {
                assertTrue("$id must be provisional until a device report replaces it", snapshot.getBoolean("provisional"))
                assertTrue("$id must list what it assumes", snapshot.getJSONArray("assumed").length() > 0)
                assertTrue("$id must list what it does not know", snapshot.getJSONArray("unknown").length() > 0)
            }
        }
    }

    @Test
    fun snapshotsSurviveAJsonRoundTrip() {
        for (snapshot in VectorJson.snapshots) {
            val original = HardwareCapabilities.fromJson(snapshot.getJSONObject("capabilities"))
            assertEquals(snapshot.getString("id"), original, HardwareCapabilities.fromJson(original.toJsonString()))
        }
    }

    @Test
    fun theLogLineNamesRouteAndReason() {
        assertEquals("route route=serverTranscode reason=dv-unsupported", RouteDecision(Route.ServerTranscode, RouteReason.DvUnsupported).logLine)
    }

    private fun verdicts(o: JSONObject?): Map<Int, DecodeVerdict> =
        o?.keys()?.asSequence()?.associate { it.toInt() to requireNotNull(DecodeVerdict.fromCode(o.getString(it))) }.orEmpty()
}
