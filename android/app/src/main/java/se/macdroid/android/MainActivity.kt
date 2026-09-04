package se.macdroid.android

import android.Manifest
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import android.service.notification.NotificationListenerService
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import se.macdroid.android.bridge.BridgeForegroundService
import se.macdroid.android.bridge.BridgeRuntime
import se.macdroid.android.notifications.NotificationRelayService

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                Surface(color = Color(0xFFF8F7FC)) {
                    SetupScreen(
                        openNotificationAccess = {
                            startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                        },
                        startBridge = {
                            NotificationListenerService.requestRebind(
                                ComponentName(this, NotificationRelayService::class.java)
                            )
                            startForegroundService(Intent(this, BridgeForegroundService::class.java))
                        },
                        stopAndExit = {
                            NotificationRelayService.stopRelaying()
                            stopService(Intent(this, BridgeForegroundService::class.java))
                            finishAndRemoveTask()
                        }
                    )
                }
            }
        }
    }
}

@Composable
private fun SetupScreen(
    openNotificationAccess: () -> Unit,
    startBridge: () -> Unit,
    stopAndExit: () -> Unit
) {
    var status by remember { mutableStateOf("Inte parkopplad") }
    val bridgeState by BridgeRuntime.state.collectAsState()
    val notificationPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { }
    val smsPermissions = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { result ->
        status = if (result.values.all { it }) "SMS-behörighet klar" else "SMS-behörighet nekad"
    }
    val callPermissions = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { result ->
        if (result.values.all { it }) startBridge()
    }
    val nearbyPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (granted) startBridge() else status = "Nätverksbehörighet nekad"
    }
    val filePicker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenMultipleDocuments()
    ) { uris ->
        if (uris.isNotEmpty()) BridgeRuntime.sendFiles(uris)
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Text("MacDroid", style = MaterialTheme.typography.headlineLarge)
        Text("Galaxy ↔ Mac, direkt och krypterat", color = Color.Gray)
        SetupCard("1. Parkoppla dator", "Sök efter Macen på ditt lokala nätverk och jämför den sexsiffriga säkerhetskoden.") {
            Button(onClick = {
                nearbyPermission.launch(Manifest.permission.NEARBY_WIFI_DEVICES)
            }) { Text("Sök efter Mac") }
        }
        SetupCard("2. Aviseringar", "Du väljer vilka appar som får speglas till datorn.") {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = openNotificationAccess) { Text("Ge åtkomst") }
                Button(onClick = { notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS) }) {
                    Text("Tillåt status")
                }
            }
        }
        SetupCard("3. SMS", "Används endast för synk och SMS som du skickar från din parkopplade Mac.") {
            Button(onClick = {
                smsPermissions.launch(arrayOf(
                    Manifest.permission.READ_SMS,
                    Manifest.permission.RECEIVE_SMS,
                    Manifest.permission.SEND_SMS
                ))
            }) { Text("Aktivera SMS") }
        }
        SetupCard("4. Samtal", "Mobilnätssamtal kan startas från Mac. Ljudet stannar säkert på telefonen.") {
            Button(onClick = {
                callPermissions.launch(arrayOf(
                    Manifest.permission.READ_PHONE_STATE,
                    Manifest.permission.CALL_PHONE
                ))
            }) { Text("Aktivera samtal") }
        }
        SetupCard("5. Filöverföring", "Skicka filer direkt till Hämtade filer/MacDroid på Macen över den krypterade anslutningen.") {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(
                        onClick = { filePicker.launch(arrayOf("*/*")) },
                        enabled = bridgeState.connected && !bridgeState.isTransferringFiles
                    ) { Text("Välj filer") }
                    if (bridgeState.isTransferringFiles) {
                        OutlinedButton(onClick = BridgeRuntime::cancelFileTransfer) {
                            Text("Avbryt")
                        }
                    }
                }
                if (bridgeState.isTransferringFiles || bridgeState.fileTransferProgress > 0f) {
                    LinearProgressIndicator(
                        progress = { bridgeState.fileTransferProgress },
                        modifier = Modifier.fillMaxWidth()
                    )
                }
                if (bridgeState.fileTransferStatus.isNotEmpty()) {
                    Text(bridgeState.fileTransferStatus, color = Color.Gray)
                }
            }
        }
        SetupCard("Avsluta", "Stoppar anslutningen, filöverföringar och aviseringsspeglingen. Ingenting fortsätter synka i bakgrunden.") {
            OutlinedButton(onClick = stopAndExit, modifier = Modifier.fillMaxWidth()) {
                Text("Stoppa och avsluta")
            }
        }
        if (bridgeState.pairingCode != null) {
            Text("Jämför med Macen", style = MaterialTheme.typography.titleMedium)
            Text(bridgeState.pairingCode!!, style = MaterialTheme.typography.headlineLarge)
            Button(onClick = BridgeRuntime::confirmPairing, modifier = Modifier.fillMaxWidth()) {
                Text("Koderna matchar")
            }
        }
        Text(bridgeState.status, color = if (bridgeState.connected) Color(0xFF16883A) else Color.Gray)
        Text(status, color = Color.Gray)
    }
}

@Composable
private fun SetupCard(title: String, description: String, action: @Composable () -> Unit) {
    Card(
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.cardColors(containerColor = Color.White),
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            Text(description, color = Color.Gray)
            action()
        }
    }
}
