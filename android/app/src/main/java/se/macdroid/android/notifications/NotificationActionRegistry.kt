package se.macdroid.android.notifications

import android.app.Notification
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.service.notification.StatusBarNotification
import se.macdroid.android.bridge.BridgeInputValidation
import java.util.concurrent.ConcurrentHashMap

/** Keeps only active, text-capable notification actions in memory. */
object NotificationActionRegistry {
    private val replies = ConcurrentHashMap<String, Map<String, Notification.Action>>()

    fun update(notification: StatusBarNotification): String? {
        val textActions = notification.notification.actions
            ?.mapIndexedNotNull { index, action ->
                val inputs = action.remoteInputs
                if (inputs.isNullOrEmpty() || inputs.none(RemoteInput::getAllowFreeFormInput)) null
                else index.toString() to action
            }
            ?.toMap()
            .orEmpty()
        if (textActions.isEmpty()) replies.remove(notification.key)
        else replies[notification.key] = textActions
        return textActions.keys.firstOrNull()
    }

    fun remove(notificationId: String) {
        replies.remove(notificationId)
    }

    fun reply(context: Context, notificationId: String, actionId: String, text: String): Boolean {
        if (runCatching { BridgeInputValidation.requireMessageText(text) }.isFailure) return false
        val action = replies[notificationId]?.get(actionId) ?: return false
        val inputs = action.remoteInputs?.filter(RemoteInput::getAllowFreeFormInput)?.toTypedArray()
            ?: return false
        if (inputs.isEmpty()) return false
        val results = Bundle().apply {
            inputs.forEach { putCharSequence(it.resultKey, text) }
        }
        val intent = Intent().addFlags(Intent.FLAG_RECEIVER_FOREGROUND)
        RemoteInput.addResultsToIntent(inputs, intent, results)
        RemoteInput.setResultsSource(intent, RemoteInput.SOURCE_FREE_FORM_INPUT)
        return runCatching {
            action.actionIntent.send(context, 0, intent)
        }.isSuccess
    }
}
