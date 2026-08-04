package org.torchat.mobile

import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.IBinder
import android.os.PowerManager
import android.util.Base64
import android.util.Log
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.torchat.generated.EngineContract
import org.torchat.security.LocalSecretStore
import org.torchat.security.TorRuntime
import java.io.File
import java.util.concurrent.ConcurrentLinkedDeque
import java.util.concurrent.ConcurrentHashMap
import java.util.LinkedHashSet

/** Owns Tor, engine lifecycle and notifications outside the Flutter UI. */
class TorChatForegroundService : Service() {
    private lateinit var startupLogger: StartupPlatformLogger
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var runtime: TorRuntime? = null
    private var secretStore: LocalSecretStore? = null
    private var engineHost: AndroidEngineHost? = null
    private var engineEventPump: AndroidEngineEventPump? = null
    @Volatile private var pendingOnionAction: JSONObject? = null
    @Volatile private var torReadyForOnion = false
    @Volatile private var starting = false
    @Volatile private var torStarting = false
    @Volatile private var networkOnline = false
    private var torRetryJob: Job? = null
    private var runtimeGeneration = 0L
    private val pendingTorStatuses = ArrayDeque<JSONObject>()

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = publishNetworkState()
        override fun onLost(network: Network) = publishNetworkState()
        override fun onCapabilitiesChanged(
            network: Network,
            networkCapabilities: NetworkCapabilities,
        ) = publishNetworkState()
    }
    private val powerModeReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) = publishPowerFacts()
    }

    override fun onCreate() {
        super.onCreate()
        startupLogger = StartupPlatformLogger(applicationContext)
        resetReadinessIfStopped()
        createNotificationChannel()
        getSystemService(ConnectivityManager::class.java)
            .registerDefaultNetworkCallback(networkCallback)
        registerReceiver(
            powerModeReceiver,
            IntentFilter().apply {
                addAction(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
                addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
            },
        )
        publishNetworkState()
        startForeground(NOTIFICATION_ID, notification("Uruchamianie TorChat…"))
        processStarted.complete(Unit)
        startupLogger.write(
            level = "info",
            component = "service",
            eventCode = "process_started",
            stage = "PROCESS_STARTED",
            message = "Foreground service process started",
            state = "ready",
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val deployRunId = intent?.getStringExtra("deploy_run_id")
        val resetDev = BuildConfig.DEBUG &&
            intent?.getBooleanExtra("reset_dev_state", false) == true
        val clean = intent?.getBooleanExtra("clean_state", false) == true
        if ((resetDev || clean) && runtime == null && engineHost == null && !starting) {
            resetLocalState(resetDev = resetDev, clean = clean)
        } else if ((resetDev || clean) && (runtime != null || engineHost != null || starting)) {
            Log.w(
                "TorChat-Engine",
                "Ignoring late client-state reset because the service already owns an active runtime",
            )
        }

        if (engineHost == null && !starting) {
            starting = true
            runtimeGeneration += 1
            startupLogger.updateContext(deployRunId, runtimeGeneration)
            scope.launch { startLocalEngine(startId) }
        } else if (!deployRunId.isNullOrBlank()) {
            startupLogger.updateContext(deployRunId, runtimeGeneration)
        }
        return START_STICKY
    }

    private suspend fun startLocalEngine(startId: Int) {
        val startedAt = System.currentTimeMillis()
        runCatching {
            val secrets = LocalSecretStore(applicationContext).also { secretStore = it }
            val databasePassphrase = secrets.databasePassphrase()
            val identitySeed = if (
                BuildConfig.DEBUG && BuildConfig.TORCHAT_DEV_IDENTITY_KEY.isNotBlank()
            ) {
                Base64.decode(
                    BuildConfig.TORCHAT_DEV_IDENTITY_KEY,
                    Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
                )
            } else {
                secrets.identityPrivateKey()
            }
            val host = AndroidEngineHost.create(
                AndroidEngineHost.Config(
                    databasePath = File(applicationContext.noBackupFilesDir, "torchat-client-v1.db"),
                    databaseKey = databasePassphrase,
                    identityPrivateKey = identitySeed,
                    relayOnionUrl = BuildConfig.TORCHAT_SERVER_URL,
                    initialSocks5Url = null,
                    logDirectory = File(applicationContext.noBackupFilesDir, "engine-logs"),
                    mlsEpochAnchorStore = secrets,
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
            publishPowerFacts()
            publishBackgroundRestrictionFact()
            publishEngineFact(engineNetworkChangedFactJson(networkOnline))

            if (!engineReady.isCompleted) engineReady.complete(Unit)
            startupLogger.write(
                level = "info",
                component = "engine",
                eventCode = "engine_initialized",
                stage = "ENGINE_READY",
                message = "Foreground service client engine initialized",
                state = "ready",
                durationMs = System.currentTimeMillis() - startedAt,
            )
            Log.i(
                "TorChat-Engine",
                "engine_initialized generation=$runtimeGeneration connected=false",
            )

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
            if (!localDataReady.isCompleted) localDataReady.complete(Unit)
            startupLogger.write(
                level = "info",
                component = "storage",
                eventCode = "local_data_ready",
                stage = "LOCAL_DATA_READY",
                message = "Profile, identity and encrypted local database are ready",
                state = "ready",
                durationMs = System.currentTimeMillis() - startedAt,
            )
            host
        }.onSuccess { host ->
            starting = false
            updateNotification("TorChat lokalnie gotowy · uruchamianie Tor")
            scope.launch { startTor(host) }
        }.onFailure { error ->
            starting = false
            Log.e("TorChat-Engine", "Mobile engine initialization failed", error)
            startupLogger.write(
                level = "error",
                component = "engine",
                eventCode = "engine_initialization_failed",
                stage = "ENGINE_READY",
                message = error.stackTraceToString(),
                state = "failed",
                durationMs = System.currentTimeMillis() - startedAt,
                errorCode = error.javaClass.simpleName,
            )
            shutdownEngineHost()
            completeExceptionally(engineReady, error)
            completeExceptionally(localDataReady, error)
            publishRuntimeError(error.message ?: "TorChat engine failed")
            updateNotification("Błąd lokalnego engine TorChat")
            stopSelf(startId)
        }
    }

    private suspend fun startTor(host: AndroidEngineHost) {
        if (torStarting || runtime != null) return
        torStarting = true
        val startedAt = System.currentTimeMillis()
        runCatching {
            val tor = TorRuntime(applicationContext).also { runtime = it }
            val config = withContext(Dispatchers.IO) {
                tor.prepare()
                tor.start(BuildConfig.TORCHAT_SERVER_URL) { progress, summary ->
                    startupLogger.write(
                        level = "info",
                        component = "tor",
                        eventCode = "tor_bootstrap",
                        stage = "TOR_READY",
                        message = summary,
                        state = if (progress >= 100) "ready" else "starting",
                    )
                    val snapshot = torStatusSnapshot(
                        phase = if (progress >= 100) {
                            EngineContract.TRANSPORT_PHASE_CONNECTED
                        } else {
                            EngineContract.TRANSPORT_PHASE_BOOTSTRAPPING
                        },
                        label = if (progress >= 100) {
                            "Tor gotowy"
                        } else {
                            "Tor bootstrap: $progress%"
                        },
                        detail = summary,
                        progress = progress.coerceIn(0, 100),
                    )
                    // Publish each live status exactly once. Replaying every
                    // buffered status after Tor becomes ready made the UI
                    // move backwards from Done to Starting/Connecting. The
                    // engine already receives the live stream; buffering is
                    // only needed when it was not attached yet.
                    if (engineReady.isCompleted) {
                        pendingTorStatuses.clear()
                    } else {
                        pendingTorStatuses.add(snapshot)
                    }
                    publishTorStatusFact(snapshot)
                    updateNotification("Tor bootstrap: $progress%")
                }
            }
            val socks5Url = "socks5h://127.0.0.1:${config.socksPort}"
            torReadyForOnion = true
            publishEngineFact(engineTorEndpointAvailableFactJson(socks5Url))
            if (!engineReady.isCompleted) {
                pendingTorStatuses.lastOrNull()?.let(::publishTorStatusFact)
            }
            pendingTorStatuses.clear()
            if (!torReady.isCompleted) torReady.complete(Unit)
            startupLogger.write(
                level = "info",
                component = "tor",
                eventCode = "tor_ready",
                stage = "TOR_READY",
                message = "Tor SOCKS ready; relay readiness is tracked separately",
                state = "ready",
                durationMs = System.currentTimeMillis() - startedAt,
            )
            pendingOnionAction?.also { action ->
                pendingOnionAction = null
                handlePlatformAction(action)
            }
            torRetryJob = null
        }.onFailure { error ->
            Log.e("TorChat-Tor", "Tor startup failed; local UI remains usable", error)
            // TorRuntime stops and releases a failed native service. Clear the
            // reference so the retry worker can create a fresh control
            // connection instead of being blocked by `runtime != null`.
            runtime = null
            startupLogger.write(
                level = "error",
                component = "tor",
                eventCode = "tor_start_failed",
                stage = "TOR_READY",
                message = error.stackTraceToString(),
                state = "degraded",
                durationMs = System.currentTimeMillis() - startedAt,
                errorCode = error.javaClass.simpleName,
            )
            // Keep TOR_READY pending across transient bootstrap failures so
            // the retry worker can eventually complete it. It is completed
            // exceptionally only when the service is actually destroyed.
            publish(
                mapOf(
                    EngineContract.TYPE to EngineContract.TOR_STATUS,
                    EngineContract.PHASE to EngineContract.TRANSPORT_PHASE_DEGRADED,
                    EngineContract.LABEL to "Tor niedostępny · ponawianie w tle",
                    EngineContract.DETAIL to (error.message ?: "Tor startup failed"),
                    EngineContract.PROGRESS to 0,
                    EngineContract.RETRY_ATTEMPT to 1,
                ),
            )
            updateNotification("Tor niedostępny · aplikacja lokalna działa")
            scheduleTorRetry(host)
        }
        torStarting = false
    }

    /**
     * A transient Tor bootstrap failure must not permanently strand Android
     * in warming-up. Keep the engine and local data alive, then retry Tor with
     * bounded backoff. Relay/onion readiness is only published after a
     * successful bootstrap, so this cannot create a false READY state.
     */
    private fun scheduleTorRetry(host: AndroidEngineHost) {
        if (torRetryJob?.isActive == true) return
        torRetryJob = scope.launch {
            var attempt = 0
            while (kotlinx.coroutines.currentCoroutineContext().isActive &&
                engineHost === host && !torReady.isCompleted
            ) {
                attempt += 1
                val waitMs = minOf(60_000L, 5_000L * attempt)
                delay(waitMs)
                if (!networkOnline) {
                    startupLogger.write(
                        level = "info",
                        component = "tor",
                        eventCode = "tor_retry_deferred",
                        stage = "TOR_READY",
                        message = "Retry deferred because Android network is offline",
                        state = "waiting",
                        errorCode = "NETWORK_OFFLINE",
                    )
                    continue
                }
                Log.i("TorChat-Tor", "Retrying Tor startup attempt=$attempt")
                startupLogger.write(
                    level = "info",
                    component = "tor",
                    eventCode = "tor_retry",
                    stage = "TOR_READY",
                    message = "Retrying Tor bootstrap attempt=$attempt",
                    state = "starting",
                )
                startTor(host)
            }
        }
    }

    private fun resetLocalState(resetDev: Boolean, clean: Boolean) {
        val root = applicationContext.noBackupFilesDir.canonicalFile
        listOf(
            "torchat-client-v1.db",
            "torchat-client-v1.db-wal",
            "torchat-client-v1.db-shm",
            "torchat-client-v1.db-journal",
        ).forEach { name ->
            val target = root.resolve(name).canonicalFile
            require(target.parentFile == root) {
                "Reset path escaped TorChat data directory: ${target.absolutePath}"
            }
            if (target.exists() && !target.delete()) {
                error("Unable to delete client state file: ${target.absolutePath}")
            }
        }
        if (clean) LocalSecretStore(applicationContext).clearLocalSecrets()
        Log.i(
            "TorChat-Engine",
            "Service-owned client state reset completed resetDev=$resetDev clean=$clean",
        )
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        runCatching {
            getSystemService(ConnectivityManager::class.java)
                .unregisterNetworkCallback(networkCallback)
        }
        runCatching { unregisterReceiver(powerModeReceiver) }
        torRetryJob?.cancel()
        torRetryJob = null
        publishEngineFact(engineAppVisibilityChangedFactJson(foreground = false))
        publishEngineFact(engineOnionServiceLostFactJson("TorChat service stopped"))
        publishEngineFact(engineTorEndpointLostFactJson("TorChat service stopped"))
        shutdownEngineHost()
        runtime?.release()
        runtime = null
        torReadyForOnion = false
        pendingOnionAction = null
        secretStore = null
        starting = false
        torStarting = false
        activeEngineHost = null
        runtimeEventBuffer.clear()
        runtimeLatestStatus.clear()
        val stopped = IllegalStateException("TorChat service stopped")
        completeExceptionally(engineReady, stopped)
        completeExceptionally(localDataReady, stopped)
        completeExceptionally(torReady, stopped)
        completeExceptionally(onionReady, stopped)
        scope.cancel()
        super.onDestroy()
    }

    private fun shutdownEngineHost() {
        runCatching { runBlocking { engineEventPump?.stop() } }
            .onFailure { error ->
                Log.w("TorChat-Engine", "Engine event pump shutdown failed", error)
            }
        engineEventPump = null
        runCatching { engineHost?.close() }
            .onFailure { error -> Log.w("TorChat-Engine", "Engine shutdown failed", error) }
        engineHost = null
        activeEngineHost = null
    }

    private fun publish(event: Map<String, Any?>) {
        val type = event[EngineContract.TYPE] as? String
        if (type != null) {
            when (type) {
                EngineContract.TOR_STATUS -> runtimeLatestStatus["tor"] = event
                EngineContract.TRANSPORT_STATUS_CHANGED -> {
                    val component = event["component"]?.toString().orEmpty()
                    if (component.isNotEmpty()) {
                        runtimeLatestStatus["transport:$component"] = event
                    }
                }
            }
            runtimeEventBuffer.addLast(event)
            while (runtimeEventBuffer.size > MAX_RUNTIME_EVENT_BUFFER) {
                runtimeEventBuffer.pollFirst()
            }
        }
        eventListener?.invoke(event)
    }

    private fun publishRuntimeError(message: String) {
        publish(
            mapOf(
                EngineContract.TYPE to EngineContract.RUNTIME_ERROR,
                EngineContract.MESSAGE to message,
            ),
        )
    }

    private fun publishEngineFact(fact: JSONObject) {
        runCatching { engineHost?.publishPlatformFact(fact) }
            .onFailure { error ->
                Log.w(
                    "TorChat-Engine",
                    "Unable to publish engine fact ${fact.optString(EngineContract.TYPE)}",
                    error,
                )
            }
    }

    private fun publishNetworkState() {
        val manager = getSystemService(ConnectivityManager::class.java)
        val capabilities = manager.getNetworkCapabilities(manager.activeNetwork)
        val previous = networkOnline
        networkOnline = capabilities?.hasCapability(
            NetworkCapabilities.NET_CAPABILITY_INTERNET,
        ) == true
        if (previous == networkOnline) return
        publishEngineFact(engineNetworkChangedFactJson(networkOnline))
    }

    private fun publishPowerFacts() {
        val power = getSystemService(PowerManager::class.java)
        publishEngineFact(
            enginePowerModeChangedFactJson(
                batterySaver = power.isPowerSaveMode,
                deviceIdle = power.isDeviceIdleMode,
            ),
        )
    }

    private fun publishBackgroundRestrictionFact() {
        val activityManager = getSystemService(ActivityManager::class.java)
        publishEngineFact(
            engineBackgroundExecutionRestrictedFactJson(
                restricted = activityManager.isBackgroundRestricted,
            ),
        )
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
        if (event.optString(EngineContract.TYPE) == EngineContract.EVENT_PLATFORM_ACTION) {
            handlePlatformAction(
                event.optJSONObject(EngineContract.ACTION)
                    ?: error("Platform action event is missing action"),
            )
            return
        }
        val publishedEvents = mapEngineEventToPublishedEvents(event)
        publishedEvents.forEach(::publish)
        when (event.optString(EngineContract.TYPE)) {
            EngineContract.EVENT_LOG -> {
                val log = event.optJSONObject(EngineContract.LOG)
                val message = log?.optString(EngineContract.MESSAGE).orEmpty()
                startupLogger.write(
                    level = log?.optString(EngineContract.LEVEL).ifNullOrBlank { "info" },
                    component = "engine",
                    eventCode = "engine_log",
                    stage = null,
                    message = message.ifBlank { event.toString() },
                    state = null,
                )
                Log.i("TorChat-Engine", message.ifBlank { event.toString() })
            }
            EngineContract.EVENT_FATAL -> {
                val error = event.optJSONObject(EngineContract.ERROR)
                val message = error?.optString(EngineContract.MESSAGE)
                    .ifNullOrBlank { "Client engine failed" }
                Log.e("TorChat-Engine", message)
                startupLogger.write(
                    level = "error",
                    component = "engine",
                    eventCode = "engine_fatal",
                    stage = "ENGINE_READY",
                    message = message,
                    state = "failed",
                    errorCode = error?.optString(EngineContract.CODE),
                )
                publishRuntimeError(message)
            }
            EngineContract.EVENT_NOTIFICATION_REQUESTED -> {
                val request = event.optJSONObject(EngineContract.NOTIFICATION) ?: return
                val kind = request.optString(EngineContract.KIND)
                val title = when (kind) {
                    "message_received" -> getString(R.string.notification_new_message_title)
                    "pairing_request" -> getString(R.string.notification_pairing_request_title)
                    else -> getString(R.string.app_name)
                }
                val text = when (kind) {
                    "message_received" -> getString(R.string.notification_private_message_body)
                    "pairing_request" -> getString(R.string.notification_pairing_request_body)
                    else -> getString(R.string.app_name)
                }
                postAlert(
                    title = title,
                    text = text,
                    stableId = request.optString(EngineContract.ID),
                    conversationId = request.optString(EngineContract.CONVERSATION_ID),
                    kind = kind,
                )
            }
        }
    }

    private fun handlePlatformAction(action: JSONObject) {
        if (!torReadyForOnion) {
            pendingOnionAction = JSONObject(action.toString())
            startupLogger.write(
                level = "info",
                component = "peer",
                eventCode = "onion_action_queued",
                stage = "ONION_READY",
                message = "Waiting for Tor control readiness",
                state = "pending",
            )
            return
        }
        val tor = runtime ?: error("Tor runtime is not running")
        val secrets = secretStore ?: error("Local secret store is not initialized")
        val generation = action.getLong(EngineContract.GENERATION)
        runCatching {
            when (action.getString(EngineContract.TYPE)) {
                EngineContract.PLATFORM_ACTION_CONFIGURE_ONION_SERVICE -> {
                    val localPort = action.getInt(EngineContract.LOCAL_PORT)
                    val virtualPort = action.getInt(EngineContract.VIRTUAL_PORT)
                    val onionAddress = tor.configureOnionService(
                        localPort = localPort,
                        virtualPort = virtualPort,
                        generation = generation,
                        secrets = secrets,
                    )
                    onionAddress to virtualPort
                }
                EngineContract.PLATFORM_ACTION_ROTATE_ONION_SERVICE ->
                    tor.rotateOnionService(generation, secrets)
                else -> error(
                    "Unsupported platform action: ${action.optString(EngineContract.TYPE)}",
                )
            }
        }.onSuccess { (onionAddress, virtualPort) ->
            publishEngineFact(
                engineOnionServiceAvailableFactJson(
                    onionAddress = onionAddress,
                    virtualPort = virtualPort,
                    generation = generation,
                ),
            )
            if (!onionReady.isCompleted) onionReady.complete(Unit)
            startupLogger.write(
                level = "info",
                component = "peer",
                eventCode = "onion_ready",
                stage = "ONION_READY",
                message = "Peer onion service ready",
                state = "ready",
            )
            Log.i("TorChat-Tor", "Peer onion service ready generation=$generation")
        }.onFailure { error ->
            publishEngineFact(
                engineOnionServiceLostFactJson(
                    error.message ?: "Unable to configure peer onion service",
                ),
            )
            startupLogger.write(
                level = "error",
                component = "peer",
                eventCode = "onion_failed",
                stage = "ONION_READY",
                message = error.stackTraceToString(),
                state = "degraded",
                errorCode = error.javaClass.simpleName,
            )
            Log.e("TorChat-Tor", "Peer onion service configuration failed", error)
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
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, notification(text))
    }

    private fun notification(text: String): Notification =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_tor)
            .setContentTitle("TorChat")
            .setContentText(text)
            .setOngoing(true)
            .setContentIntent(
                PendingIntent.getActivity(
                    this,
                    0,
                    Intent(this, MainActivity::class.java),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                ),
            )
            .build()

    private fun createNotificationChannel() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "TorChat connection",
                NotificationManager.IMPORTANCE_LOW,
            ),
        )
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

    private fun postAlert(
        title: String,
        text: String,
        stableId: String,
        conversationId: String,
        kind: String,
    ) {
        val normalizedId = stableId.ifBlank {
            "$kind:$conversationId:${title.hashCode()}:${text.hashCode()}"
        }
        val notificationId = ALERT_NOTIFICATION_BASE + (normalizedId.hashCode() and 0x3fff)
        notifyIncomingNotification(
            context = this,
            title = title,
            text = text,
            stableId = normalizedId,
            conversationId = conversationId,
            kind = kind,
            notificationId = notificationId,
        )
    }

    companion object {
        private const val CHANNEL_ID = "torchat-tor"
        private const val ALERT_CHANNEL_ID = "torchat-alerts"
        private const val NOTIFICATION_ID = 4101
        private const val ALERT_NOTIFICATION_BASE = 5100
        private const val MAX_PROCESSED_NOTIFICATION_IDS = 256
        private const val MAX_RUNTIME_EVENT_BUFFER = 512
        private const val PROCESSED_NOTIFICATION_IDS_KEY =
            "flutter.torchat.notifications.android.processedIds"
        private const val ACTIVE_CONVERSATION_KEY =
            "flutter.torchat.notifications.activeConversationId"

        @Volatile private var processStarted = CompletableDeferred<Unit>()
        @Volatile private var engineReady = CompletableDeferred<Unit>()
        @Volatile private var localDataReady = CompletableDeferred<Unit>()
        @Volatile private var torReady = CompletableDeferred<Unit>()
        @Volatile private var onionReady = CompletableDeferred<Unit>()
        @Volatile var eventListener: ((Map<String, Any?>) -> Unit)? = null
        @Volatile var activeEngineHost: AndroidEngineHost? = null
        // Reattach must replay every recent event, not only the last event per
        // type. The previous map silently discarded updates for parallel
        // conversations and made the UI appear stale until navigation.
        private val runtimeEventBuffer = ConcurrentLinkedDeque<Map<String, Any?>>()
        /**
         * Readiness is state, not a replayable history.  Keeping the latest
         * value per component prevents Activity reattach from ending on an
         * old reconnect/error event after the service stayed alive in the
         * background.
         */
        private val runtimeLatestStatus = ConcurrentHashMap<String, Map<String, Any?>>()

        fun runtimeSnapshot(): List<Map<String, Any?>> {
            val history = runtimeEventBuffer.filter { event ->
                val type = event[EngineContract.TYPE]
                type != EngineContract.TOR_STATUS &&
                    type != EngineContract.TRANSPORT_STATUS_CHANGED
            }
            return history + runtimeLatestStatus.entries
                .sortedBy { it.key }
                .map { it.value }
        }

        fun readinessSnapshot(): Map<String, String> = mapOf(
            "PROCESS_STARTED" to deferredState(processStarted),
            "ENGINE_READY" to deferredState(engineReady),
            "LOCAL_DATA_READY" to deferredState(localDataReady),
            "TOR_READY" to deferredState(torReady),
            "ONION_READY" to deferredState(onionReady),
        )

        private fun deferredState(deferred: CompletableDeferred<Unit>): String = when {
            deferred.isCancelled -> "failed"
            deferred.isCompleted -> "ready"
            else -> "starting"
        }

        private fun resetReadinessIfStopped() {
            if (activeEngineHost != null) return
            runtimeEventBuffer.clear()
            runtimeLatestStatus.clear()
            if (processStarted.isCompleted) processStarted = CompletableDeferred()
            if (engineReady.isCompleted) engineReady = CompletableDeferred()
            if (localDataReady.isCompleted) localDataReady = CompletableDeferred()
            if (torReady.isCompleted) torReady = CompletableDeferred()
            if (onionReady.isCompleted) onionReady = CompletableDeferred()
        }

        private fun completeExceptionally(
            deferred: CompletableDeferred<Unit>,
            error: Throwable,
        ) {
            if (!deferred.isCompleted) deferred.completeExceptionally(error)
        }

        private fun notifyIncomingNotification(
            context: Context,
            title: String,
            text: String,
            stableId: String,
            conversationId: String,
            kind: String,
            notificationId: Int,
        ) {
            val preferences = context.getSharedPreferences(
                "FlutterSharedPreferences",
                Context.MODE_PRIVATE,
            )
            if (!preferences.getBoolean("flutter.torchat.notifications.enabled", true)) return

            val pairing = kind.equals("pairing", ignoreCase = true)
            val categoryEnabled = if (pairing) {
                preferences.getBoolean("flutter.torchat.notifications.pairing", true)
            } else {
                preferences.getBoolean("flutter.torchat.notifications.messages", true)
            }
            if (!categoryEnabled) return
            if (!pairing && conversationId.isNotBlank() &&
                preferences.getString(ACTIVE_CONVERSATION_KEY, "") == conversationId
            ) {
                return
            }

            val processed = LinkedHashSet(
                preferences.getStringSet(PROCESSED_NOTIFICATION_IDS_KEY, emptySet())
                    ?: emptySet(),
            )
            if (!processed.add(stableId)) return
            while (processed.size > MAX_PROCESSED_NOTIFICATION_IDS) {
                processed.remove(processed.first())
            }
            preferences.edit()
                .putStringSet(PROCESSED_NOTIFICATION_IDS_KEY, processed)
                .apply()

            val sound = preferences.getBoolean("flutter.torchat.notifications.sound", true)
            val vibration =
                preferences.getBoolean("flutter.torchat.notifications.vibration", true)
            val preview = preferences.getBoolean("flutter.torchat.notifications.preview", false)
            val visibleTitle = if (preview) title else "TorChat"
            val visibleText = if (preview) text else "Nowa prywatna wiadomość"
            ensureIncomingNotificationChannel(context)

            val openIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                if (conversationId.isNotBlank()) {
                    action = NotificationNavigation.ACTION_OPEN_CONVERSATION
                    putExtra(NotificationNavigation.EXTRA_CONVERSATION_ID, conversationId)
                    putExtra(NotificationNavigation.EXTRA_NOTIFICATION_ID, notificationId)
                }
            }
            val notification = NotificationCompat.Builder(context, ALERT_CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_tor)
                .setContentTitle(visibleTitle)
                .setContentText(visibleText.take(120))
                .setStyle(
                    NotificationCompat.BigTextStyle().bigText(visibleText.take(400)),
                )
                .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setDefaults(
                    (if (sound) Notification.DEFAULT_SOUND else 0) or
                        (if (vibration) Notification.DEFAULT_VIBRATE else 0),
                )
                .setSilent(!sound && !vibration)
                .setAutoCancel(true)
                .setContentIntent(
                    PendingIntent.getActivity(
                        context,
                        notificationId,
                        openIntent,
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

        /** Flutter connect succeeds when the local encrypted client state is usable. */
        suspend fun awaitReady() = withTimeout(10_000L) { localDataReady.await() }

        suspend fun awaitLocalReady() =
            withTimeout(10_000L) { localDataReady.await() }

        suspend fun awaitTorReady() = torReady.await()

        suspend fun awaitOnionReady() = onionReady.await()

    }
}

private fun String?.ifNullOrBlank(fallback: () -> String): String =
    if (this.isNullOrBlank()) fallback() else this
