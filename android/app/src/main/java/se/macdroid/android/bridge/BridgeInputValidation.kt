package se.macdroid.android.bridge

internal object BridgeInputValidation {
    const val MAX_MESSAGE_BYTES = 16 * 1_024

    fun normalizedPhoneAddress(raw: String): String {
        val compact = raw.filterNot { it in " -()." }
        require(Regex("^\\+?[0-9]{1,20}$").matches(compact)) { "Invalid phone address" }
        return compact
    }

    fun requireMessageText(text: String) {
        require(text.isNotBlank() && text.toByteArray(Charsets.UTF_8).size <= MAX_MESSAGE_BYTES) {
            "Invalid message text"
        }
    }
}
