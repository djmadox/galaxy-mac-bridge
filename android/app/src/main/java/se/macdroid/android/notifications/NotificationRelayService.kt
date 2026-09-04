package se.macdroid.android.notifications

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONArray
import org.json.JSONObject
import se.macdroid.android.bridge.BridgeOutbox

class NotificationRelayService : NotificationListenerService() {
    override fun onCreate() {
        super.onCreate()
        current = this
    }

    override fun onDestroy() {
        if (current === this) current = null
        super.onDestroy()
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        publishActiveMessagingNotifications()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        relay(sbn)
    }

    private fun relay(sbn: StatusBarNotification) {
        if (sbn.packageName == packageName) return
        val extras = sbn.notification.extras
        val isSensitive = sbn.notification.visibility == Notification.VISIBILITY_SECRET
        val actions = JSONArray()
        if (!isSensitive) {
            sbn.notification.actions?.take(MAX_ACTIONS)?.forEachIndexed { index, action ->
                actions.put(
                    JSONObject()
                        .put("id", index.toString())
                        .put("title", safeText(action.title?.toString()))
                        .put("acceptsText", !action.remoteInputs.isNullOrEmpty())
                )
            }
        }
        BridgeOutbox.publish(
            "notificationPosted",
            JSONObject()
                .put("id", sbn.key)
                .put("packageName", sbn.packageName)
                .put("appName", applicationLabel(sbn.packageName))
                .put("title", if (isSensitive) "" else safeText(extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()))
                .put("body", if (isSensitive) "" else safeText(extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()))
                .put("postedAt", sbn.postTime)
                .put("actions", actions)
                .put("isSensitive", isSensitive)
        )
        publishMessagingConversation(sbn)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        NotificationActionRegistry.remove(sbn.key)
        BridgeOutbox.publish("notificationRemoved", JSONObject().put("id", sbn.key))
    }

    private fun publishMessagingConversation(sbn: StatusBarNotification) {
        if (sbn.packageName !in MESSAGING_PACKAGES) return
        if (sbn.notification.visibility == Notification.VISIBILITY_SECRET) return
        val replyActionId = NotificationActionRegistry.update(sbn) ?: return
        val extras = sbn.notification.extras
        val title = safeText(extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)?.toString()
            ?: extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()
            ?: applicationLabel(sbn.packageName))
        val conversationKey = sbn.notification.shortcutId ?: sbn.groupKey ?: title
        val messages = buildList {
            addAll(
                Notification.MessagingStyle.Message.getMessagesFromBundleArray(
                    extras.getParcelableArray(Notification.EXTRA_HISTORIC_MESSAGES)
                )
            )
            addAll(
                Notification.MessagingStyle.Message.getMessagesFromBundleArray(
                    extras.getParcelableArray(Notification.EXTRA_MESSAGES)
                )
            )
        }
        val payload = JSONArray()
        messages.forEach { message ->
            val text = safeText(message.text?.toString())
            if (text.isEmpty()) return@forEach
            val sender = message.senderPerson?.name?.toString()
            payload.put(
                JSONObject()
                    .put("id", "rcs:${sbn.packageName}:${conversationKey}:${message.timestamp}:${text.hashCode()}")
                    .put("threadId", "rcs:${sbn.packageName}:$conversationKey")
                    .put("address", title)
                    .put("contactName", sender ?: title)
                    .put("body", text)
                    .put("timestamp", message.timestamp)
                    .put("direction", if (sender == null) "outgoing" else "incoming")
                    .put("deliveryState", "delivered")
                    .put("transport", "rcs")
                    .put("replyNotificationId", sbn.key)
                    .put("replyActionId", replyActionId)
            )
        }
        if (payload.length() > 0) {
            BridgeOutbox.publish("smsSnapshot", JSONObject().put("messages", payload))
        }
    }

    private fun applicationLabel(packageName: String): String = runCatching {
        val info = packageManager.getApplicationInfo(packageName, 0)
        packageManager.getApplicationLabel(info).toString()
    }.getOrDefault(packageName)

    private fun safeText(value: String?): String = value.orEmpty().take(MAX_TEXT_CHARS)

    companion object {
        @Volatile private var current: NotificationRelayService? = null

        private val MESSAGING_PACKAGES = setOf(
            "com.google.android.apps.messaging",
            "com.samsung.android.messaging"
        )
        private const val MAX_TEXT_CHARS = 16_384
        private const val MAX_ACTIONS = 32

        fun publishActiveMessagingNotifications() {
            val service = current ?: return
            service.activeNotifications.orEmpty().forEach(service::relay)
        }

        fun stopRelaying() {
            current?.requestUnbind()
        }
    }
}
