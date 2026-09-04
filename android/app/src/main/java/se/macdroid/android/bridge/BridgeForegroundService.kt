package se.macdroid.android.bridge

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.IBinder
import androidx.core.app.NotificationCompat
import se.macdroid.android.calls.CallStateRelay
import se.macdroid.android.notifications.NotificationRelayService

class BridgeForegroundService : Service() {
    private lateinit var client: LanBridgeClient
    private lateinit var callStateRelay: CallStateRelay

    override fun onCreate() {
        super.onCreate()
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Mac-anslutning", NotificationManager.IMPORTANCE_LOW)
        )
        val stopIntent = Intent(this, BridgeForegroundService::class.java).setAction(ACTION_STOP)
        val stopPendingIntent = PendingIntent.getService(
            this,
            1,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle("MacDroid är ansluten")
            .setContentText("Aviseringar och meddelanden synkas krypterat")
            .addAction(0, "Stoppa", stopPendingIntent)
            .setOngoing(true)
            .build()
        startForeground(NOTIFICATION_ID, notification)

        client = LanBridgeClient(applicationContext)
        client.start()
        callStateRelay = CallStateRelay(applicationContext)
        callStateRelay.start()
    }

    override fun onDestroy() {
        if (::callStateRelay.isInitialized) callStateRelay.stop()
        if (::client.isInitialized) client.stop()
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopCompletely()
            return START_NOT_STICKY
        }
        if (::callStateRelay.isInitialized) callStateRelay.start()
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        stopCompletely()
        super.onTaskRemoved(rootIntent)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun stopCompletely() {
        NotificationRelayService.stopRelaying()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private companion object {
        const val CHANNEL_ID = "mac_bridge"
        const val NOTIFICATION_ID = 1001
        const val ACTION_STOP = "se.macdroid.android.action.STOP"
    }
}
