package org.torchat.mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.media.AudioAttributes
import android.app.Service
import android.content.Intent
import android.content.Context
import android.os.IBinder
import android.util.Base64
import android.util.Log
import androidx.core.app.NotificationCompat
import org.json.JSONObject
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.torchat.security.LocalSecretStore
import org.torchat.security.TorRuntime
import org.torchat.core.NativeIdentity
import org.torchat.generated.EngineContract
import java.io.File

/** Owns Tor, engine lifecycle and notifications outside the Flutter UI. */
class TorChatForegroundService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var runtime: TorRuntime? = null
    private var engineHost: AndroidEngineHost? = null
    private var engineEventPump: AndroidEngineEventPump? = null
    @Volatile private var starting = false
    private val pendingTorStatuses = ArrayDeque<JSONObject>()

    override fun onCreate() {
        super.onCreate()
        // A service can be stopped and started again in the same process. Do not
        // let a completed deferred from the previous runtime make the new UI
        // skip the bootstrap step.
        if (activeEngineHost == null && ready.isCompleted) {
            ready = kotlinx.coroutines.CompletableDeferred()
        }
        if (localReady.isCompleted) localReady = kotlinx.coroutines.CompletableDeferred()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, notification("Uruchamianie Torâ€¦"))
        publish(
            mapOf(
                EngineContract.TYPE to EngineContract.TOR_STATUS,
                "phase" to "starting",
                "label" to "Uruchamianie usÅ‚ugi Tor",
                "detail" to "Przygotowywanie lokalnego procesu Tor",
                "progress" to 0,
                "retryAttempt" to 0,
            ),
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (runtime == null && !starting) {
            starting = true
            scope.launch {
                runCatching {
                    val tor = TorRuntime(applicationContext).also { runtime = it }
                    val config = withContext(Dispatchers.IO) {
                        tor.prepare()
                        tor.start { progress, summary ->
                            // Native Tor reaching 100% completes the first
                            // phase, not the whole application connection.
                            val snapshot = torStatusSnapshot(
                                phase = if (progress >= 100) "connecting" else "bootstrapping",
                                label = if (progress >= 100) {
                                    "Tor gotowy Â· Å‚Ä…czenie z relayem"
                                } else {
                                    "Tor bootstrap: $progress%"
                                },
                                detail = summary,
                                progress = (progress * 70 / 100).coerceIn(0, 70),
                            )
                            pendingTorStatuses.add(snapshot)
                            publishTorStatusFact(snapshot)
                            updateNotification("Tor bootstrap: $progress%")
                        }
                    }
                    val secrets = LocalSecretStore(applicationContext)
                    val databasePassphrase = secrets.databasePassphrase()
                    val identitySeed = if (BuildConfig.DEBUG && BuildConfig.TORCHAT_DEV_IDENTITY_KEY.isNotBlank()) {
                        Base64.decode(
                            BuildConfig.TORCHAT_DEV_IDENTITY_KEY,
                            Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
                        )
                    } else {
                        secrets.identityPrivateKey()
                    }
                    val socks5Url = "socks5://127.0.0.1:${config.socksPort}"
                    val host = AndroidEngineHost.create(
                        AndroidEngineHost.Config(
                            databasePath = File(applicationContext.noBackupFilesDir, "torchat-client-v1.db"),
                            databaseKey = databasePassphrase,
                            identityPrivateKey = identitySeed,
                            relayOnionUrl = BuildConfig.TORCHAT_SERVER_URL,
                            initialSocks5Url = socks5Url,
                            logDirectory = File(applicationContext.noBackupFilesDir, "engine-logs"),
                        ),
                    )
                    host.start()
                    engineHost = host
                    activeEngineHost = host
                    engineEventPump = AndroidEngineEventPump(
                        host = host,
                        scope = scope,
                        onEvent = ::handleEngineEvent,
                        onFailure = { error ->
                            Log.w("TorChat-Engine", "Engine event pump stopped", error)
                        },
                    ).also { it.start() }
                    runCatching {
                        host.submitCommandAndAwait(JSONObject().put("type", "bootstrap"))
                    }.onFailure { error ->
                        Log.w("TorChat-Engine", "Engine bootstrap command failed", error)
                    }
                    publishEngineFact(engineAppVisibilityChangedFactJson(foreground = true))
                    publishEngineFact(engineTorEndpointAvailableFactJson(socks5Url))
                    pendingTorStatuses.forEach(::publishTorStatusFact)
                    val loadedIdentity = NativeIdentity.fromPrivateKey(identitySeed)
                    activeIdentity = loadedIdentity
                    val localNickname = if (BuildConfig.DEBUG && BuildConfig.TORCHAT_DEV_PROFILE.isNotBlank()) {
                        BuildConfig.TORCHAT_DEV_PROFILE
                    } else {
                        secrets.nickname().orEmpty()
                    }
                    activeProfile = runtimeProfileResponse(loadedIdentity, localNickname)
                    localReady.complete(Unit)
                    publishProfileReady(activeProfile!!)
                    Log.i("TorChat-Runtime", "Foreground service runtime initialized nickname=$localNickname connected=false")
                    host.submitCommandAndAwait(JSONObject().put("type", "connect"))
                    config
                }.onSuccess {
                    starting = false
                    updateNotification("TorChat uruchomiony")
                }.onFailure { error ->
                    starting = false
                    Log.e("TorChat-Runtime", "Mobile runtime initialization failed", error)
                    // Reset the native service before retrying. The SOCKS
                    // listener can remain bound after a failed bootstrap on
                    // some OEM builds, so a simple Activity retry is unsafe.
                    runtime?.stop()
                    runtime = null
                    val failedReady = ready
                    failedReady.completeExceptionally(error)
                    ready = kotlinx.coroutines.CompletableDeferred()
                    localReady.completeExceptionally(error)
                    publish(
                        mapOf(
                            EngineContract.TYPE to EngineContract.RUNTIME_ERROR,
                            "message" to (error.message ?: "TorChat runtime failed"),
                        ),
                    )
                    updateNotification("BÅ‚Ä…d TorChat")
                    stopSelf(startId)
                }
            }
        }
        // This runtime is the owner of the Tor circuit and the delivery
        // queues. Ask Android to recreate it after a process reclaim; it
        // still cannot survive an explicit force-stop, which is an Android
        // platform guarantee no app may bypass.
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        publishEngineFact(engineAppVisibilityChangedFactJson(foreground = false))
        publishEngineFact(engineTorEndpointLostFactJson("TorChat service stopped"))
        runCatching { engineHost?.close() }
            .onFailure { error -> Log.w("TorChat-Engine", "Engine shutdown failed", error) }
        runtime?.release()
        runtime = null
        engineEventPump = null
        engineHost = null
        starting = false
        activeEngineHost = null
        activeIdentity = null
        activeProfile = null
        if (!ready.isCompleted) {
            ready.completeExceptionally(IllegalStateException("TorChat service stopped"))
        }
        scope.cancel()
        super.onDestroy()
    }

    private fun publish(event: Map<String, Any?>) {
        if (event[EngineContract.TYPE] == EngineContract.TOR_STATUS) {
            lastTorStatus = event
        }
        when (event[EngineContract.TYPE]) {
            EngineContract.INVITE_RECEIVED,
            EngineContract.MESSAGE_RECEIVED -> {
                val kind = when (event[EngineContract.TYPE]) {
                    EngineContract.INVITE_RECEIVED -> "invite"
                    else -> "message"
                }
                val payload = event["payload"]?.toString()
                notifyIncoming(this, kind, payload)
            }
        }
        eventListener?.invoke(event)
    }

    private fun publishEngineFact(fact: JSONObject) {
        runCatching { engineHost?.publishPlatformFact(fact) }
            .onFailure { error -> Log.w("TorChat-Engine", "Unable to publish engine fact ${fact.optString("type")}", error) }
    }

    private fun publishProfileReady(profile: org.torchat.transport.ProfileResponse) {
        publish(
            mapOf(
                EngineContract.TYPE to EngineContract.PROFILE_READY,
                "profile" to profile.toRuntimeMap(),
            ),
        )
    }

    private fun publishTorStatusFact(status: JSONObject) {
        publishEngineFact(
            engineTorStatusFactJson(
                phase = status.optString("phase").ifBlank { "failed" },
                progress = status.optInt("progress", 0).coerceIn(0, 100),
                detail = status.optString("detail").ifBlank { status.optString("label", "Tor status update") },
            ),
        )
    }

    private fun handleEngineEvent(event: JSONObject) {
        val publishedEvents = mapEngineEventToPublishedEvents(event)
        publishedEvents.forEach(::publish)
        when (event.optString("type")) {
            "connection" -> {
                val status = publishedEvents.firstOrNull()
                when (status?.get("phase")?.toString().orEmpty()) {
                    "connected" -> {
                        if (!ready.isCompleted) {
                            ready.complete(Unit)
                        }
                        updateNotification("TorChat dziaÅ‚a przez Tor")
                    }
                    "reconnecting" -> updateNotification("Ponowne Å‚Ä…czenie z relay...")
                    "connecting" -> updateNotification("Å\u0081Ä…czenie z relay...")
                }
            }
            "log" -> {
                val message = event.optString("message")
                Log.i("TorChat-Engine", message.ifBlank { event.toString() })
            }
            "fatal" -> {
                val message = event.optString("message").ifNullOrBlank { "Client engine failed" }
                Log.e("TorChat-Engine", message)
                if (!ready.isCompleted) {
                    ready.completeExceptionally(IllegalStateException(message))
                }
            }
            "notification_requested" -> {
                val notification = event.optJSONObject("notificationRequested")
                    ?: event.optJSONObject("notification_requested")
                    ?: event
                postAlert(
                    title = notification.optString("title").ifBlank { "TorChat" },
                    text = notification.optString("body").ifBlank { "Nowe zdarzenie" },
                    id = notification.optString("id").hashCode(),
                )
            }
        }
    }

    private fun torStatusSnapshot(
        phase: String,
        label: String,
        detail: String = label,
        progress: Int? = null,
        latencyMs: Long? = null,
        retryAttempt: Int = 0,
    ) = JSONObject()
        .put("phase", phase)
        .put("label", label)
        .put("detail", detail)
        .put("progress", progress)
        .put("latencyMs", latencyMs)
        .put("retryAttempt", retryAttempt)

    private fun updateNotification(text: String) {
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification(text))
    }

    private fun notification(text: String): Notification = NotificationCompat.Builder(this, CHANNEL_ID)
        .setSmallIcon(R.drawable.ic_stat_tor)
        .setContentTitle("TorChat")
        .setContentText(text)
        .setOngoing(true)
        .setContentIntent(PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
        .build()

    private fun createNotificationChannel() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "TorChat connection", NotificationManager.IMPORTANCE_LOW),
        )
        manager.createNotificationChannel(
            NotificationChannel(ALERT_CHANNEL_ID, "TorChat messages", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Nowe wiadomoÅ›ci i zaproszenia"
                enableVibration(true)
                setSound(
                    android.provider.Settings.System.DEFAULT_NOTIFICATION_URI,
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                        .build(),
                )
            },
        )
    }

    private fun postAlert(title: String, text: String, id: Int) {
        notifyIncomingNotification(
            context = this,
            title = title,
            text = text,
            notificationId = ALERT_NOTIFICATION_BASE + (id and 0x3fff),
        )
    }

    companion object {
        private const val CHANNEL_ID = "torchat-tor"
        private const val ALERT_CHANNEL_ID = "torchat-alerts"
        private const val NOTIFICATION_ID = 4101
        private const val ALERT_NOTIFICATION_BASE = 5100
        @Volatile private var ready = kotlinx.coroutines.CompletableDeferred<Unit>()
        @Volatile private var localReady = kotlinx.coroutines.CompletableDeferred<Unit>()
        @Volatile var eventListener: ((Map<String, Any?>) -> Unit)? = null
        @Volatile var activeEngineHost: AndroidEngineHost? = null
        @Volatile var activeIdentity: NativeIdentity? = null
        @Volatile var activeProfile: org.torchat.transport.ProfileResponse? = null
        @Volatile var lastTorStatus: Map<String, Any?>? = null

        fun notifyIncoming(context: Context, kind: String?, payload: String?) {
            val title = when (kind) {
                "invite" -> "Nowe zaproszenie"
                else -> "Nowa wiadomoÅ›Ä‡"
            }
            val text = when {
                !payload.isNullOrBlank() -> payload
                kind == "invite" -> "Masz nowÄ… proÅ›bÄ™ o rozmowÄ™."
                else -> "Masz nowÄ… wiadomoÅ›Ä‡."
            }
            notifyIncomingNotification(
                context = context,
                title = title,
                text = text,
                notificationId = ALERT_NOTIFICATION_BASE + ((payload?.hashCode() ?: title.hashCode()) and 0x3fff),
            )
        }

        private fun notifyIncomingNotification(
            context: Context,
            title: String,
            text: String,
            notificationId: Int,
        ) {
            ensureIncomingNotificationChannel(context)
            val notification = NotificationCompat.Builder(context, ALERT_CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_tor)
                .setContentTitle(title)
                .setContentText(text.take(120))
                .setStyle(NotificationCompat.BigTextStyle().bigText(text.take(400)))
                .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setDefaults(Notification.DEFAULT_SOUND or Notification.DEFAULT_VIBRATE)
                .setAutoCancel(true)
                .setContentIntent(
                    PendingIntent.getActivity(
                        context,
                        notificationId,
                        Intent(context, MainActivity::class.java),
                        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                    ),
                )
                .build()
            context.getSystemService(NotificationManager::class.java)
                .notify(notificationId, notification)
        }

        private fun ensureIncomingNotificationChannel(context: Context) {
            val manager = context.getSystemService(NotificationManager::class.java)
            if (manager.getNotificationChannel(ALERT_CHANNEL_ID) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        ALERT_CHANNEL_ID,
                        "TorChat messages",
                        NotificationManager.IMPORTANCE_HIGH,
                    ).apply {
                        description = "Nowe wiadomoÅ›ci i zaproszenia"
                        enableVibration(true)
                        setSound(
                            android.provider.Settings.System.DEFAULT_NOTIFICATION_URI,
                            AudioAttributes.Builder()
                                .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                                .build(),
                        )
                    },
                )
            }
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID,
                        "TorChat connection",
                        NotificationManager.IMPORTANCE_LOW,
                    ),
                )
            }
        }

        /**
         * A cold v3 onion circuit can take several minutes. The foreground
         * service owns that wait and continuously publishes progress to the UI;
         * timing out here only starts a duplicate Flutter connection cycle.
         */
        suspend fun awaitReady() = ready.await()
        suspend fun awaitLocalReady() = withTimeout(30_000L) { localReady.await() }
    }
}

private fun String?.ifNullOrBlank(fallback: () -> String): String =
    if (this.isNullOrBlank()) fallback() else this

