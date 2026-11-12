package app.payday

import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

class APIContractTests {
    private fun response(data: String) = MockResponse().setHeader("Content-Type", "application/json").setBody("{\"data\":$data}")
    @Test fun patchSendsAbsoluteIntegerAndChecksCategoryIdentity() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(response("{\"category\":{\"id\":\"food\",\"budgeted\":123450}}"))
            val api = YNABClient("synthetic-token", baseURL = server.url("/v1/").toString())
            assertEquals(123_450L, api.assign("plan", "2026-10-01", "food", 123_450))
            val request = server.takeRequest(); assertEquals("PATCH", request.method); assertEquals("/v1/plans/plan/months/2026-10-01/categories/food", request.path)
            assertEquals("Bearer synthetic-token", request.getHeader("Authorization")); assertEquals("{\"category\":{\"budgeted\":123450}}", request.body.readUtf8())
            server.enqueue(response("{\"category\":{\"id\":\"other\",\"budgeted\":123450}}"))
            assertTrue(runCatching { api.assign("plan", "2026-10-01", "food", 123_450) }.isFailure)
        }
    }
    @Test fun snapshotIncludesFutureMonthMinimumAndEligibility() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(response("""{"month":{"month":"2026-10-01","to_be_budgeted":500000,"categories":[{"id":"food","name":"Food","category_group_id":"daily","budgeted":50000,"balance":20000,"hidden":false,"deleted":false,"internal":false},{"id":"hidden","name":"Hidden","category_group_id":"internal","budgeted":0,"balance":0,"hidden":false,"deleted":false,"internal":false}]}}"""))
            server.enqueue(response("""{"months":[{"month":"2026-09-01","to_be_budgeted":-100000},{"month":"2026-10-01","to_be_budgeted":500000},{"month":"2026-11-01","to_be_budgeted":120000}]}"""))
            server.enqueue(response("""{"category_groups":[{"id":"daily","name":"Everyday","hidden":false,"deleted":false,"internal":false},{"id":"internal","name":"Internal","hidden":false,"deleted":false,"internal":true}]}"""))
            val value = YNABClient("synthetic", baseURL = server.url("/v1/").toString()).snapshot("plan", "2026-10-01")
            assertEquals(120_000L, value.readyToAssign); assertTrue(value.categories[0].eligible); assertFalse(value.categories[1].eligible)
        }
    }
    @Test fun redirectsFailuresAndLostResponsesNeverRetryPatch() = runBlocking {
        for (response in listOf(MockResponse().setResponseCode(307).setHeader("Location", "/elsewhere"), MockResponse().setResponseCode(503).setHeader("Retry-After", "0"), MockResponse().setResponseCode(408), MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AFTER_REQUEST))) {
            MockWebServer().use { server ->
                server.enqueue(response)
                server.enqueue(MockResponse().setResponseCode(500))
                val api = YNABClient("synthetic", baseURL = server.url("/v1/").toString())
                assertTrue(runCatching { api.assign("plan", "2026-10-01", "food", 1000) }.isFailure)
                assertNotNull(server.takeRequest(2, TimeUnit.SECONDS)); assertNull(server.takeRequest(100, TimeUnit.MILLISECONDS))
                assertEquals(1, server.requestCount)
            }
        }
    }
    @Test fun rateLimitAndPathValidationBlockUnsafeRequests() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(response("""{"plans":[{"id":"plan","name":"Test","currency_format":{"iso_code":"USD","decimal_digits":2}}]}""").setHeader("X-Rate-Limit", "199/200"))
            val api = YNABClient("synthetic", baseURL = server.url("/v1/").toString())
            assertEquals(2, api.plans()[0].digits); assertTrue(runCatching { api.checkWriteCapacity(1) }.isFailure)
            assertTrue(runCatching { api.assign("../other", "2026-10-01", "food", 1000) }.isFailure); assertEquals(1, server.requestCount)
        }
    }
}
