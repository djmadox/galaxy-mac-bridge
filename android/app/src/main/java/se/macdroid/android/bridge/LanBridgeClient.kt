package se.macdroid.android.bridge

import android.content.Context
import android.content.Intent
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.Uri
import android.util.Base64
import android.provider.OpenableColumns
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import org.json.JSONObject
import se.macdroid.android.calls.CallStateRelay
import se.macdroid.android.files.FileTransferReceiver
import se.macdroid.android.sms.SmsRepository
import se.macdroid.android.notifications.NotificationActionRegistry
import se.macdroid.android.notifications.NotificationRelayService
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.security.SecureRandom
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

class LanBridgeClient(context: Context) {
    private val context = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val nsd = context.getSystemService(NsdManager::class.java)
    private val identityStore = IdentityStore(context)
    private val identity = identityStore.loadOrCreate()
    private val fileReceiver = FileTransferReceiver(context)
    private val connecting = AtomicBoolean(false)
    private var socket: Socket? = null
    private var output: DataOutputStream? = null
    private var sessionKey: ByteArray? = null
    private var localConfirmed = false
    private var remoteConfirmed = false
    private var connected = false
    private var sendSequence = 0L
    private var receivedSequence = 0L
    private var remoteName: String? = null
    private var remoteOffer: PairingOfferData? = null
    private var outboxJob: Job? = null
    private var reconnectJob: Job? = null
    private var fileTransferJob: Job? = null
    @Volatile private var currentOutgoingTransferId: String? = null
    @Volatile private var remoteTransferError: String? = null
    private var expectedOutgoingCompletions = 0
    private var outgoingCompletions = 0
    private var lastService: NsdServiceInfo? = null

