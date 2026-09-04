package se.macdroid.android.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class BridgeInputValidationTest {
    @Test
    fun normalizesOrdinaryPhoneNumbers() {
        assertEquals("+15550100100", BridgeInputValidation.normalizedPhoneAddress("+1 (555) 010-0100"))
    }

    @Test
    fun rejectsUssdAndUriInjection() {
        assertThrows(IllegalArgumentException::class.java) {
            BridgeInputValidation.normalizedPhoneAddress("*#06#")
        }
        assertThrows(IllegalArgumentException::class.java) {
            BridgeInputValidation.normalizedPhoneAddress("123;phone-context=evil")
        }
    }

    @Test
    fun rejectsOversizedMessages() {
        assertThrows(IllegalArgumentException::class.java) {
            BridgeInputValidation.requireMessageText("x".repeat(BridgeInputValidation.MAX_MESSAGE_BYTES + 1))
        }
    }
}
