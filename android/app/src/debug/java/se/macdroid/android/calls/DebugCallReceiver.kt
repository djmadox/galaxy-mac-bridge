package se.macdroid.android.calls

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class DebugCallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        CallStateRelay.simulateState(intent.getStringExtra("state") ?: "idle")
    }
}
