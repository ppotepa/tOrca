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
import kotlin.coroutines.coroutineContext
import org.torchat.chat.ChatController
import org.torchat.data.DevContacts
import org.torchat.data.DevFixtures
import org.torchat.data.EncryptedMessageStore
import org.torchat.security.LocalSecretStore
import org.torchat.security.TorRuntime
import org.torchat.core.NativeIdentity
import org.torchat.transport.classifyRelayFailure
import kotlin.random.Random

/** Owns Tor, relay, MLS receive loop and notifications outside the Flutter UI. */
class TorChatForegroundService : Service() {
    private enum class RelayPhase {
        DISCONNECTED,
        CONNECTING,
        AUTHENTICATING,
        WAITING_FOR_READY,
        CONNECTED,
        BACKOFF,
        STOPPED,
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var runtime: TorRuntime? = null
    @Volatile private var starting = false
    private val pendingTorStatuses = ArrayDeque<JSONObject>()

    override fun onCreate() {
        super.onCreate()
        // A service can be stopped and started again in the same process. Do not
        // let a completed deferred from the previous runtime make the new UI
        // skip the bootstrap step.
        if (activeController == null && ready.isCompleted) {
            ready = kotlinx.coroutines.CompletableDeferred()
        }
        if (localReady.isCompleted) localReady = kotlinx.coroutines.CompletableDeferred()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, notification("Uruchamianie Torâ€¦"))
        publish(
            mapOf(
                RuntimeContract.TYPE to RuntimeContract.TOR_STATUS,
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
                            val appProgress = (progress * 70 / 100).coerceIn(0, 70)
                            pendingTorStatuses.add(
                                torStatusSnapshot(
                                    phase = if (progress >= 100) "connecting" else "bootstrapping",
                                    label = if (progress >= 100) {
                                        "Tor gotowy Â· Å‚Ä…czenie z relayem"
                                    } else {
                                        "Tor bootstrap: $progress%"
                                    },
                                    detail = summary,
                                    progress = appProgress,
                                ),
                            )
                            updateNotification("Tor bootstrap: $progress%")
                        }
                    }
                    val secrets = LocalSecretStore(applicationContext)
                    val store = EncryptedMessageStore(applicationContext, secrets.databasePassphrase())
                    val identitySeed = if (BuildConfig.DEBUG && BuildConfig.TORCHAT_DEV_IDENTITY_KEY.isNotBlank()) {
                        Base64.decode(
                            BuildConfig.TORCHAT_DEV_IDENTITY_KEY,
                            Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
                        )
                    } else {
                        secrets.identityPrivateKey()
                    }
                    val loadedIdentity = NativeIdentity.fromPrivateKey(identitySeed)
                    store.mlsInbox()?.let { saved ->
                        runCatching { loadedIdentity.restoreMls(saved) }
                    }
                    val relay = org.torchat.transport.AndroidRelayTransport(BuildConfig.TORCHAT_SERVER_URL, config.socksPort, loadedIdentity)
                    val controller = ChatController(
                        loadedIdentity,
                        store,
                        relay,
                        if (BuildConfig.TORCHAT_DEV_PAIR) DevFixtures.load(applicationContext) else emptyMap(),
                        if (BuildConfig.DEBUG && BuildConfig.TORCHAT_DEV_PROFILE.isNotBlank()) {
                            BuildConfig.TORCHAT_DEV_PROFILE
                        } else {
                            secrets.nickname().orEmpty()
                        },
                    )
                    activeController = controller
                    activeIdentity = loadedIdentity
                    val localNickname = if (BuildConfig.DEBUG && BuildConfig.TORCHAT_DEV_PROFILE.isNotBlank()) {
                        BuildConfig.TORCHAT_DEV_PROFILE
                    } else {
                        secrets.nickname().orEmpty()
                    }
                    activeProfile = runtimeProfileResponse(loadedIdentity, localNickname)
                    localReady.complete(Unit)
                    controller.reportBootstrapRuntime()
                    while (pendingTorStatuses.isNotEmpty()) {
                        controller.reportTorStatus(pendingTorStatuses.removeFirst())
                    }
                    controller.applyRemoteProfile(activeProfile!!)
                    controller.publishLocalRuntimeEvents()
                    Log.i("TorChat-Runtime", "Foreground service runtime initialized nickname=$localNickname connected=false")
                    if (BuildConfig.DEBUG && BuildConfig.TORCHAT_DEV_PAIR) {
                        // The foreground service owns the receive loop. Seed
                        // the debug conversation here as well as the contact,
                        // before the relay can deliver an application frame.
                        // Opening Bob from Flutter then only selects local
                        // state and never starts another Tor connection.
                        DevContacts.seed(applicationContext).forEach { contact ->
                            controller.addContact(contact)
                            runCatching {
                                controller.startDevConversation(contact)
                            }.onFailure { error ->
                                Log.w("TorChat-Runtime", "Unable to seed dev conversation", error)
                            }
                        }
                    }
                    val (profile, onionLatencyMs, retryAttempt) =
                        connectRelayActor(controller, retryAttempt = 0, reconnectDetail = null)
                            ?: error("TorChat service stopped before the onion relay connected")
                    activeProfile = profile
                    controller.applyRemoteProfile(profile)
                    ready.complete(Unit)
                    controller.reportTorStatus(
                        phase = "connected",
                        label = "PoÅ‚Ä…czono z relayem przez Tor",
                        detail = "PoÅ‚Ä…czono z relayem przez Tor",
                        progress = 100,
                        latencyMs = onionLatencyMs,
                        retryAttempt = retryAttempt,
                    )
                    controller.publishLocalRuntimeEvents()
                    scope.launch {
                        while (isActive) {
                            delay(20_000)
                            runCatching { controller.syncPairingInbox() }
                                .onSuccess { incoming ->
                                    Log.i("TorChat-Pairing", "pairing inbox sync ok count=${incoming.size}")
                                    controller.publishLocalRuntimeEvents()
                                }
                                .onFailure { error -> Log.w("TorChat-Pairing", "Pairing inbox refresh failed", error) }
                            runCatching {
                                controller.retryDueMessages()
                                controller.retryDueReceipts()
                                controller.resendPendingWelcomes()
                                controller.publishLocalRuntimeEvents()
                            }.onFailure { error ->
                                Log.w("TorChat-Runtime", "Client queue retry failed", error)
                            }
                        }
                    }
                    scope.launch {
                        var retryAttempt = 0
                        while (isActive) {
                            val disconnected = runCatching {
                                controller.receiveLoop(onText = { text ->
                                    controller.publishLocalRuntimeEvents()
                                }, onWelcome = {
                                    controller.publishLocalRuntimeEvents()
                                }, onStateChanged = {
                                    controller.publishLocalRuntimeEvents()
                                })
                            }.exceptionOrNull() ?: continue

                            connectRelayActor(
                                controller,
                                disconnected.message ?: "Relay rozÅ‚Ä…czony",
                                retryAttempt = retryAttempt,
                            )?.let { latencyMs ->
                                retryAttempt = 0
                                controller.reportTorStatus(
                                    phase = "connected",
                                    label = "PoÅ‚Ä…czono z relayem przez Tor",
                                    detail = "PoÅ‚Ä…czono z relayem przez Tor",
                                    progress = 100,
                                    latencyMs = latencyMs,
                                    retryAttempt = 0,
                                )
                                controller.publishLocalRuntimeEvents()
                                updateNotification("TorChat dziaÅ‚a przez Tor")
                            } ?: break
                        }
                    }
                    config
                }.onSuccess {
                    starting = false
                    updateNotification("TorChat dziaÅ‚a przez Tor")
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
                    activeController?.let { controller ->
                        controller.reportRuntimeError(error.message ?: "TorChat runtime failed")
                        controller.publishLocalRuntimeEvents()
                    }
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
        runCatching { activeController?.close() }
            .onFailure { error -> Log.w("TorChat-Runtime", "Runtime shutdown failed", error) }
        runtime?.release()
        runtime = null
        starting = false
        activeController = null
        activeIdentity = null
        activeProfile = null
        if (!ready.isCompleted) {
            ready.completeExceptionally(IllegalStateException("TorChat service stopped"))
        }
        scope.cancel()
        super.onDestroy()
    }