    private val discovery = object : NsdManager.DiscoveryListener {
        override fun onDiscoveryStarted(serviceType: String) {
            BridgeRuntime.update(BridgeUiState(status = "Söker efter Mac…"))
        }

        override fun onServiceFound(service: NsdServiceInfo) {
            lastService = service
            resolveAndConnect(service)
        }

        override fun onServiceLost(service: NsdServiceInfo) {
            if (lastService?.serviceName == service.serviceName && socket == null) {
                lastService = null
            }
        }
        override fun onDiscoveryStopped(serviceType: String) = Unit
        override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
            connecting.set(false)
            BridgeRuntime.update(BridgeUiState(status = "Nätverkssökning misslyckades ($errorCode)"))
        }
        override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
    }

    private fun resolveAndConnect(service: NsdServiceInfo) {
        if (!connecting.compareAndSet(false, true)) return
        runCatching {
            @Suppress("DEPRECATION")
            nsd.resolveService(service, object : NsdManager.ResolveListener {
                override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                    connecting.set(false)
                    scheduleReconnect()
                }

                override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                    scope.launch { connect(serviceInfo) }
                }
            })
        }.onFailure {
            connecting.set(false)
            scheduleReconnect()
        }
    }

    fun start() {
        BridgeRuntime.attach(this)
        nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discovery)
    }

    fun stop() {
        fileTransferJob?.cancel()
        runCatching { nsd.stopServiceDiscovery(discovery) }
        runCatching { socket?.close() }
        fileReceiver.abortAll()
        reconnectJob?.cancel()
        BridgeRuntime.detach(this)
        BridgeRuntime.update(BridgeUiState(status = "Stoppad"))
        scope.cancel()
    }

    fun confirmPairing() {
        scope.launch {
            if (sessionKey == null) return@launch
            localConfirmed = true
            sendPacket(JSONObject().put("type", "confirmation").put("confirmed", true))
            finishPairingIfReady()
        }
    }

    fun sendFiles(uris: List<Uri>) {
        if (uris.isEmpty() || fileTransferJob?.isActive == true) return
        fileTransferJob = scope.launch {
            var activeId: String? = null
            try {
                check(connected) { "Anslut Macen innan du skickar." }
                val files = uris.map(::readFileMetadata)
                require(files.isNotEmpty()) { "Inga filer valdes." }
                var totalBytes = 0L
                files.forEach { file ->
                    require(file.size in 0..MAX_FILE_BYTES) { "${file.name} är större än 10 GB." }
                    require(totalBytes <= MAX_TRANSFER_BYTES - file.size) { "Överföringen är större än 20 GB." }
                    totalBytes += file.size
                }

                expectedOutgoingCompletions = files.size
                outgoingCompletions = 0
                remoteTransferError = null
                var allBytesSent = 0L
                val progressTotal = maxOf(totalBytes, 1L)
                BridgeRuntime.updateFileTransfer("Förbereder säker överföring…", 0f, true)

                files.forEach { file ->
                    ensureActive()
                    val transferId = UUID.randomUUID().toString()
                    activeId = transferId
                    currentOutgoingTransferId = transferId
                    sendRequiredBridge(
                        "fileTransferStart",
                        JSONObject()
                            .put("transferId", transferId)
                            .put("fileName", file.name)
                            .put("size", file.size)
                            .put("mimeType", file.mimeType)
                    )

                    val digest = MessageDigest.getInstance("SHA-256")
                    var offset = 0L
                    val input = context.contentResolver.openInputStream(file.uri)
                        ?: error("${file.name} kunde inte öppnas.")
                    input.use { stream ->
                        val buffer = ByteArray(FILE_CHUNK_BYTES)
                        while (true) {
                            ensureActive()
                            val count = stream.read(buffer)
                            if (count < 0) break
                            if (count == 0) continue
                            require(offset + count <= file.size) { "Filen ändrades under överföringen." }
                            digest.update(buffer, 0, count)
                            sendRequiredBridge(
                                "fileTransferChunk",
                                JSONObject()
                                    .put("transferId", transferId)
                                    .put("offset", offset)
                                    .put("data", Base64.encodeToString(buffer, 0, count, Base64.NO_WRAP))
                            )
                            offset += count
                            allBytesSent += count
                            BridgeRuntime.updateFileTransfer(
                                "Skickar ${file.name}…",
                                allBytesSent.toFloat() / progressTotal.toFloat(),
                                true
                            )
                        }
                    }
                    require(offset == file.size) { "Filen ändrades under överföringen." }
                    sendRequiredBridge(
                        "fileTransferComplete",
                        JSONObject()
                            .put("transferId", transferId)
                            .put("sha256", digest.digest().toHex())
                    )
                    activeId = null
                    currentOutgoingTransferId = null
                }
                BridgeRuntime.updateFileTransfer("Verifierar filerna på Macen…", 1f, true)
            } catch (error: CancellationException) {
                activeId?.let(::sendCancelIfConnected)
                val remoteError = remoteTransferError
                BridgeRuntime.updateFileTransfer(
                    remoteError ?: "Filöverföringen avbröts.",
                    BridgeRuntime.state.value.fileTransferProgress,
                    false
                )
                throw error
            } catch (error: Exception) {
                activeId?.let(::sendCancelIfConnected)
                BridgeRuntime.updateFileTransfer(
                    error.message ?: "Filöverföringen misslyckades.",
                    BridgeRuntime.state.value.fileTransferProgress,
                    false
                )
            } finally {
                currentOutgoingTransferId = null
                remoteTransferError = null
                fileTransferJob = null
            }
        }
    }

    fun cancelOutgoingFileTransfer() {
        fileTransferJob?.cancel()
    }

    private fun connect(service: NsdServiceInfo) {
        try {
            resetSession()
            val address = service.host ?: error("Missing host")
            val newSocket = Socket().apply {
                tcpNoDelay = true
                soTimeout = HANDSHAKE_TIMEOUT_MS
                connect(InetSocketAddress(address, service.port), 8_000)
            }
            socket = newSocket
            output = DataOutputStream(BufferedOutputStream(newSocket.getOutputStream()))
            val input = DataInputStream(BufferedInputStream(newSocket.getInputStream()))
            val localOffer = PairingOfferData(
                version = 1,
                deviceId = identity.deviceId.toString().lowercase(),
                // Avoid exposing the user's device model before authentication.
                deviceName = "Galaxy",
                publicKey = identity.rawPublicKey,
                nonce = ByteArray(32).also(SecureRandom()::nextBytes)
            )
            sendPacket(JSONObject().put("type", "offer").put("offer", localOffer.json()))

            while (!newSocket.isClosed) {
                val length = input.readInt()
                require(length in 1..MAX_FRAME_SIZE)
                val bytes = ByteArray(length)
                input.readFully(bytes)
                handle(JSONObject(String(bytes, Charsets.UTF_8)), localOffer)
            }
        } catch (_: Exception) {
            disconnect("Anslutningen bröts")
        }
    }

    private fun handle(packet: JSONObject, localOffer: PairingOfferData) {
        when (packet.getString("type")) {
            "offer" -> {
                require(remoteOffer == null && !connected)
                val remote = PairingOfferData.from(packet.getJSONObject("offer"))
                val derived = BridgeCrypto.derive(identity, localOffer, remote)
                sessionKey = derived.key
                remoteName = remote.deviceName
                remoteOffer = remote
                if (identityStore.isTrusted(remote)) {
                    localConfirmed = true
                    sendPacket(JSONObject().put("type", "confirmation").put("confirmed", true))
                    finishPairingIfReady()
                } else {
                    BridgeRuntime.update(
                        BridgeUiState(
                            status = "Bekräfta koden på båda enheterna",
                            macName = remote.deviceName,
                            pairingCode = derived.code
                        )
                    )
                }
            }
            "confirmation" -> {
                if (sessionKey == null || !packet.optBoolean("confirmed")) error("Invalid confirmation")
                remoteConfirmed = true
                finishPairingIfReady()
            }
            "envelope" -> handleEnvelope(packet.getJSONObject("envelope"))
            "error" -> Unit
            else -> error("Unsupported packet type")
        }
    }

    private fun finishPairingIfReady() {
        if (!localConfirmed || !remoteConfirmed || connected) return
        remoteOffer?.let(identityStore::trust)
        connected = true
        socket?.soTimeout = 0
        BridgeRuntime.update(
            BridgeUiState(status = "Ansluten och krypterad", macName = remoteName, connected = true)
        )
        outboxJob = scope.launch {
            BridgeOutbox.events.collect { event ->
                sendBridge(event.getString("kind"), event.getJSONObject("payload"))
            }
        }
        scope.launch {
            delay(100)
            NotificationRelayService.publishActiveMessagingNotifications()
            CallStateRelay.publishCurrentState()
        }
    }

    private fun handleEnvelope(envelope: JSONObject) {
        check(connected)
        val sequence = envelope.getLong("sequence")
        require(sequence > receivedSequence)
        val cleartext = BridgeCrypto.open(
            sessionKey ?: error("Missing key"),
            sequence,
            Base64.decode(envelope.getString("ciphertext"), Base64.DEFAULT)
        )
        val message = JSONObject(String(cleartext, Charsets.UTF_8))
        require(message.getInt("version") == 1)
        require(message.getLong("sequence") == sequence)
        receivedSequence = sequence
        val payload = JSONObject(
            String(Base64.decode(message.getString("payload"), Base64.DEFAULT), Charsets.UTF_8)
        )
        when (message.getString("kind")) {
            "smsSyncRequest" -> {
                runCatching { SmsRepository(context).all() }
                    .onSuccess(::sendSMSSnapshot)
                    .onFailure {
                        sendPacket(JSONObject().put("type", "error").put("error", "sms_read_failed"))
                    }
            }
            "smsSend" -> {
                val clientId = payload.getString("clientMessageId")
                val result = runCatching {
                    SmsRepository(context).send(payload.getString("address"), payload.getString("body"))
                }
                sendBridge(
                    "smsStatus",
                    JSONObject()
                        .put("clientMessageId", clientId)
                        .put("state", if (result.isSuccess) "sent" else "failed")
                )
            }
            "notificationAction" -> {
                val success = NotificationActionRegistry.reply(
                    context,
                    payload.getString("notificationId"),
                    payload.getString("actionId"),
                    payload.getString("text")
                )
                if (!success) {
                    sendPacket(JSONObject().put("type", "error").put("error", "notification_action_failed"))
                }
            }
            "callStart" -> {
                val address = BridgeInputValidation.normalizedPhoneAddress(payload.getString("address"))
                val intent = Intent(Intent.ACTION_CALL, Uri.fromParts("tel", address, null))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(intent)
            }
            "fileTransferStart" -> fileReceiver.start(payload)
            "fileTransferChunk" -> fileReceiver.append(payload)
            "fileTransferComplete" -> fileReceiver.complete(payload)
            "fileTransferCancel" -> fileReceiver.cancel(payload)
            "fileTransferStatus" -> handleFileTransferStatus(payload)
            "ping" -> sendBridge("pong", JSONObject())
            else -> error("Unsupported message kind")
        }
    }

    private fun handleFileTransferStatus(payload: JSONObject) {
        val state = payload.getString("state")
        val total = payload.optLong("totalBytes", 0).coerceAtLeast(1)
        val received = payload.optLong("bytesReceived", 0).coerceAtLeast(0)
        when (state) {
            "accepted", "progress" -> Unit
            "completed" -> {
                outgoingCompletions += 1
                if (outgoingCompletions >= expectedOutgoingCompletions) {
                    BridgeRuntime.updateFileTransfer(
                        if (expectedOutgoingCompletions == 1) {
                            "Filen är sparad i Hämtade filer/MacDroid på Macen."
                        } else {
                            "Alla filer är sparade i Hämtade filer/MacDroid på Macen."
                        },
                        1f,
                        false
                    )
                }
            }
            "cancelled", "failed" -> {
                remoteTransferError = payload.optString("error")
                    .takeIf { it.isNotBlank() && it != "null" }
                    ?: if (state == "cancelled") "Filöverföringen avbröts." else "Macen avvisade filen."
                BridgeRuntime.updateFileTransfer(
                    remoteTransferError!!,
                    received.toFloat() / total.toFloat(),
                    false
                )
                fileTransferJob?.cancel(CancellationException("remote_transfer_failed"))
            }
            else -> error("Unsupported file status")
        }
    }

    private fun sendSMSSnapshot(messages: org.json.JSONArray) {
        if (messages.length() == 0) {
            sendBridge(
                "smsSnapshot",
                JSONObject()
                    .put("messages", org.json.JSONArray())
                    .put("reset", true)
                    .put("complete", true)
            )
            return
        }

        var offset = 0
        while (offset < messages.length()) {
            val end = minOf(offset + SMS_CHUNK_SIZE, messages.length())
            val chunk = org.json.JSONArray()
            for (index in offset until end) chunk.put(messages.get(index))
            sendBridge(
                "smsSnapshot",
                JSONObject()
                    .put("messages", chunk)
                    .put("reset", offset == 0)
                    .put("complete", end == messages.length())
            )
            offset = end
        }
    }

    @Synchronized
    private fun sendRequiredBridge(kind: String, payload: JSONObject) {
        check(connected && output != null) { "Anslutningen till Macen bröts." }
        sendBridge(kind, payload)
    }

    private fun sendCancelIfConnected(transferId: String) {
        runCatching {
            sendRequiredBridge(
                "fileTransferCancel",
                JSONObject().put("transferId", transferId)
            )
        }
    }

    @Synchronized
    private fun sendBridge(kind: String, payload: JSONObject) {
        if (!connected) return
        sendSequence += 1
        val message = JSONObject()
            .put("version", 1)
            .put("id", UUID.randomUUID().toString())
            .put("sequence", sendSequence)
            .put("sentAt", System.currentTimeMillis())
            .put("kind", kind)
            .put("payload", Base64.encodeToString(payload.toString().toByteArray(), Base64.NO_WRAP))
        val ciphertext = BridgeCrypto.seal(
            sessionKey ?: error("Missing key"),
            sendSequence,
            message.toString().toByteArray()
        )
        sendPacket(
            JSONObject()
                .put("type", "envelope")
                .put(
                    "envelope",
                    JSONObject()
                        .put("sequence", sendSequence)
                        .put("ciphertext", Base64.encodeToString(ciphertext, Base64.NO_WRAP))
                )
        )
    }

    @Synchronized
    private fun sendPacket(packet: JSONObject) {
        val bytes = packet.toString().toByteArray(Charsets.UTF_8)
        require(bytes.size <= MAX_FRAME_SIZE)
        output?.apply {
            writeInt(bytes.size)
            write(bytes)
            flush()
        }
    }

    private fun disconnect(message: String) {
        fileTransferJob?.cancel()
        resetSession()
        fileReceiver.abortAll()
        outboxJob?.cancel()
        output = null
        runCatching { socket?.close() }
        socket = null
        connecting.set(false)
        BridgeRuntime.update(BridgeUiState(status = message))
        scheduleReconnect()
    }

    private fun scheduleReconnect() {
        val service = lastService ?: return
        reconnectJob?.cancel()
        reconnectJob = scope.launch {
            delay(2_000)
            resolveAndConnect(service)
        }
    }

    private fun resetSession() {
        connected = false
        sessionKey?.fill(0)
        sessionKey = null
        localConfirmed = false
        remoteConfirmed = false
        sendSequence = 0L
        receivedSequence = 0L
        remoteName = null
        remoteOffer = null
    }

    private fun readFileMetadata(uri: Uri): OutgoingFile {
        var name: String? = null
        var size = -1L
        context.contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
            null,
            null,
            null
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (nameIndex >= 0 && !cursor.isNull(nameIndex)) name = cursor.getString(nameIndex)
                if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) size = cursor.getLong(sizeIndex)
            }
        }
        if (size < 0) {
            size = context.contentResolver.openAssetFileDescriptor(uri, "r")?.use { descriptor ->
                descriptor.length.takeIf { it >= 0 }
                    ?: descriptor.parcelFileDescriptor.statSize
            } ?: -1
        }
        require(size >= 0) { "Filens storlek kunde inte läsas." }
        val safeName = (name ?: "fil")
            .map { if (it.isISOControl() || it == '/' || it == '\\') '_' else it }
            .joinToString("")
            .trim()
            .take(MAX_FILE_NAME_CHARS)
            .takeIf { it.isNotBlank() && it !in setOf(".", "..") }
            ?: error("Ogiltigt filnamn.")
        val mime = context.contentResolver.getType(uri)
            ?.takeIf { it.length <= MAX_MIME_CHARS && MIME_PATTERN.matches(it) }
            ?: "application/octet-stream"
        return OutgoingFile(uri, safeName, size, mime)
    }

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

    private data class OutgoingFile(
        val uri: Uri,
        val name: String,
        val size: Long,
        val mimeType: String
    )

    private companion object {
        const val SERVICE_TYPE = "_macdroid._tcp."
        const val MAX_FRAME_SIZE = 4 * 1024 * 1024
        const val SMS_CHUNK_SIZE = 100
        const val HANDSHAKE_TIMEOUT_MS = 20_000
        const val FILE_CHUNK_BYTES = 256 * 1_024
        const val MAX_FILE_NAME_CHARS = 180
        const val MAX_MIME_CHARS = 128
        const val MAX_FILE_BYTES = 10L * 1_024 * 1_024 * 1_024
        const val MAX_TRANSFER_BYTES = 20L * 1_024 * 1_024 * 1_024
        val MIME_PATTERN = Regex("^[a-zA-Z0-9][a-zA-Z0-9.+-]*/[a-zA-Z0-9][a-zA-Z0-9.+-]*$")
    }
}
