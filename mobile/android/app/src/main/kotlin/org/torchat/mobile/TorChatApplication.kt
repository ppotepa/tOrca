package org.torchat.mobile

import android.app.Activity
import android.app.Application
import android.os.Bundle
import android.os.Process
import android.os.SystemClock
import android.util.Log
import java.util.UUID

/** Process-level lifecycle diagnostics independent from Flutter recreation. */
class TorChatApplication : Application(), Application.ActivityLifecycleCallbacks {
    private val processInstanceId = UUID.randomUUID().toString().replace("-", "")
    private val processStartedAt = SystemClock.elapsedRealtime()
    private var startedActivities = 0
    private var resumedActivities = 0

    override fun onCreate() {
        super.onCreate()
        NativeLocaleManager.applyStoredPreference(this)
        AndroidNotificationPolicy.initialize(this)
        registerActivityLifecycleCallbacks(this)
        log("process_created")
    }

    override fun onActivityCreated(activity: Activity, state: Bundle?) =
        log("activity_created", activity, "restored=${state != null}")

    override fun onActivityStarted(activity: Activity) {
        startedActivities += 1
        log("activity_started", activity, "started=$startedActivities")
    }

    override fun onActivityResumed(activity: Activity) {
        resumedActivities += 1
        log("activity_resumed", activity, "resumed=$resumedActivities")
    }

    override fun onActivityPaused(activity: Activity) {
        resumedActivities = (resumedActivities - 1).coerceAtLeast(0)
        log("activity_paused", activity, "resumed=$resumedActivities")
    }

    override fun onActivityStopped(activity: Activity) {
        startedActivities = (startedActivities - 1).coerceAtLeast(0)
        log("activity_stopped", activity, "started=$startedActivities")
    }

    override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) =
        log("activity_state_saved", activity)

    override fun onActivityDestroyed(activity: Activity) =
        log("activity_destroyed", activity, "changingConfig=${activity.isChangingConfigurations}")

    private fun log(event: String, activity: Activity? = null, detail: String = "") {
        val uptimeMs = SystemClock.elapsedRealtime() - processStartedAt
        Log.i(
            "TorChat-Lifecycle",
            listOfNotNull(
                "event=$event",
                "processInstanceId=$processInstanceId",
                "pid=${Process.myPid()}",
                "uptimeMs=$uptimeMs",
                activity?.let { "activity=${it.javaClass.simpleName}" },
                detail.takeIf { it.isNotBlank() },
            ).joinToString(" "),
        )
    }
}