    private fun publish(event: Map<String, Any?>) {
        if (event[RuntimeContract.TYPE] == RuntimeContract.TOR_STATUS) {
            lastTorStatus = event
        }
        when (event[RuntimeContract.TYPE]) {
            RuntimeContract.INVITE_RECEIVED,
            RuntimeContract.MESSAGE_RECEIVED -> {
                val kind = when (event[RuntimeContract.TYPE]) {
                    RuntimeContract.INVITE_RECEIVED -> "invite"
                    else -> "message"
                }
                val payload = event["payload"]?.toString()
                notifyIncoming(this, kind, payload)
            }
        }
        eventListener?.invoke(event)
    }

    private fun ChatController.publishLocalRuntimeEvents() {
        drainLocalRuntimeEvents().forEach(::publish)
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

    private data class RelayBootstrapResult(
        val profile: org.torchat.transport.ProfileResponse,
        val latencyMs: Long?,
        val retryAttempt: Int,
    )
    private suspend fun connectRelayActor(
        controller: ChatController,
        retryAttempt: Int,
        reconnectDetail: String?,
    ): RelayBootstrapResult? {
        var currentAttempt = retryAttempt
        var onionLatencyMs: Long? = null
        while (coroutineContext.isActive) {
            val backoffSeconds = connectionBackoffSeconds(currentAttempt)
            val attemptNumber = currentAttempt + 1
            val phase = if (reconnectDetail == null && currentAttempt == retryAttempt) {
                RelayPhase.CONNECTING
            } else {
                RelayPhase.BACKOFF
            }
            val detail = reconnectDetail
                ?: "Laczenie z usluga onion, proba $attemptNumber"
            controller.reportTorStatus(
                phase = phase.name.lowercase(),
                label = detail,
                detail = detail,
                progress = 80,
                retryAttempt = currentAttempt,
            )
            Log.i(
                "TorChat-Tor",
                "phase=${phase.name.lowercase()} retryAttempt=$currentAttempt nextDelayS=$backoffSeconds detail=$detail",
            )
            controller.publishLocalRuntimeEvents()
            if (reconnectDetail != null || currentAttempt > retryAttempt) {
                updateNotification("Laczenie z relay...")
                delay(backoffSeconds * 1_000)
            }
            val connected = runCatching {
                controller.reportTorStatus(
                    phase = "circuit_building",
                    label = "Budowanie circuitu onion, proba $attemptNumber",
                    detail = "Tor zestawia trase do uslugi onion; pierwsze polaczenie moze potrwac kilka minut",
                    progress = 85,
                    retryAttempt = currentAttempt,
                )
                controller.publishLocalRuntimeEvents()
                updateNotification("Budowanie circuitu onion...")
                onionLatencyMs = controller.warmupRelay()
                controller.reportTorStatus(
                    phase = RelayPhase.AUTHENTICATING.name.lowercase(),
                    label = "Circuit onion gotowy, uwierzytelnianie relaya",
                    detail = "Circuit onion gotowy, uwierzytelnianie relaya",
                    progress = 90,
                    latencyMs = onionLatencyMs,
                    retryAttempt = currentAttempt,
                )
                controller.publishLocalRuntimeEvents()
                if (reconnectDetail == null) {
                    controller.bootstrapRelay()
                    if (
                        BuildConfig.DEBUG &&
                        BuildConfig.TORCHAT_DEV_PAIR &&
                        BuildConfig.TORCHAT_DEV_PROFILE.isNotBlank()
                    ) {
                        controller.updateNickname(BuildConfig.TORCHAT_DEV_PROFILE)
                    }
                }
                controller.reportTorStatus(
                    phase = RelayPhase.WAITING_FOR_READY.name.lowercase(),
                    label = "Handshake WebSocket, oczekiwanie na ready",
                    detail = "Handshake WebSocket, oczekiwanie na ready",
                    progress = 92,
                    latencyMs = onionLatencyMs,
                    retryAttempt = currentAttempt,
                )
                controller.publishLocalRuntimeEvents()
                if (reconnectDetail == null) {
                    controller.connectRelay()
                } else {
                    runCatching { controller.connectRelay() }
                        .getOrElse {
                            controller.bootstrapRelay()
                            controller.connectRelay()
                        }
                }
                controller.syncPairingInbox()
                val profile = runCatching { controller.loadProfile() }.getOrElse {
                    activeProfile ?: throw it
                }
                RelayBootstrapResult(profile, onionLatencyMs, currentAttempt)
            }
            if (connected.isSuccess) {
                val result = connected.getOrThrow()
                Log.i(
                    "TorChat-Tor",
                    "phase=${RelayPhase.CONNECTED.name.lowercase()} retryAttempt=$currentAttempt latencyMs=${result.latencyMs}",
                )
                return result
            }
            val failure = classifyRelayFailure(
                connected.exceptionOrNull() ?: IllegalStateException("unknown relay failure"),
            )
            Log.w(
                "TorChat-Tor",
                "phase=${RelayPhase.BACKOFF.name.lowercase()} retryAttempt=$currentAttempt code=${failure.code} retryable=${failure.retryable} nextDelayS=$backoffSeconds detail=${failure.detail}",
                connected.exceptionOrNull(),
            )
            currentAttempt += 1
        }
        return null
    }

    private suspend fun connectRelayActor(
        controller: ChatController,
        detail: String,
        retryAttempt: Int,
    ): Long? {
        return connectRelayActor(
            controller = controller,
            retryAttempt = retryAttempt,
            reconnectDetail = detail,
        )?.latencyMs
    }

    private fun connectionBackoffSeconds(retryAttempt: Int): Long {
        val base = when (retryAttempt.coerceAtMost(7)) {
            0 -> 1L
            1 -> 2L
            2 -> 4L
            3 -> 8L
            4 -> 15L
            5 -> 30L
            6 -> 60L
            else -> 120L
        }
        val jitterPercent = Random(retryAttempt + 17).nextInt(from = -20, until = 21)
        return (base + base * jitterPercent / 100).coerceAtLeast(1L)
    }

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
        @Volatile var activeController: ChatController? = null
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

