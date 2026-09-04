package se.macdroid.android.bridge

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.SecureRandom
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.X509EncodedKeySpec
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

data class BridgeIdentity(val deviceId: UUID, val keyPair: KeyPair) {
    val rawPublicKey: ByteArray get() = keyPair.public.encoded.takeLast(32).toByteArray()
}

/** The X25519 private key is encrypted by a non-exportable Android Keystore AES key. */
class IdentityStore(context: Context) {
    private val preferences = context.getSharedPreferences("bridge_identity_v1", Context.MODE_PRIVATE)

    fun loadOrCreate(): BridgeIdentity {
        val storedPrivate = preferences.getString("private", null)
        val storedPublic = preferences.getString("public", null)
        val storedDevice = preferences.getString("device", null)
        if (storedPrivate != null && storedPublic != null && storedDevice != null) {
            runCatching {
                val factory = KeyFactory.getInstance("XDH")
                return BridgeIdentity(
                    UUID.fromString(storedDevice),
                    KeyPair(
                        factory.generatePublic(X509EncodedKeySpec(Base64.decode(storedPublic, Base64.NO_WRAP))),
                        factory.generatePrivate(PKCS8EncodedKeySpec(decrypt(Base64.decode(storedPrivate, Base64.NO_WRAP))))
                    )
                )
            }
        }

        // Android's Conscrypt XDH generator is already fixed to X25519. Some
        // Samsung builds reject every AlgorithmParameterSpec passed to it.
        val pair = KeyPairGenerator.getInstance("XDH").generateKeyPair()
        val identity = BridgeIdentity(UUID.randomUUID(), pair)
        preferences.edit()
            .putString("device", identity.deviceId.toString())
            .putString("public", Base64.encodeToString(pair.public.encoded, Base64.NO_WRAP))
            .putString("private", Base64.encodeToString(encrypt(pair.private.encoded), Base64.NO_WRAP))
            .apply()
        return identity
    }

    fun isTrusted(offer: PairingOfferData): Boolean {
        val trustedDevice = preferences.getString("trusted_device", null) ?: return false
        val trustedKey = preferences.getString("trusted_public", null) ?: return false
        return trustedDevice == offer.deviceId.lowercase() &&
            trustedKey == Base64.encodeToString(offer.publicKey, Base64.NO_WRAP)
    }

    fun trust(offer: PairingOfferData) {
        preferences.edit()
            .putString("trusted_device", offer.deviceId.lowercase())
            .putString("trusted_public", Base64.encodeToString(offer.publicKey, Base64.NO_WRAP))
            .apply()
    }

    private fun wrappingKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return generator.generateKey()
    }

    private fun encrypt(cleartext: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, wrappingKey())
        return cipher.iv + cipher.doFinal(cleartext)
    }

    private fun decrypt(combined: ByteArray): ByteArray {
        require(combined.size > 12)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, wrappingKey(), GCMParameterSpec(128, combined.copyOfRange(0, 12)))
        return cipher.doFinal(combined.copyOfRange(12, combined.size))
    }

    private companion object {
        const val KEY_ALIAS = "macdroid_identity_wrap_v1"
    }
}
