package se.macdroid.android.bridge

import android.util.Base64
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

data class PairingOfferData(
    val version: Int,
    val deviceId: String,
    val deviceName: String,
    val publicKey: ByteArray,
    val nonce: ByteArray
) {
    fun json(): JSONObject = JSONObject()
        .put("version", version)
        .put("deviceId", deviceId)
        .put("deviceName", deviceName)
        .put("publicKey", Base64.encodeToString(publicKey, Base64.NO_WRAP))
        .put("nonce", Base64.encodeToString(nonce, Base64.NO_WRAP))
        .put("serviceType", "_macdroid._tcp")

    companion object {
        fun from(json: JSONObject): PairingOfferData {
            val offer = PairingOfferData(
                version = json.getInt("version"),
                deviceId = json.getString("deviceId").lowercase(),
                deviceName = json.getString("deviceName"),
                publicKey = Base64.decode(json.getString("publicKey"), Base64.DEFAULT),
                nonce = Base64.decode(json.getString("nonce"), Base64.DEFAULT)
            )
            require(offer.version == 1)
            require(json.getString("serviceType") == "_macdroid._tcp")
            require(runCatching { java.util.UUID.fromString(offer.deviceId) }.isSuccess)
            require(offer.deviceName.toByteArray(Charsets.UTF_8).size in 1..128)
            require(offer.publicKey.size == 32 && offer.nonce.size == 32)
            return offer
        }
    }
}

data class SessionKeys(val key: ByteArray, val code: String)

object BridgeCrypto {
    private val x25519Prefix = byteArrayOf(
        0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x03, 0x21, 0x00
    )

    fun derive(identity: BridgeIdentity, local: PairingOfferData, remote: PairingOfferData): SessionKeys {
        require(local.deviceId != remote.deviceId)
        require(local.publicKey.size == 32 && remote.publicKey.size == 32)
        require(local.nonce.size == 32 && remote.nonce.size == 32)
        require(remote.publicKey.size == 32)
        val publicKey = KeyFactory.getInstance("XDH").generatePublic(
            X509EncodedKeySpec(x25519Prefix + remote.publicKey)
        )
        val agreement = KeyAgreement.getInstance("XDH")
        agreement.init(identity.keyPair.private)
        agreement.doPhase(publicKey, true)
        val shared = agreement.generateSecret()
        val transcript = transcript(local, remote)
        val salt = MessageDigest.getInstance("SHA-256").digest(transcript)
        val sessionKey = hkdf(shared, salt, "macdroid/session/v1".toByteArray(), 32)
        val authentication = hmac(sessionKey, transcript)
        val value = ByteBuffer.wrap(authentication.copyOfRange(0, 4)).int.toLong() and 0xffffffffL
        return SessionKeys(sessionKey, "%06d".format(value % 1_000_000))
    }

    fun seal(key: ByteArray, sequence: Long, cleartext: ByteArray): ByteArray {
        val nonce = ByteArray(12).also(SecureRandom()::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        cipher.updateAAD(ByteBuffer.allocate(8).putLong(sequence).array())
        return nonce + cipher.doFinal(cleartext)
    }

    fun open(key: ByteArray, sequence: Long, combined: ByteArray): ByteArray {
        require(combined.size >= 28)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            SecretKeySpec(key, "AES"),
            GCMParameterSpec(128, combined.copyOfRange(0, 12))
        )
        cipher.updateAAD(ByteBuffer.allocate(8).putLong(sequence).array())
        return cipher.doFinal(combined.copyOfRange(12, combined.size))
    }

    private fun transcript(first: PairingOfferData, second: PairingOfferData): ByteArray {
        val offers = listOf(first, second).sortedBy { it.deviceId.lowercase() }
        val output = java.io.ByteArrayOutputStream()
        output.write("macdroid/pairing/v1".toByteArray(StandardCharsets.UTF_8))
        offers.forEach {
            output.write(it.deviceId.lowercase().toByteArray(StandardCharsets.UTF_8))
            output.write(it.publicKey)
            output.write(it.nonce)
        }
        return output.toByteArray()
    }

    private fun hkdf(input: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val pseudoRandomKey = hmac(salt, input)
        val output = java.io.ByteArrayOutputStream()
        var previous = ByteArray(0)
        var counter = 1
        while (output.size() < length) {
            previous = hmac(pseudoRandomKey, previous + info + byteArrayOf(counter.toByte()))
            output.write(previous)
            counter += 1
        }
        return output.toByteArray().copyOf(length)
    }

    private fun hmac(key: ByteArray, value: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(value)
    }
}
