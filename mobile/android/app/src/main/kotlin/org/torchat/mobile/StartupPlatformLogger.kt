package org.torchat.mobile

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.util.UUID

internal class StartupPlatformLogger(context: Context) {
    private val directory = File(context.noBackupFilesDir, "engine-logs")
    private val sessionId = UUID.randomUUID().toString()
    private val file: File

    init {
        directory.mkdirs()
        rotate()
        file = File(directory, "platform-${System.currentTimeMillis()}-$sessionId.jsonl")
    }

    @Synchronized
    fun write(
        level: String,
        component: String,
        eventCode: String,
        stage: String?,
        message: String,
        attempt: Int = 0,
    ) {
        runCatching {
            val entry = JSONObject()
                .put("timestampMs", System.currentTimeMillis())
                .put("sessionId", sessionId)
                .put("platform", "android")
                .put("level", level)
                .put("component", component)
                .put("eventCode", eventCode)
                .put("stage", stage ?: JSONObject.NULL)
                .put("attempt", attempt)
                .put("message", redact(message))
            file.appendText(entry.toString() + "\n", Charsets.UTF_8)
        }
    }

    private fun rotate() {
        val cutoff = System.currentTimeMillis() - RETENTION_MS
        directory.listFiles()
            .orEmpty()
            .filter { it.isFile && (it.name.startsWith("platform-") || it.name.startsWith("startup-")) }
            .filter { it.lastModified() < cutoff }
            .forEach { it.delete() }
        val files = directory.listFiles()
            .orEmpty()
            .filter { it.isFile }
            .sortedBy { it.lastModified() }
            .toMutableList()
        var total = files.sumOf { it.length() }
        while (total > LOG_BUDGET_BYTES && files.isNotEmpty()) {
            val oldest = files.removeAt(0)
            val size = oldest.length()
            if (oldest.delete()) total -= size
        }
    }

    private fun redact(message: String): String =
        message.split(Regex("\\s+")).joinToString(" ") { token ->
            if (token.contains(".onion", ignoreCase = true)) "[onion]" else token
        }

    private companion object {
        const val RETENTION_MS = 7L * 24 * 60 * 60 * 1000
        const val LOG_BUDGET_BYTES = 20L * 1024 * 1024
    }
}
