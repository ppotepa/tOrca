package org.torchat.mobile

import android.app.Activity
import android.app.ActivityManager
import android.content.Intent
import android.os.Handler
import android.util.Log

internal object ProfileReset {
    fun clear(activity: Activity, handler: Handler) {
        handler.postDelayed({
            runCatching {
                activity.stopService(Intent(activity, TorChatForegroundService::class.java))
                val manager = activity.getSystemService(ActivityManager::class.java)
                check(manager.clearApplicationUserData()) {
                    "Android refused to clear Torca application data"
                }
            }.onFailure { error ->
                Log.e("Torca-Reset", "Unable to clear Torca application data", error)
            }
        }, 250L)
    }
}
