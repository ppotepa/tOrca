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
import net.sqlcipher.database.SQLiteDatabase
import org.torchat.data.ChatMessage
import org.torchat.data.LocalContact
import org.torchat.data.LocalConversation

class MainActivity : FlutterActivity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        resetDebugStateIfRequested()
        SQLiteDatabase.loadLibs(this)
        ContextCompat.startForegroundService(this, Intent(this, TorChatForegroundService::class.java))
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission("android.permission.POST_NOTIFICATIONS") != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf("android.permission.POST_NOTIFICATIONS"), 4102)
        }
    }

    private fun resetDebugStateIfRequested() {
        if (!BuildConfig.DEBUG || !intent.getBooleanExtra("reset_dev_state", false)) return
        listOf(
            "torchat-local.db",
            "torchat-local.db-wal",
            "torchat-local.db-shm",
            "torchat-local.db-journal",
        ).forEach { name ->
            runCatching { noBackupFilesDir.resolve(name).delete() }
        }
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

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        val controller = TorChatForegroundService.activeController
        when (call.method) {
            "connect" -> connect(result)
            "identity" -> result.success(TorChatForegroundService.identityInfo())
            "refreshPairingCode" -> runAsync(result) {
                TorChatForegroundService.activeController?.refreshPairingCode()?.toMap() ?: error("runtime not connected")
            }
            "setNickname" -> runAsync(result) {
                val nickname = call.argument<String>("nickname")?.trim().orEmpty()
                require(nickname.length in 2..32) { "Nick musi mieć od 2 do 32 znaków" }
                TorChatForegroundService.activeController?.updateNickname(nickname)?.toMap() ?: error("runtime not connected")
            }
            "submitPairingCode" -> runAsync(result) {
                TorChatForegroundService.activeController?.submitPairingCode(call.argument<String>("code").orEmpty())
                    ?: error("runtime not connected")
            }
            "pairingInbox" -> result.success(controller?.pairingInbox()?.map { it.toMap() }.orEmpty())
            "acceptPairing" -> runAsync(result) { controller?.acceptPairing(call.argument<String>("pairingId").orEmpty()) ?: error("runtime not connected"); null }
            "rejectPairing" -> runAsync(result) { controller?.rejectPairing(call.argument<String>("pairingId").orEmpty()) ?: error("runtime not connected"); null }
            "verifyContact" -> { controller?.verifyContact(call.argument<String>("installationId").orEmpty()); result.success(null) }
            "contacts" -> result.success(controller?.localContacts()?.map { it.toMap() }.orEmpty())
            "conversations" -> result.success(controller?.localConversations()?.map { it.toMap() }.orEmpty())
            "messages" -> result.success(controller?.messages(call.argument<String>("id").orEmpty())?.map { it.toMap() }.orEmpty())
            "openConversation" -> { controller?.openConversation(call.argument<String>("id").orEmpty()); result.success(null) }
            "sendMessage" -> runAsync(result) {
                TorChatForegroundService.activeController?.send(call.argument<String>("id").orEmpty(), call.argument<String>("text").orEmpty())
                null
            }
            else -> result.notImplemented()
        }
    }

    private fun connect(result: MethodChannel.Result) {
        if (TorChatForegroundService.activeController != null) {
            TorChatForegroundService.activeProfile?.let { profile ->
                emit(mapOf("type" to "profile_ready", "profile" to profile.toMap(), "identity" to TorChatForegroundService.identityInfo()))
            }
            result.success(true)
            return
        }
        emit(mapOf("type" to "tor_status", "phase" to "starting", "label" to "Uruchamianie Tor"))
        ContextCompat.startForegroundService(this, Intent(this, TorChatForegroundService::class.java))
        scope.launch {
            runCatching { withContext(Dispatchers.IO) { TorChatForegroundService.awaitReady() } }
                .onSuccess {
                    emit(mapOf("type" to "tor_status", "phase" to "connected", "label" to "Onion połączony · relay aktywny"))
                    TorChatForegroundService.activeProfile?.let { profile ->
                        emit(mapOf("type" to "profile_ready", "profile" to profile.toMap(), "identity" to TorChatForegroundService.identityInfo()))
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

    override fun onDestroy() {
        TorChatForegroundService.eventListener = null
        scope.cancel()
        super.onDestroy()
    }
}

private fun org.torchat.transport.PairingCode.toMap() = mapOf("code" to code, "expiresAt" to expiresAt)
private fun org.torchat.data.LocalPairingInboxItem.toMap() = mapOf(
    "pairingId" to pairingId,
    "sender" to mapOf("installationId" to senderInstallationId, "nickname" to senderNickname, "publicKey" to senderPublicKey, "fingerprint" to senderFingerprint),
    "expiresAt" to expiresAt,
    "state" to state.name,
)

private fun LocalContact.toMap() = mapOf("installationId" to installationId, "nickname" to nickname, "publicKey" to publicKey, "fingerprint" to fingerprint, "verification" to verification.name, "dev" to devFixture)
private fun LocalConversation.toMap() = mapOf("id" to id, "contactInstallationId" to contactInstallationId, "status" to status.name, "unreadCount" to unreadCount, "lastMessagePreview" to lastMessagePreview, "lastMessageAt" to lastMessageAt)
private fun ChatMessage.toMap() = mapOf("id" to id.toString(), "conversationId" to conversationId, "outgoing" to outgoing, "body" to body, "state" to state.name, "createdAt" to createdAt, "error" to error)
private fun org.torchat.transport.ProfileResponse.toMap() = mapOf("installationId" to installationId, "nickname" to nickname, "publicKey" to publicKey, "fingerprint" to fingerprint)
