package org.torchat.security

import java.net.URI

object TorTransport {
    fun validateOnionAddress(value: String): Boolean =
        Regex("^[a-z2-7]{56}\\.onion$").matches(value.lowercase())

    fun validateOnionUrl(value: String): Boolean {
        val uri = runCatching { URI(value) }.getOrNull() ?: return false
        return uri.scheme in setOf("http", "https") &&
            uri.host?.let(::validateOnionAddress) == true &&
            uri.userInfo == null && uri.port == -1 &&
            (uri.path.isNullOrEmpty() || uri.path == "/") &&
            uri.query == null && uri.fragment == null
    }
}
