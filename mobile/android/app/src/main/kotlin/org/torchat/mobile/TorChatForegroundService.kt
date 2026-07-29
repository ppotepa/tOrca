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
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.torchat.security.LocalSecretStore
import org.torchat.security.TorRuntime
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
        startForeground(NOTIFICATION_ID, notification("Uruchamianie Tor…"))
        publish(
            mapOf(
                EngineContract.TYPE to EngineContract.TOR_STATUS,
                EngineContract.PHASE to EngineContract.TRANSPORT_PHASE_STARTING,
                EngineContract.LABEL to "Uruchamianie usługi Tor",
                EngineContract.DETAIL to "Przygotowywanie lokalnego procesu Tor",
                EngineContract.PROGRESS to 0,
                EngineContract.RETRY_ATTEMPT to 0,
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
                                phase = if (progress >= 100) {
                                    EngineContract.TRANSPORT_PHASE_CONNECTING
                                } else {
                                    EngineContract.TRANSPORT_PHASE_BOOTSTRAPPING
                                },
                                label = if (progress >= 100) {
                                    "Tor gotowy · łączenie z relayem"
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
                    publishEngineFact(engineAppVisibilityChangedFactJson(foreground = true))
                    publishEngineFact(engineTorEndpointAvailableFactJson(socks5Url))
                    pendingTorStatuses.forEach(::publishTorStatusFact)

                    val debugNickname = BuildConfig.TORCHAT_DEV_PROFILE
                        .takeIf { BuildConfig.DEBUG }
                        ?.trim()
                        .orEmpty()
                    if (debugNickname.length in 2..32) {
                        host.submitCommandAndAwait(
                            engineCommand(EngineContract.COMMAND_SET_NICKNAME)
                                .put(EngineContract.NICKNAME, debugNickname),
                        )
                    }
                    val profile = host.submitQueryAndAwait(EngineContract.COMMAND_GET_PROFILE)
                    publishProfileReady(profile)
                    localReady.complete(Unit)
                    Log.i(
                        "TorChat-Engine",
                        "Foreground service client engine initialized connected=false",
                    )
                    host.submitCommandAndAwait(engineCommand(EngineContract.COMMAND_CONNECT))
                    config
                }.onSuccess {
                    starting = false
                    updateNotification("TorChat uruchomiony")
                }.onFailure { error ->
                    starting = false
                    Log.e("TorChat-Engine", "Mobile engine initialization failed", error)
                    // Reset the native service before retrying. The SOCKS
                    // listener can remain bound after a failed bootstrap on
                    // some OEM builds, so a simple Activity retry is unsafe.
                    shutdownEngineHost()
                    runtime?.stop()
                    runtime = null
                    val failedReady = ready
                    failedReady.completeExceptionally(error)
                    ready = kotlinx.coroutines.CompletableDeferred()
                    localReady.completeExceptionally(error)
                    publish(
                        mapOf(
                            EngineContract.TYPE to EngineContract.RUNTIME_ERROR,
                            EngineContract.MESSAGE to (error.message ?: "TorChat engine failed"),
                        ),
                    )
                    updateNotification("Błąd TorChat")
                    stopSelf(startId)
                }
            }
        }
        // The client engine is the owner of the Tor circuit and delivery
        // queues. Ask Android to recreate it after a process reclaim; it
        // still cannot survive an explicit force-stop, which is an Android
        // platform guarantee no app may bypass.
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        publishEngineFact(engineAppVisibilityChangedFactJson(foreground = false))
        publishEngineFact(engineTorEndpointLostFactJson("TorChat service stopped"))
        shutdownEngineHost()
        runtime?.release()
        runtime = null
        starting = false
        activeEngineHost = null
        if (!ready.isCompleted) {
            ready.completeExceptionally(IllegalStateException("TorChat service stopped"))
        }
        scope.cancel()
        super.onDestroy()
    }

    private fun shutdownEngineHost() {
        runCatching { runBlocking { engineEventPump?.stop() } }
            .onFailure { error -> Log.w("TorChat-Engine", "Engine event pump shutdown failed", error) }
        engineEventPump = null
        runCatching { engineHost?.close() }
            .onFailure { error -> Log.w("TorChat-Engine", "Engine shutdown failed", error) }
        engineHost = null
        activeEngineHost = null
    }

    private fun publish(event: Map<String, Any?>) {
        if (event[EngineContract.TYPE] == EngineContract.TOR_STATUS) {
            lastTorStatus = event
        }
        eventListener?.invoke(event)
    }

    private fun publishEngineFact(fact: JSONObject) {
        runCatching { engineHost?.publishPlatformFact(fact) }
            .onFailure { error -> Log.w("TorChat-Engine", "Unable to publish engine fact ${fact.optString(EngineContract.TYPE)}", error) }
    }

    private fun publishProfileReady(profile: Any?) {
        val profileMap = profile as? Map<*, *>
            ?: error("Engine profile response is not an object")
        publish(
            mapOf(
                EngineContract.TYPE to EngineContract.PROFILE_READY,
                EngineContract.PROFILE to profileMap.entries.associate { (key, value) ->
                    key.toString() to value
                },
            ),
        )
    }

    private fun publishTorStatusFact(status: JSONObject) {
        val transportPhase = status.optString(EngineContract.PHASE)
            .ifBlank { EngineContract.TRANSPORT_PHASE_ERROR }
        publishEngineFact(
            engineTorStatusFactJson(
                phase = torPhaseForTransportPhase(transportPhase),
                progress = status.optInt(EngineContract.PROGRESS, 0).coerceIn(0, 100),
                detail = status.optString(EngineContract.DETAIL).ifBlank {
                    status.optString(EngineContract.LABEL, "Tor status update")
                },
            ),
        )
    }

    private fun torPhaseForTransportPhase(phase: String): String = when (phase) {
        EngineContract.TRANSPORT_PHASE_STARTING -> EngineContract.TOR_PHASE_STARTING
        EngineContract.TRANSPORT_PHASE_BOOTSTRAPPING -> EngineContract.TOR_PHASE_BOOTSTRAPPING
        EngineContract.TRANSPORT_PHASE_CONNECTING,
        EngineContract.TRANSPORT_PHASE_CONNECTED,
        EngineContract.TRANSPORT_PHASE_DEGRADED,
        EngineContract.TRANSPORT_PHASE_RECONNECTING -> EngineContract.TOR_PHASE_READY
        EngineContract.TRANSPORT_PHASE_OFFLINE,
        EngineContract.TRANSPORT_PHASE_ERROR -> EngineContract.TOR_PHASE_FAILED
        else -> error("Unknown transport phase: $phase")
    }

    private fun handleEngineEvent(event: JSONObject) {
        val publishedEvents = mapEngineEventToPublishedEvents(event)
        publishedEvents.forEach(::publish)
        when (event.optString(EngineContract.TYPE)) {
            EngineContract.EVENT_CONNECTION -> {
                val status = publishedEvents.firstOrNull()
                when (status?.get(EngineContract.PHASE)?.toString().orEmpty()) {
                    EngineContract.TRANSPORT_PHASE_CONNECTED -> {
                        if (!ready.isCompleted) {
                            ready.complete(Unit)
                        }
                        updateNotification("TorChat działa przez Tor")
                    }
                    EngineContract.TRANSPORT_PHASE_RECONNECTING -> updateNotification("Ponowne łączenie z relay...")
                    EngineContract.TRANSPORT_PHASE_CONNECTING -> updateNotification("Łączenie z relay...")
                }
            }
            EngineContract.EVENT_LOG -> {
                val log = event.optJSONObject(EngineContract.LOG)
                val message = log?.optString(EngineContract.MESSAGE).orEmpty()
                Log.i("TorChat-Engine", message.ifBlank { event.toString() })
            }
            EngineContract.EVENT_FATAL -> {
                val error = event.optJSONObject(EngineContract.ERROR)
                val message = error?.optString(EngineContract.MESSAGE)
                    .ifNullOrBlank { "Client engine failed" }
                Log.e("TorChat-Engine", message)
                if (!ready.isCompleted) {
                    ready.completeExceptionally(IllegalStateException(message))
                }
            }
            EngineContract.EVENT_NOTIFICATION_REQUESTED -> {
                val notification = event.optJSONObject(EngineContract.NOTIFICATION) ?: return
                postAlert(
                    title = notification.optString(EngineContract.TITLE).ifBlank { "TorChat" },
                    text = notification.optString(EngineContract.BODY).ifBlank { "Nowe zdarzenie" },
                    id = notification.optString(EngineContract.ID).hashCode(),
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
        .put(EngineContract.PHASE, phase)
        .put(EngineContract.LABEL, label)
        .put(EngineContract.DETAIL, detail)
        .put(EngineContract.PROGRESS, progress)
        .put(EngineContract.LATENCY_MS, latencyMs)
        .put(EngineContract.RETRY_ATTEMPT, retryAttempt)

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
                description = "Nowe wiadomości i zaproszenia"
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
        @Volatile var lastTorStatus: Map<String, Any?>? = null

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
                        description = "Nowe wiadomości i zaproszenia"
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

