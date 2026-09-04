package se.macdroid.android.bridge

import org.junit.Assert.assertEquals
import org.junit.Test
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyPair
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.X509EncodedKeySpec
import java.util.UUID

class BridgeCryptoTest {
    @Test
    fun xdhGeneratorCreatesX25519KeyWithoutExplicitParameters() {
        val pair = KeyPairGenerator.getInstance("XDH").generateKeyPair()

        assertEquals(32, pair.public.encoded.takeLast(32).size)
        assertEquals("XDH", pair.public.algorithm)
    }

    @Test
    fun pairingMatchesSwiftRFC7748Vector() {
        val alicePrivate = "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a".hex()
        val alicePublic = "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a".hex()
        val bobPublic = "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f".hex()
        val factory = KeyFactory.getInstance("XDH")
        val identity = BridgeIdentity(
            UUID.fromString("00000000-0000-0000-0000-000000000001"),
            KeyPair(
                factory.generatePublic(X509EncodedKeySpec(X509_PREFIX + alicePublic)),
                factory.generatePrivate(PKCS8EncodedKeySpec(PKCS8_PREFIX + alicePrivate))
            )
        )
        val local = PairingOfferData(
            1,
            identity.deviceId.toString(),
            "Mac",
            alicePublic,
            ByteArray(32) { 1 }
        )
        val remote = PairingOfferData(
            1,
            "00000000-0000-0000-0000-000000000002",
            "Android",
            bobPublic,
            ByteArray(32) { 2 }
        )

        val result = BridgeCrypto.derive(identity, local, remote)
        assertEquals("e517edf35cf302c5f8a69d0de5652fe731818defc825fe62a287b746c3cb07b2", result.key.hexString())
        assertEquals("762753", result.code)
    }

    private fun String.hex(): ByteArray = chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    private fun ByteArray.hexString(): String = joinToString("") { "%02x".format(it) }

    private companion object {
        val X509_PREFIX = "302a300506032b656e032100".hexStatic()
        val PKCS8_PREFIX = "302e020100300506032b656e04220420".hexStatic()

        fun String.hexStatic(): ByteArray = chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    }
}
