package org.torchat.data

import android.content.Context
import android.util.Base64
import org.json.JSONObject

/** Debug-only MLS snapshots. Release builds intentionally return no fixtures. */
object DevFixtures {
    fun load(context: Context): Map<String, ByteArray> {
        if (!org.torchat.mobile.BuildConfig.DEBUG) return emptyMap()
        return runCatching {
            val json = context.assets.open("dev-fixtures/android-peer.json")
                .bufferedReader().use { JSONObject(it.readText()) }
            mapOf("android-peer" to Base64.decode(
                json.getString("android_snapshot"),
                Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
            ))
        }.getOrDefault(emptyMap())
    }
}
