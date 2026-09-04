package se.macdroid.android.calls

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject
import se.macdroid.android.bridge.BridgeOutbox

/**
 * Samsung's dialer can render an incoming call without exposing a normal status-bar
 * notification. This relay mirrors only the call state; it never reads a phone number
 * or captures call audio.
 */
class CallStateRelay(context: Context) {
    private val appContext = context.applicationContext
    private val telephony = appContext.getSystemService(TelephonyManager::class.java)
    private var registered = false

    private val callback = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
        override fun onCallStateChanged(state: Int) {
            currentState = state
            publishState(state)
        }
    }

    fun start() {
        if (registered) return
        if (ContextCompat.checkSelfPermission(appContext, Manifest.permission.READ_PHONE_STATE)
            != PackageManager.PERMISSION_GRANTED
        ) return
        runCatching {
            telephony.registerTelephonyCallback(appContext.mainExecutor, callback)
            registered = true
        }
    }

    fun stop() {
        if (!registered) return
        runCatching { telephony.unregisterTelephonyCallback(callback) }
        registered = false
    }

    companion object {
        const val NOTIFICATION_ID = "macdroid:call-state"
        @Volatile private var currentState = TelephonyManager.CALL_STATE_IDLE

        fun publishCurrentState() = publishState(currentState)

        fun simulateState(state: String) {
            currentState = when (state.lowercase()) {
                "ringing" -> TelephonyManager.CALL_STATE_RINGING
                "offhook", "active" -> TelephonyManager.CALL_STATE_OFFHOOK
                else -> TelephonyManager.CALL_STATE_IDLE
            }
            publishState(currentState)
        }

        private fun publishState(state: Int) {
            val text = when (state) {
                TelephonyManager.CALL_STATE_RINGING -> "Inkommande samtal" to "Svara på din Galaxy."
                TelephonyManager.CALL_STATE_OFFHOOK -> "Samtal pågår" to
                    "Samtalsljudet stannar på telefonen."
                else -> {
                    BridgeOutbox.publish(
                        "notificationRemoved",
                        JSONObject().put("id", NOTIFICATION_ID)
                    )
                    return
                }
            }
            BridgeOutbox.publish(
                "notificationPosted",
                JSONObject()
                    .put("id", NOTIFICATION_ID)
                    .put("packageName", "android.telecom")
                    .put("appName", "Telefon")
                    .put("title", text.first)
                    .put("body", text.second)
                    .put("postedAt", System.currentTimeMillis())
                    .put("actions", JSONArray())
                    .put("isSensitive", false)
            )
        }
    }
}
