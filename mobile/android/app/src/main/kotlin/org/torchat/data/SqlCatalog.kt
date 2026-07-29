package org.torchat.data

import android.content.Context
import java.util.concurrent.ConcurrentHashMap

/** SQL is packaged as reviewed APK assets, never authored in store code. */
class SqlCatalog(context: Context) {
    private val assets = context.assets
    private val cache = ConcurrentHashMap<String, String>()

    fun get(path: String): String = cache.getOrPut(path) {
        assets.open("sql/$path").bufferedReader(Charsets.UTF_8).use { it.readText() }
    }

    fun statements(path: String): List<String> = get(path)
        .split(';')
        .map(String::trim)
        .filter(String::isNotEmpty)
}
