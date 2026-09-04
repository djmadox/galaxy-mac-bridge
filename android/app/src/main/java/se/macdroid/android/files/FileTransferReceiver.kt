package se.macdroid.android.files

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import android.util.Base64
import org.json.JSONObject
import se.macdroid.android.bridge.BridgeOutbox
import java.io.File
import java.io.OutputStream
import java.security.MessageDigest

class FileTransferReceiver(context: Context) {
    private val resolver = context.applicationContext.contentResolver
    private val active = mutableMapOf<String, Transfer>()

    @Synchronized
    fun start(payload: JSONObject) {
        val id = payload.getString("transferId")
        runCatching {
            require(id !in active) { "Överföringen finns redan." }
            require(runCatching { java.util.UUID.fromString(id) }.isSuccess) { "Ogiltigt överförings-ID." }
            require(active.size < MAX_ACTIVE_TRANSFERS) { "För många samtidiga överföringar." }
            val rawName = payload.getString("fileName")
            val safeName = File(rawName).name
                .map { if (it.isISOControl() || it == '/' || it == '\\') '_' else it }
                .joinToString("")
                .take(MAX_FILE_NAME_CHARS)
                .takeIf { it.isNotBlank() && it !in setOf(".", "..") }
                ?: error("Ogiltigt filnamn.")
            val size = payload.getLong("size")
            require(size in 0..MAX_FILE_BYTES) { "Ogiltig filstorlek." }
            val requestedMime = payload.optString("mimeType", "application/octet-stream")
            val mimeType = requestedMime.takeIf {
                it.length <= MAX_MIME_CHARS && MIME_PATTERN.matches(it)
            } ?: "application/octet-stream"

            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, safeName)
                put(MediaStore.Downloads.MIME_TYPE, mimeType)
                put(
                    MediaStore.Downloads.RELATIVE_PATH,
                    Environment.DIRECTORY_DOWNLOADS + "/MacDroid"
                )
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: error("Telefonen kunde inte skapa filen.")
            val output = resolver.openOutputStream(uri, "w")
                ?: run {
                    resolver.delete(uri, null, null)
                    error("Telefonen kunde inte öppna filen.")
                }
            active[id] = Transfer(uri, output, size)
            publish(id, "accepted", 0, size)
        }.onFailure { error ->
            publish(id, "failed", 0, payload.optLong("size", 0), error.userMessage())
        }
    }

    @Synchronized
    fun append(payload: JSONObject) {
        val id = payload.getString("transferId")
        val transfer = active[id]
        if (transfer == null) {
            publish(id, "failed", 0, 0, "Överföringen startades inte korrekt.")
            return
        }

        runCatching {
            val offset = payload.getLong("offset")
            require(offset == transfer.received) { "Fel ordning på fildata." }
            val data = Base64.decode(payload.getString("data"), Base64.DEFAULT)
            require(data.isNotEmpty() && data.size <= MAX_CHUNK_BYTES) { "Ogiltig delstorlek." }
            require(transfer.received + data.size <= transfer.expectedSize) {
                "Filen är större än utlovat."
            }
            transfer.output.write(data)
            transfer.digest.update(data)
            transfer.received += data.size
            publish(id, "progress", transfer.received, transfer.expectedSize)
        }.onFailure { fail(id, transfer, it.userMessage()) }
    }

    @Synchronized
    fun complete(payload: JSONObject) {
        val id = payload.getString("transferId")
        val transfer = active[id]
        if (transfer == null) {
            publish(id, "failed", 0, 0, "Överföringen saknas.")
            return
        }

        runCatching {
            transfer.output.flush()
            transfer.output.close()
            require(transfer.received == transfer.expectedSize) { "Filen blev inte komplett." }
            val expectedHash = payload.getString("sha256").lowercase()
            require(SHA256_PATTERN.matches(expectedHash)) { "Ogiltig kontrollsumma." }
            val actualHash = transfer.digest.digest().toHex()
            require(expectedHash == actualHash) { "Filens kontrollsumma stämmer inte." }

            val values = ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }
            require(resolver.update(transfer.uri, values, null, null) == 1) {
                "Filen kunde inte göras synlig."
            }
            active.remove(id)
            publish(id, "completed", transfer.received, transfer.expectedSize)
        }.onFailure { fail(id, transfer, it.userMessage()) }
    }

    @Synchronized
    fun cancel(payload: JSONObject) {
        val id = payload.getString("transferId")
        val transfer = active.remove(id) ?: return
        runCatching { transfer.output.close() }
        runCatching { resolver.delete(transfer.uri, null, null) }
        publish(
            id,
            "cancelled",
            transfer.received,
            transfer.expectedSize,
            "Överföringen avbröts."
        )
    }

    @Synchronized
    fun abortAll() {
        active.values.forEach { transfer ->
            runCatching { transfer.output.close() }
            runCatching { resolver.delete(transfer.uri, null, null) }
        }
        active.clear()
    }

    private fun fail(id: String, transfer: Transfer, message: String) {
        active.remove(id)
        runCatching { transfer.output.close() }
        runCatching { resolver.delete(transfer.uri, null, null) }
        publish(id, "failed", transfer.received, transfer.expectedSize, message)
    }

    private fun publish(
        id: String,
        state: String,
        received: Long,
        total: Long,
        error: String? = null
    ) {
        BridgeOutbox.publish(
            "fileTransferStatus",
            JSONObject()
                .put("transferId", id)
                .put("state", state)
                .put("bytesReceived", received)
                .put("totalBytes", total)
                .put("error", error ?: JSONObject.NULL)
        )
    }

    private data class Transfer(
        val uri: Uri,
        val output: OutputStream,
        val expectedSize: Long,
        val digest: MessageDigest = MessageDigest.getInstance("SHA-256"),
        var received: Long = 0
    )

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

    private fun Throwable.userMessage(): String = message ?: "Filöverföringen misslyckades."

    private companion object {
        const val MAX_ACTIVE_TRANSFERS = 4
        const val MAX_CHUNK_BYTES = 256 * 1_024
        const val MAX_FILE_NAME_CHARS = 180
        const val MAX_MIME_CHARS = 128
        const val MAX_FILE_BYTES = 10L * 1_024 * 1_024 * 1_024
        val MIME_PATTERN = Regex("^[a-zA-Z0-9][a-zA-Z0-9.+-]*/[a-zA-Z0-9][a-zA-Z0-9.+-]*$")
        val SHA256_PATTERN = Regex("^[0-9a-f]{64}$")
    }
}
