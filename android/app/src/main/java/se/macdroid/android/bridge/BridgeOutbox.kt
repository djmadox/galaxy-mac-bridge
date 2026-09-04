package se.macdroid.android.bridge

import kotlinx.coroutines.flow.MutableSharedFlow
import org.json.JSONObject

/**
 * Single handoff point from Android system integrations to the encrypted transport.
 * The transport consumes this flow, assigns a monotonic sequence and seals each event.
 */
object BridgeOutbox {
    val events = MutableSharedFlow<JSONObject>(extraBufferCapacity = 128)

    fun publish(kind: String, payload: JSONObject) {
        events.tryEmit(JSONObject().put("kind", kind).put("payload", payload))
    }
}
