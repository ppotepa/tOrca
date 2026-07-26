package org.torchat.mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.IBinder
import android.util.Base64
import android.util.Log
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.torchat.chat.ChatController
import org.torchat.data.DevContacts
import org.torchat.data.DevFixtures
import org.torchat.data.EncryptedMessageStore
import org.torchat.security.LocalSecretStore
import org.torchat.security.TorRuntime
import org.torchat.core.NativeIdentity

/** Owns Tor, relay, MLS receive loop and notifications outside the Flutter UI. */
class TorChatForegroundService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var runtime: TorRuntime? = null
    @Volatile private var starting = false

    override fun onCreate() {
        super.onCreate()
        // A service can be stopped and started again in the same process. Do not
        // let a completed deferred from the previous runtime make the new UI
        // skip the bootstrap step.
        if (activeController == null && ready.isCompleted) {
            ready = kotlinx.coroutines.CompletableDeferred()
        }
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, notification("Uruchamianie Tor…"))
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
                            publish(mapOf("type" to "tor_status", "phase" to "bootstrapping", "progress" to appProgress, "detail" to summary))
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
                        if (BuildConfig.DEBUG) BuildConfig.TORCHAT_DEV_PROFILE else "Mobile",
                    )
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
                    var initialProfile: org.torchat.transport.ProfileResponse? = null
                    var initialRetrySeconds = 1L
                    var initialAttempt = 1
                    while (initialProfile == null && isActive) {
                        publish(mapOf(
                            "type" to "tor_status",
                            "phase" to "onion_connecting",
                            "progress" to 80,
                            "detail" to "Łączenie z usługą onion · próba $initialAttempt",
                        ))
                        updateNotification("Łączenie z relay przez Tor…")
                        try {
                            initialProfile = withContext(Dispatchers.IO) {
                                controller.bootstrapRelay()
                                if (BuildConfig.DEBUG) {
                                    controller.updateNickname(BuildConfig.TORCHAT_DEV_PROFILE)
                                }
                                controller.connectRelay()
                                controller.loadProfile()
                            }
                        } catch (error: CancellationException) {
                            throw error
                        } catch (error: Throwable) {
                            Log.w(
                                "TorChat-Runtime",
                                "Onion relay connection failed; retrying in ${initialRetrySeconds}s",
                                error,
                            )
                            publish(mapOf(
                                "type" to "tor_status",
                                "phase" to "onion_connecting",
                                "progress" to 80,
                                "detail" to "${error.message ?: "Relay onion chwilowo niedostępny"} · ponawiam za ${initialRetrySeconds}s",
                            ))
                            delay(initialRetrySeconds * 1_000)
                            initialRetrySeconds = (initialRetrySeconds * 2).coerceAtMost(30)
                            initialAttempt += 1
                        }
                    }
                    val profile = checkNotNull(initialProfile) {
                        "TorChat service stopped before the onion relay connected"
                    }
                    activeController = controller
                    activeIdentity = loadedIdentity
                    activeProfile = profile
                    publish(mapOf("type" to "profile_ready", "profile" to profile.toMap(), "identity" to identityInfo()))
                    ready.complete(Unit)
                    scope.launch {
                        var retrySeconds = 1L
                        while (isActive) {
                            val disconnected = runCatching {
                                controller.receiveLoop(onText = { text ->
                                    publish(mapOf("type" to "message_received", "text" to text))
                                    updateNotification("Nowa wiadomość")
                                }, onWelcome = {
                                    publish(mapOf("type" to "chat_state_changed"))
                                }, onStateChanged = {
                                    publish(mapOf("type" to "chat_state_changed"))
                                })
                            }.exceptionOrNull() ?: continue

                            var reconnectDetail = disconnected.message ?: "Relay rozłączony"
                            while (isActive) {
                                publish(mapOf(
                                    "type" to "tor_status",
                                    "phase" to "onion_connecting",
                                    "progress" to 85,
                                    "detail" to reconnectDetail,
                                ))
                                updateNotification("Ponowne łączenie z relay…")
                                delay(retrySeconds * 1_000)
                                val reconnected = runCatching {
                                    controller.bootstrapRelay()
                                    controller.connectRelay()
                                }
                                if (reconnected.isSuccess) {
                                    retrySeconds = 1
                                    publish(mapOf("type" to "tor_status", "phase" to "connected", "progress" to 100))
                                    updateNotification("TorChat działa przez Tor")
                                    break
                                }
                                reconnectDetail = reconnected.exceptionOrNull()?.message ?: "Relay nadal niedostępny"
                                retrySeconds = (retrySeconds * 2).coerceAtMost(30)
                            }
                        }
                    }
                    config
                }.onSuccess { config ->
                    starting = false
                    publish(mapOf("type" to "tor_status", "phase" to "connected", "progress" to 100, "socksPort" to config.socksPort))
                    updateNotification("TorChat działa przez Tor")
                }.onFailure { error ->
                    starting = false
                    Log.e("TorChat-Runtime", "Mobile runtime initialization failed", error)
                    // tor-android can still have native worker threads after
                    // reporting bootstrap=100. Abrupt stopService() here races
                    // those threads and aborts on some OEM builds. Detach and
                    // surface the original error instead.
                    runtime?.release()
                    runtime = null
                    val failedReady = ready
                    failedReady.completeExceptionally(error)
                    ready = kotlinx.coroutines.CompletableDeferred()
                    publish(mapOf("type" to "runtime_error", "message" to (error.message ?: "TorChat runtime failed")))
                    updateNotification("Błąd TorChat")
                    stopSelf(startId)
                }
            }
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
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
        if (event["type"] == "tor_status") {
            lastTorStatus = event
        }
        eventListener?.invoke(event)
    }

    private fun updateNotification(text: String) {
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification(text))
    }

    private fun notification(text: String): Notification = NotificationCompat.Builder(this, CHANNEL_ID)
        .setSmallIcon(android.R.drawable.stat_sys_warning)
        .setContentTitle("TorChat")
        .setContentText(text)
        .setOngoing(true)
        .setContentIntent(PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
        .build()

    private fun createNotificationChannel() {
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "TorChat connection", NotificationManager.IMPORTANCE_LOW),
        )
    }

    companion object {
        private const val CHANNEL_ID = "torchat-tor"
        private const val NOTIFICATION_ID = 4101
        @Volatile private var ready = kotlinx.coroutines.CompletableDeferred<Unit>()
        @Volatile var eventListener: ((Map<String, Any?>) -> Unit)? = null
        @Volatile var activeController: ChatController? = null
        @Volatile var activeIdentity: NativeIdentity? = null
        @Volatile var activeProfile: org.torchat.transport.ProfileResponse? = null
        @Volatile var lastTorStatus: Map<String, Any?>? = null

        suspend fun awaitReady() = ready.await()
        fun identityInfo(): Map<String, Any?>? = activeIdentity?.let {
            val nickname = activeProfile?.nickname
                ?: if (BuildConfig.DEBUG) BuildConfig.TORCHAT_DEV_PROFILE else "Mobile"
            val invite = activeController?.contactInvitePayload() ?: it.contactInvitePayload(nickname)
            mapOf("installationId" to it.installationId(), "fingerprint" to it.fingerprint(), "invite" to invite)
        }
    }
}

private fun org.torchat.transport.ProfileResponse.toMap() = mapOf(
    "installationId" to installationId, "nickname" to nickname,
    "publicKey" to publicKey, "fingerprint" to fingerprint,
)
