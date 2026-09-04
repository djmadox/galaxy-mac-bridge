package se.macdroid.android.sms

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.provider.Telephony
import android.telephony.SmsManager
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject
import se.macdroid.android.bridge.BridgeInputValidation

class SmsRepository(private val context: Context) {
    fun all(): JSONArray {
        checkPermission(Manifest.permission.READ_SMS)
        val result = JSONArray()
        val projection = arrayOf(
            Telephony.Sms._ID,
            Telephony.Sms.THREAD_ID,
            Telephony.Sms.ADDRESS,
            Telephony.Sms.BODY,
            Telephony.Sms.DATE,
            Telephony.Sms.TYPE
        )
        context.contentResolver.query(
            Telephony.Sms.CONTENT_URI,
            projection,
            null,
            null,
            "${Telephony.Sms.DATE} DESC"
        )?.use { cursor ->
            while (cursor.moveToNext() && result.length() < MAX_MESSAGES) {
                result.put(
                    JSONObject()
                        .put("id", cursor.getString(0))
                        .put("threadId", cursor.getString(1))
                        .put("address", cursor.getString(2).orEmpty())
                        .put("contactName", JSONObject.NULL)
                        .put("body", cursor.getString(3).orEmpty().take(MAX_TEXT_CHARS))
                        .put("timestamp", cursor.getLong(4))
                        .put(
                            "direction",
                            if (cursor.getInt(5) == Telephony.Sms.MESSAGE_TYPE_INBOX) "incoming" else "outgoing"
                        )
                        .put("deliveryState", "delivered")
                )
            }
        }
        return result
    }

    fun send(address: String, body: String) {
        checkPermission(Manifest.permission.SEND_SMS)
        val normalized = BridgeInputValidation.normalizedPhoneAddress(address)
        BridgeInputValidation.requireMessageText(body)
        val manager = context.getSystemService(SmsManager::class.java)
        val parts = manager.divideMessage(body)
        if (parts.size == 1) manager.sendTextMessage(normalized, null, body, null, null)
        else manager.sendMultipartTextMessage(normalized, null, parts, null, null)
    }

    private fun checkPermission(permission: String) {
        check(ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED) {
            "Permission not granted: $permission"
        }
    }

    private companion object {
        const val MAX_MESSAGES = 50_000
        const val MAX_TEXT_CHARS = 16_384
    }
}
