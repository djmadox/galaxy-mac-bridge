package se.macdroid.android.sms

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import org.json.JSONObject
import se.macdroid.android.bridge.BridgeOutbox

class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        Telephony.Sms.Intents.getMessagesFromIntent(intent).forEach { message ->
            val item = JSONObject()
                    .put("id", "${message.timestampMillis}:${message.originatingAddress}")
                    .put("threadId", message.originatingAddress.orEmpty())
                    .put("address", message.originatingAddress.orEmpty())
                    .put("contactName", JSONObject.NULL)
                    .put("body", message.messageBody.orEmpty())
                    .put("timestamp", message.timestampMillis)
                    .put("direction", "incoming")
                    .put("deliveryState", "delivered")
            BridgeOutbox.publish(
                "smsSnapshot",
                JSONObject().put("messages", org.json.JSONArray().put(item))
            )
        }
    }
}
