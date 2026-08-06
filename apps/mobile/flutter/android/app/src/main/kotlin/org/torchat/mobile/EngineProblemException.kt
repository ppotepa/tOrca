package org.torchat.mobile

import org.json.JSONArray
import org.json.JSONObject

internal class EngineProblemException(
    val problem: Map<String, Any?>,
    message: String,
) : IllegalStateException(message)

internal fun JSONObject.toEngineProblemMap(): Map<String, Any?> =
    keys().asSequence().associateWith { key ->
        when (val value = opt(key)) {
            null, JSONObject.NULL -> null
            is JSONObject -> value.toEngineProblemMap()
            is JSONArray -> value.toEngineProblemList()
            else -> value
        }
    }

private fun JSONArray.toEngineProblemList(): List<Any?> = List(length()) { index ->
    when (val value = opt(index)) {
        null, JSONObject.NULL -> null
        is JSONObject -> value.toEngineProblemMap()
        is JSONArray -> value.toEngineProblemList()
        else -> value
    }
}
