package org.torchat.mobile

import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import org.torchat.core.NativeIdentity
import org.torchat.generated.EngineContract
import org.torchat.security.LocalSecretStore

private const val NOTIFY_INCOMING = "notifyIncoming"

class MainActivity : FlutterActivity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        resetLocalStateIfRequested()
        ContextCompat.startForegroundService(this, Intent(this, TorChatForegroundService::class.java))
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission("android.permission.POST_NOTIFICATIONS") != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf("android.permission.POST_NOTIFICATIONS"), 4102)
        }
    }

    private fun resetLocalStateIfRequested() {
        val resetDev = BuildConfig.DEBUG && intent.getBooleanExtra("reset_dev_state", false)
        val clean = intent.getBooleanExtra("clean_state", false)
        if (!resetDev && !clean) return
        // Deployment reset flags are one-shot. Activity recreation must never
        // delete a database already owned by the foreground service.
        intent.removeExtra("reset_dev_state")
        intent.removeExtra("clean_state")
        listOf(
            "torchat-client-v1.db",
            "torchat-client-v1.db-wal",
            "torchat-client-v1.db-shm",
            "torchat-client-v1.db-journal",
        ).forEach { name ->
            runCatching {
                val target = noBackupFilesDir.resolve(name).canonicalFile
                val root = noBackupFilesDir.canonicalFile
                require(target.parentFile == root) { "Reset path escaped TorChat data directory: ${target.absolutePath}" }
                target.delete()
            }
        }
        if (clean) LocalSecretStore(this).clearLocalSecrets()
        android.util.Log.i(
            "TorChat-Runtime",
            "Developer local client state reset completed resetDev=$resetDev clean=$clean",
        )
    }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        TorChatForegroundService.eventListener = { event -> emit(event) }
        EventChannel(engine.dartExecutor.binaryMessenger, "org.torchat/mobile/events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    TorChatForegroundService.lastTorStatus?.let { status ->
                        events?.success(status)
                    }
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
        MethodChannel(engine.dartExecutor.binaryMessenger, "org.torchat/mobile")
            .setMethodCallHandler { call, result -> handle(call, result) }
    }

    private suspend fun readyEngineHost(): AndroidEngineHost {
        TorChatForegroundService.awaitLocalReady()
        return TorChatForegroundService.activeEngineHost
            ?: error("Client engine host is not ready")
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            EngineContract.CONNECT -> connect(result)
            EngineContract.GET_IDENTITY -> submitQueryResult(result, "get_identity")
            EngineContract.GET_PROFILE -> submitQueryResult(result, "get_profile")
            EngineContract.REFRESH_PAIRING_CODE -> runAsync(result) {
                readyEngineHost().submitCommandAndAwait(
                    JSONObject().put("type", "refresh_pairing_code"),
                )
            }
            EngineContract.SET_NICKNAME -> runAsync(result) {
                val nickname = call.argument<String>("nickname")?.trim().orEmpty()
                require(nickname.length in 2..32) { "Nick musi miec od 2 do 32 znakow" }
                android.util.Log.i("TorChat-Runtime", "setNickname requested length=${nickname.length}")
                val activeEngineHost = readyEngineHost()
                val localStore = LocalSecretStore(applicationContext)
                localStore.saveNickname(nickname)
                val activeIdentity = TorChatForegroundService.activeIdentity
                val localProfile = activeIdentity?.let {
                    runtimeProfileResponse(it, nickname)
                } ?: runCatching {
                    NativeIdentity.fromPrivateKey(localStore.identityPrivateKey()).use {
                        runtimeProfileResponse(it, nickname)
                    }
                }.getOrNull() ?: TorChatForegroundService.activeProfile?.withNickname(nickname)
                requireNotNull(localProfile) { "Lokalna tozsamosc nie jest jeszcze gotowa" }
                TorChatForegroundService.activeProfile = localProfile
                runCatching {
                    activeEngineHost.submitCommandAndAwait(
                        JSONObject()
                            .put("type", "set_nickname")
                            .put("nickname", nickname),
                    )
                }.onFailure { error ->
                    android.util.Log.w("TorChat-Engine", "Nickname engine sync pending", error)
                }
                localProfile.toRuntimeMap()
            }
            EngineContract.SUBMIT_PAIRING_CODE -> runAsync(result) {
                android.util.Log.i("TorChat-Pairing", "submitPairingCode requested")
                readyEngineHost().submitCommandAndAwait(
                    JSONObject()
                        .put("type", "submit_pairing_code")
                        .put("code", call.argument<String>("code").orEmpty()),
                )
            }
            EngineContract.PAIRING_INBOX -> runAsync(result) {
                readyEngineHost().submitQueryAndAwait("pairing_inbox")
            }
            EngineContract.PAIRING_OUTBOX -> submitQueryResult(result, "pairing_outbox")
            EngineContract.ACCEPT_PAIRING -> runAsync(result) {
                readyEngineHost().submitCommandAndAwait(
                    JSONObject()
                        .put("type", "accept_pairing")
                        .put("pairing_id", call.argument<String>("pairingId").orEmpty()),
                )
                null
            }
            EngineContract.REJECT_PAIRING -> runAsync(result) {
                readyEngineHost().submitCommandAndAwait(
                    JSONObject()
                        .put("type", "reject_pairing")
                        .put("pairing_id", call.argument<String>("pairingId").orEmpty()),
                )
                null
            }
            EngineContract.CANCEL_PAIRING -> runAsync(result) {
                readyEngineHost().submitCommandAndAwait(
                    JSONObject()
                        .put("type", "cancel_pairing")
                        .put("pairing_id", call.argument<String>("pairingId").orEmpty()),
                )
                null
            }
            EngineContract.ARCHIVE_PAIRING -> runAsync(result) {
                readyEngineHost().submitCommandAndAwait(
                    JSONObject()
                        .put("type", "archive_pairing")
                        .put("pairing_id", call.argument<String>("pairingId").orEmpty()),
                )
                null
            }
            NOTIFY_INCOMING -> {
                val kind = call.argument<String>("kind")
                val payload = call.argument<String>("payload")
                TorChatForegroundService.notifyIncoming(this, kind, payload)
                result.success(null)
            }
            EngineContract.VERIFY_CONTACT -> runAsync(result) {
                readyEngineHost().submitCommandAndAwait(
                    JSONObject()
                        .put("type", "verify_contact")
                        .put("installation_id", call.argument<String>("installationId").orEmpty()),
                )
                null
            }
            EngineContract.LIST_CONTACTS -> submitQueryResult(result, "list_contacts")
            EngineContract.LIST_CONVERSATIONS -> submitQueryResult(result, "list_conversations")
            EngineContract.LIST_MESSAGES -> runAsync(result) {
                readyEngineHost().submitCommandAndAwait(
                    JSONObject()
                        .put("type", "list_messages")
                        .put("conversation_id", call.argument<String>("id").orEmpty()),
                )
            }
            EngineContract.OPEN_CONVERSATION -> runAsync(result) {
                readyEngineHost().submitCommandAndAwait(
                    JSONObject()
                        .put("type", "open_conversation")
                        .put("conversation_id", call.argument<String>("id").orEmpty()),
                )
                null
            }
            EngineContract.CLOSE_CONVERSATION -> runAsync(result) {
                readyEngineHost().submitCommandAndAwait(
                    JSONObject().put("type", "close_conversation"),
                )
                null
            }
            EngineContract.START_CONVERSATION -> runAsync(result) {
                readyEngineHost().submitCommandAndAwait(
                    JSONObject()
                        .put("type", "start_conversation")
                        .put("contact_id", call.argument<String>("contactId").orEmpty()),
                )
                null
            }
            EngineContract.SEND_MESSAGE -> runAsync(result) {
                readyEngineHost().submitCommandAndAwait(
                    JSONObject()
                        .put("type", "send_message")
                        .put("conversation_id", call.argument<String>("id").orEmpty())
                        .put("body", call.argument<String>("text").orEmpty()),
                )
                null
            }
            else -> result.notImplemented()
        }
    }

    private fun submitQueryResult(result: MethodChannel.Result, type: String) {
        runAsync(result) {
            readyEngineHost().submitQueryAndAwait(type)
        }
    }

    private fun connect(result: MethodChannel.Result) {
        if (TorChatForegroundService.activeEngineHost != null) {
            scope.launch {
                runCatching {
                    withContext(Dispatchers.IO) { TorChatForegroundService.awaitReady() }
                }
                    .onSuccess { result.success(true) }
                    .onFailure { result.error("RUNTIME", it.message, null) }
            }
            return
        }
        ContextCompat.startForegroundService(this, Intent(this, TorChatForegroundService::class.java))
        scope.launch {
            runCatching {
                // `connect()` is the readiness barrier for the Flutter layer.
                // localReady only means that the embedded Tor process and the
                // local identity exist; relay operations would still fail at
                // that point with "relay is not ready". Wait until the
                // service has completed onion HTTP bootstrap and the engine
                // reports a connected state.
                withContext(Dispatchers.IO) { TorChatForegroundService.awaitReady() }
            }
                .onSuccess { result.success(true) }
                .onFailure { result.error("RUNTIME", it.message, null) }
        }
    }

    private fun <T> runAsync(result: MethodChannel.Result, block: suspend () -> T) {
        scope.launch {
            runCatching { withContext(Dispatchers.IO) { block() } }
                .onSuccess(result::success)
                .onFailure { result.error("RUNTIME", it.message, null) }
        }
    }

    private fun emit(value: Map<String, Any?>) = mainHandler.post { eventSink?.success(value) }

    override fun onDestroy() {
        TorChatForegroundService.eventListener = null
        scope.cancel()
        super.onDestroy()
    }
}
