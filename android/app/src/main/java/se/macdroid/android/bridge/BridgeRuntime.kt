package se.macdroid.android.bridge

import android.annotation.SuppressLint
import android.net.Uri
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

data class BridgeUiState(
    val status: String = "Frånkopplad",
    val macName: String? = null,
    val pairingCode: String? = null,
    val connected: Boolean = false,
    val fileTransferStatus: String = "",
    val fileTransferProgress: Float = 0f,
    val isTransferringFiles: Boolean = false
)

object BridgeRuntime {
    private val mutableState = MutableStateFlow(BridgeUiState())
    val state = mutableState.asStateFlow()

    // LanBridgeClient retains only applicationContext; lint cannot infer that here.
    @SuppressLint("StaticFieldLeak") @Volatile
    private var client: LanBridgeClient? = null

    fun attach(client: LanBridgeClient) {
        this.client = client
    }

    fun update(value: BridgeUiState) {
        val old = mutableState.value
        mutableState.value = value.copy(
            fileTransferStatus = old.fileTransferStatus,
            fileTransferProgress = old.fileTransferProgress,
            isTransferringFiles = old.isTransferringFiles
        )
    }

    fun updateFileTransfer(status: String, progress: Float, active: Boolean) {
        mutableState.value = mutableState.value.copy(
            fileTransferStatus = status,
            fileTransferProgress = progress.coerceIn(0f, 1f),
            isTransferringFiles = active
        )
    }

    fun confirmPairing() {
        client?.confirmPairing()
    }

    fun sendFiles(uris: List<Uri>) {
        client?.sendFiles(uris)
    }

    fun cancelFileTransfer() {
        client?.cancelOutgoingFileTransfer()
    }

    fun detach(client: LanBridgeClient) {
        if (this.client === client) this.client = null
    }
}
