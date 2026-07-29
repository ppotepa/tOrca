package org.torchat.mobile

import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Build
import android.content.pm.PackageManager
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
import kotlinx.coroutines.withTimeout
import net.sqlcipher.database.SQLiteDatabase
import org.json.JSONObject
import org.torchat.core.NativeIdentity
import org.torchat.security.LocalSecretStore

class MainActivity : FlutterActivity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        resetLocalStateIfRequested()
        SQLiteDatabase.loadLibs(this)
        ContextCompat.startForegroundService(this, Intent(this, TorChatForegroundService::class.java))
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission("android.permission.POST_NOTIFICATIONS") != PackageManager.PERMISSION_GRANTED) {
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
            "torchat-local.db",
            "torchat-local.db-wal",
            "torchat-local.db-shm",
            "torchat-local.db-journal",
        ).forEach { name ->
            runCatching { noBackupFilesDir.resolve(name).delete() }
        }
        if (clean) LocalSecretStore(this).clearLocalSecrets()
        android.util.Log.i(
            "TorChat-Runtime",
            "Local state reset completed resetDev=$resetDev clean=$clean",
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
                override fun onCancel(arguments: Any?) { eventSink = null }
            })
        MethodChannel(engine.dartExecutor.binaryMessenger, "org.torchat/mobile")
            .setMethodCallHandler { call, result -> handle(call, result) }
    }

    private suspend fun readyController(): org.torchat.chat.ChatController {
        TorChatForegroundService.awaitReady()
        return TorChatForegroundService.activeController
            ?: error("Połączenie z relayem nie jest jeszcze gotowe")
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        val controller = TorChatForegroundService.activeController
        when (call.method) {
            RuntimeContract.CONNECT -> connect(result)
            RuntimeContract.IDENTITY -> {
                val value = controller?.localIdentity()
                    ?: TorChatForegroundService.activeIdentity?.let { runtimeIdentityInfo(it) }
                controller?.emitLocalRuntimeEvents()
                result.success(value)
            }
            RuntimeContract.PROFILE -> {
                val value = controller?.localProfile()
                    ?: TorChatForegroundService.activeProfile?.toRuntimeMap()
                controller?.emitLocalRuntimeEvents()
                result.success(value)
            }
            RuntimeContract.REFRESH_PAIRING_CODE -> runAsync(result) {
                readyController().refreshPairingCode().toRuntimeMap()
            }
            RuntimeContract.SET_NICKNAME -> runAsync(result) {
                val nickname = call.argument<String>("nickname")?.trim().orEmpty()
                require(nickname.length in 2..32) { "Nick musi mieć od 2 do 32 znaków" }
                android.util.Log.i("TorChat-Runtime", "setNickname requested length=${nickname.length}")
                val activeController = TorChatForegroundService.activeController
                val localStore = org.torchat.security.LocalSecretStore(applicationContext)
                localStore.saveNickname(nickname)
                val activeIdentity = TorChatForegroundService.activeIdentity
                val localProfile = activeIdentity?.let {
                    runtimeProfileResponse(it, nickname)
                } ?: runCatching {
                    NativeIdentity.fromPrivateKey(localStore.identityPrivateKey()).use {
                        runtimeProfileResponse(it, nickname)
                    }
                }.getOrNull() ?: TorChatForegroundService.activeProfile?.withNickname(nickname)
                requireNotNull(localProfile) { "Lokalna tożsamość nie jest jeszcze gotowa" }
                TorChatForegroundService.activeProfile = localProfile
                runCatching {
                    activeController?.updateLocalNickname(nickname)
                    activeController?.emitLocalRuntimeEvents()
                }.onFailure { error ->
                    android.util.Log.w("TorChat-Runtime", "Nickname local runtime sync pending", error)
                }
                scope.launch(Dispatchers.IO) {
                    runCatching { withTimeout(10_000L) { activeController?.updateNickname(nickname) } }
                        .onSuccess { profile ->
                            if (profile != null) TorChatForegroundService.activeProfile = profile
                        }
                        .onFailure { error -> android.util.Log.w("TorChat-Runtime", "Nickname relay sync pending", error) }
                }
                localProfile.toRuntimeMap()
            }
            RuntimeContract.SUBMIT_PAIRING_CODE -> runAsync(result) {
                android.util.Log.i("TorChat-Pairing", "submitPairingCode requested")
                readyController().submitPairingCode(call.argument<String>("code").orEmpty()).toRuntimeMap()
            }
            RuntimeContract.PREPARE_SUBMIT_PAIRING_CODE,
            RuntimeContract.MERGE_PAIRING_INBOX,
            RuntimeContract.MERGE_PAIRING_OUTBOX,
            RuntimeContract.BOOTSTRAP_RUNTIME,
            RuntimeContract.REPORT_TOR_STATUS,
            RuntimeContract.APPLY_REMOTE_PROFILE,
            RuntimeContract.REPORT_RUNTIME_ERROR,
            RuntimeContract.REPORT_RUNTIME_LOG,
            RuntimeContract.BOOTSTRAP_CONTACT,
            RuntimeContract.PREPARE_PENDING_SEND_EFFECTS,
            RuntimeContract.APPLY_PAIRING_PEER_OUTCOME,
            RuntimeContract.WELCOME_ACCEPTED,
            RuntimeContract.RECEIVE_MESSAGE,
            RuntimeContract.APPLY_MESSAGE_TRANSPORT_OUTCOME -> {
                val value = controller?.dispatchLocalRuntime(call.method, callParams(call))
                controller?.emitLocalRuntimeEvents()
                result.success(value)
            }
            RuntimeContract.PAIRING_INBOX -> runAsync(result) {
                val value = controller?.pairingInbox().orEmpty()
                controller?.emitLocalRuntimeEvents()
                value
            }
            RuntimeContract.PAIRING_OUTBOX -> {
                val value = controller?.pairingOutbox().orEmpty()
                controller?.emitLocalRuntimeEvents()
                result.success(value)
            }
            RuntimeContract.ACCEPT_PAIRING -> runAsync(result) {
                readyController().acceptPairing(call.argument<String>("pairingId").orEmpty())
                null
            }
            RuntimeContract.REJECT_PAIRING -> runAsync(result) {
                readyController().rejectPairing(call.argument<String>("pairingId").orEmpty())
                null
            }
            RuntimeContract.CANCEL_PAIRING -> runAsync(result) {
                readyController().cancelPairing(call.argument<String>("pairingId").orEmpty())
                null
            }
            RuntimeContract.PREPARE_ACCEPT_PAIRING -> runAsync(result) { readyController().prepareAcceptPairing(call.argument<String>("pairingId").orEmpty()); null }
            RuntimeContract.COMMIT_ACCEPT_PAIRING -> runAsync(result) { readyController().commitAcceptPairing(call.argument<String>("pairingId").orEmpty()); null }
            RuntimeContract.PREPARE_REJECT_PAIRING -> runAsync(result) { readyController().prepareRejectPairing(call.argument<String>("pairingId").orEmpty()); null }
            RuntimeContract.COMMIT_REJECT_PAIRING -> runAsync(result) { readyController().commitRejectPairing(call.argument<String>("pairingId").orEmpty()); null }
            RuntimeContract.ARCHIVE_PAIRING -> runAsync(result) {
                controller?.archivePairing(call.argument<String>("pairingId").orEmpty())
                controller?.emitLocalRuntimeEvents()
                null
            }
            RuntimeContract.PREPARE_CANCEL_PAIRING -> runAsync(result) { readyController().prepareCancelPairing(call.argument<String>("pairingId").orEmpty()); null }
            RuntimeContract.CONFIRM_PAIRING_CANCELLED -> runAsync(result) { readyController().confirmPairingCancelled(call.argument<String>("pairingId").orEmpty()); null }
            RuntimeContract.NOTIFY_INCOMING -> {
                val kind = call.argument<String>("kind")
                val payload = call.argument<String>("payload")
                TorChatForegroundService.notifyIncoming(this, kind, payload)
                result.success(null)
            }
            RuntimeContract.VERIFY_CONTACT -> {
                controller?.verifyContact(call.argument<String>("installationId").orEmpty())
                controller?.emitLocalRuntimeEvents()
                result.success(null)
            }
            RuntimeContract.CONTACTS -> {
                val value = controller?.localContacts().orEmpty()
                controller?.emitLocalRuntimeEvents()
                result.success(value)
            }
            RuntimeContract.CONVERSATIONS -> {
                val value = controller?.localConversations().orEmpty()
                controller?.emitLocalRuntimeEvents()
                result.success(value)
            }
            RuntimeContract.MESSAGES -> {
                val value = controller?.messages(call.argument<String>("id").orEmpty()).orEmpty()
                controller?.emitLocalRuntimeEvents()
                result.success(value)
            }
            RuntimeContract.OPEN_CONVERSATION -> {
                controller?.openConversation(call.argument<String>("id").orEmpty())
                controller?.emitLocalRuntimeEvents()
                result.success(null)
            }
            RuntimeContract.CLOSE_CONVERSATION -> {
                controller?.closeConversation()
                controller?.emitLocalRuntimeEvents()
                result.success(null)
            }
            RuntimeContract.START_CONVERSATION -> runAsync(result) {
                readyController().startConversation(call.argument<String>("contactId").orEmpty())
                null
            }
            RuntimeContract.SEND_MESSAGE -> runAsync(result) {
                val controller = readyController()
                controller.send(call.argument<String>("id").orEmpty(), call.argument<String>("text").orEmpty())
                controller.emitLocalRuntimeEvents()
                null
            }
            else -> result.notImplemented()
        }
    }

    private fun connect(result: MethodChannel.Result) {
        if (TorChatForegroundService.activeController != null) {
            // The controller is created before the onion relay handshake is
            // complete. Never treat that local object as relay readiness.
            scope.launch {
                runCatching {
                    withContext(Dispatchers.IO) { TorChatForegroundService.awaitReady() }
                }
                    .onSuccess {
                        val activeProfile = TorChatForegroundService.activeProfile
                        val controller = TorChatForegroundService.activeController
                        if (controller != null && activeProfile != null) {
                            controller.applyRemoteProfile(activeProfile)
                            controller.emitLocalRuntimeEvents()
                        }
                        result.success(true)
                    }
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
                // service has completed onion HTTP bootstrap, authentication,
                // WebSocket connection and profile loading.
                withContext(Dispatchers.IO) { TorChatForegroundService.awaitReady() }
            }
                .onSuccess {
                    TorChatForegroundService.activeController?.let { controller ->
                        controller.reportTorStatus(
                            phase = "connected",
                            label = "Połączono z relayem przez Tor",
                            detail = "Połączono z relayem przez Tor",
                            progress = 100,
                        )
                        controller.emitLocalRuntimeEvents()
                    }
                    result.success(true)
                }
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

    private fun org.torchat.chat.ChatController.emitLocalRuntimeEvents() {
        drainLocalRuntimeEvents().forEach(::emit)
    }

    private fun callParams(call: MethodCall): JSONObject {
        val arguments = call.arguments
        return if (arguments is Map<*, *>) {
            JSONObject(arguments)
        } else {
            JSONObject()
        }
    }

    override fun onDestroy() {
        TorChatForegroundService.eventListener = null
        scope.cancel()
        super.onDestroy()
    }
}
