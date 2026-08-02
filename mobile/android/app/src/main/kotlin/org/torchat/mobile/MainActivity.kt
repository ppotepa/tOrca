package org.torchat.mobile

import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaPlayer
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
import org.torchat.generated.EngineContract

class MainActivity : FlutterActivity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null
    private var introPlayer: MediaPlayer? = null
    private var pendingNotificationOpen: Map<String, Any?>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val serviceIntent = Intent(this, TorChatForegroundService::class.java)
        val resetDev = BuildConfig.DEBUG && intent.getBooleanExtra("reset_dev_state", false)
        val clean = intent.getBooleanExtra("clean_state", false)
        if (resetDev) serviceIntent.putExtra("reset_dev_state", true)
        if (clean) serviceIntent.putExtra("clean_state", true)
        intent.removeExtra("reset_dev_state")
        intent.removeExtra("clean_state")
        ContextCompat.startForegroundService(this, serviceIntent)
        handleNotificationIntent(intent)
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission("android.permission.POST_NOTIFICATIONS") != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf("android.permission.POST_NOTIFICATIONS"), 4102)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleNotificationIntent(intent)
    }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        TorChatForegroundService.eventListener = { event -> emit(event) }
        EventChannel(engine.dartExecutor.binaryMessenger, "org.torchat/mobile/events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    val sink = events ?: return
                    TorChatForegroundService.runtimeSnapshot().forEach(sink::success)
                    pendingNotificationOpen?.also { event ->
                        pendingNotificationOpen = null
                        sink.success(event)
                    }
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
        MethodChannel(engine.dartExecutor.binaryMessenger, "org.torchat/mobile")
            .setMethodCallHandler { call, result -> handle(call, result) }
        MethodChannel(engine.dartExecutor.binaryMessenger, "org.torchat/audio")
            .setMethodCallHandler { call, result ->
                if (call.method != "playIntro") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                runCatching { playIntro() }
                    .onSuccess { result.success(null) }
                    .onFailure { result.error("AUDIO", it.message, null) }
            }
    }

    private fun handleNotificationIntent(source: Intent) {
        if (source.action != NotificationNavigation.ACTION_OPEN_CONVERSATION) return
        val conversationId = source
            .getStringExtra(NotificationNavigation.EXTRA_CONVERSATION_ID)
            ?.trim()
            .orEmpty()
        val notificationId = source.getIntExtra(
            NotificationNavigation.EXTRA_NOTIFICATION_ID,
            -1,
        )
        source.action = null
        source.removeExtra(NotificationNavigation.EXTRA_CONVERSATION_ID)
        source.removeExtra(NotificationNavigation.EXTRA_NOTIFICATION_ID)
        if (conversationId.isEmpty()) return

        val event = mapOf<String, Any?>(
            EngineContract.TYPE to NotificationNavigation.EVENT_TYPE,
            EngineContract.CONVERSATION_ID to conversationId,
            "notificationId" to notificationId.toString(),
        )
        if (eventSink == null) {
            pendingNotificationOpen = event
        } else {
            emit(event)
        }
        if (notificationId >= 0) {
            getSystemService(NotificationManager::class.java).cancel(notificationId)
        }
    }

    private fun playIntro() {
        introPlayer?.let { previous ->
            runCatching { previous.stop() }
            previous.release()
        }
        introPlayer = null

        val descriptor = assets.openFd("flutter_assets/assets/audio/intro.mp3")
        val player = MediaPlayer()
        introPlayer = player
        try {
            descriptor.use {
                player.setDataSource(it.fileDescriptor, it.startOffset, it.length)
            }
            player.setOnCompletionListener { completed ->
                if (introPlayer === completed) introPlayer = null
                completed.release()
            }
            player.setOnErrorListener { failed, _, _ ->
                if (introPlayer === failed) introPlayer = null
                failed.release()
                true
            }
            player.prepare()
            player.start()
        } catch (error: Throwable) {
            if (introPlayer === player) introPlayer = null
            player.release()
            throw error
        }
    }

    private suspend fun readyEngineHost(): AndroidEngineHost {
        // Once the foreground service has published its host, the Rust actor and
        // event pump are already live.  Do not wait on a secondary readiness
        // latch here: it can belong to a service generation that is being
        // restarted, turning a local profile command into an artificial 10 s
        // timeout before it ever reaches the engine.
        TorChatForegroundService.activeEngineHost?.let { return it }
        TorChatForegroundService.awaitLocalReady()
        return TorChatForegroundService.activeEngineHost
            ?: error("Client engine host is not ready")
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            EngineContract.CONNECT -> connect(result)
            EngineContract.GET_IDENTITY -> submitQueryResult(result, EngineContract.COMMAND_GET_IDENTITY)
            EngineContract.GET_PROFILE -> submitQueryResult(result, EngineContract.COMMAND_GET_PROFILE)
            EngineContract.GET_APPLICATION_SNAPSHOT -> submitQueryResult(
                result,
                EngineContract.COMMAND_GET_APPLICATION_SNAPSHOT,
            )
            EngineContract.REFRESH_PAIRING_CODE -> submitCommandResult(
                result,
                engineCommand(EngineContract.COMMAND_REFRESH_PAIRING_CODE),
            )
            EngineContract.SET_NICKNAME -> runAsync(result) {
                val nickname = call.argument<String>(EngineContract.NICKNAME)?.trim().orEmpty()
                require(nickname.length in 2..32) { "Nick musi miec od 2 do 32 znakow" }
                readyEngineHost().submitCommandAndAwait(
                    engineCommand(EngineContract.COMMAND_SET_NICKNAME)
                        .put(EngineContract.NICKNAME, nickname),
                )
            }
            EngineContract.SUBMIT_PAIRING_CODE -> submitCommandResult(
                result,
                engineCommand(EngineContract.COMMAND_SUBMIT_PAIRING_CODE)
                    .put(EngineContract.CODE, call.argument<String>(EngineContract.CODE).orEmpty()),
            )
            EngineContract.PAIRING_INBOX -> submitQueryResult(
                result,
                EngineContract.COMMAND_PAIRING_INBOX,
            )
            EngineContract.PAIRING_OUTBOX -> submitQueryResult(
                result,
                EngineContract.COMMAND_PAIRING_OUTBOX,
            )
            EngineContract.ACCEPT_PAIRING -> submitPairingCommand(
                result,
                EngineContract.COMMAND_ACCEPT_PAIRING,
                call.argument<String>(EngineContract.ARG_PAIRING_ID).orEmpty(),
            )
            EngineContract.REJECT_PAIRING -> submitPairingCommand(
                result,
                EngineContract.COMMAND_REJECT_PAIRING,
                call.argument<String>(EngineContract.ARG_PAIRING_ID).orEmpty(),
            )
            EngineContract.CANCEL_PAIRING -> submitPairingCommand(
                result,
                EngineContract.COMMAND_CANCEL_PAIRING,
                call.argument<String>(EngineContract.ARG_PAIRING_ID).orEmpty(),
            )
            EngineContract.ARCHIVE_PAIRING -> submitPairingCommand(
                result,
                EngineContract.COMMAND_ARCHIVE_PAIRING,
                call.argument<String>(EngineContract.ARG_PAIRING_ID).orEmpty(),
            )
            EngineContract.VERIFY_CONTACT -> submitCommandResult(
                result,
                engineCommand(EngineContract.COMMAND_VERIFY_CONTACT)
                    .put(
                        EngineContract.COMMAND_INSTALLATION_ID,
                        call.argument<String>(EngineContract.ARG_INSTALLATION_ID).orEmpty(),
                    ),
                discardPayload = true,
            )
            EngineContract.UPDATE_CONTACT_SETTINGS -> submitCommandResult(
                result,
                engineCommand(EngineContract.COMMAND_UPDATE_CONTACT_SETTINGS)
                    .put(
                        EngineContract.COMMAND_INSTALLATION_ID,
                        call.argument<String>(EngineContract.ARG_INSTALLATION_ID).orEmpty(),
                    )
                    .put(
                        EngineContract.LOCAL_ALIAS,
                        call.argument<String>(EngineContract.LOCAL_ALIAS),
                    )
                    .put(
                        EngineContract.MUTED,
                        call.argument<Boolean>(EngineContract.MUTED) ?: false,
                    )
                    .put(
                        EngineContract.BLOCKED,
                        call.argument<Boolean>(EngineContract.BLOCKED) ?: false,
                    )
                    .apply {
                        call.argument<String>(EngineContract.TRANSPORT_POLICY)?.let {
                            put(EngineContract.TRANSPORT_POLICY, it)
                        }
                    },
            )
            EngineContract.GET_PEER_ENDPOINT -> submitQueryResult(
                result,
                EngineContract.COMMAND_GET_PEER_ENDPOINT,
            )
            EngineContract.GET_STARTUP_READINESS -> submitQueryResult(
                result,
                EngineContract.COMMAND_GET_STARTUP_READINESS,
            )
            EngineContract.RETRY_PEER_CONNECTION -> submitCommandResult(
                result,
                engineCommand(EngineContract.COMMAND_RETRY_PEER_CONNECTION)
                    .put(
                        EngineContract.COMMAND_INSTALLATION_ID,
                        call.argument<String>(EngineContract.ARG_INSTALLATION_ID).orEmpty(),
                    ),
            )
            EngineContract.ROTATE_PEER_ENDPOINT -> submitCommandResult(
                result,
                engineCommand(EngineContract.COMMAND_ROTATE_PEER_ENDPOINT),
                discardPayload = true,
            )
            EngineContract.LIST_CONTACTS -> submitQueryResult(
                result,
                EngineContract.COMMAND_LIST_CONTACTS,
            )
            EngineContract.LIST_CONVERSATIONS -> submitQueryResult(
                result,
                EngineContract.COMMAND_LIST_CONVERSATIONS,
            )
            EngineContract.LIST_MESSAGES -> submitCommandResult(
                result,
                engineCommand(EngineContract.COMMAND_LIST_MESSAGES)
                    .put(
                        EngineContract.COMMAND_CONVERSATION_ID,
                        call.argument<String>(EngineContract.ARG_ID).orEmpty(),
                    ),
            )
            EngineContract.OPEN_CONVERSATION -> submitCommandResult(
                result,
                engineCommand(EngineContract.COMMAND_OPEN_CONVERSATION)
                    .put(
                        EngineContract.COMMAND_CONVERSATION_ID,
                        call.argument<String>(EngineContract.ARG_ID).orEmpty(),
                    ),
                discardPayload = true,
            )
            EngineContract.CLOSE_CONVERSATION -> submitCommandResult(
                result,
                engineCommand(EngineContract.COMMAND_CLOSE_CONVERSATION),
                discardPayload = true,
            )
            EngineContract.START_CONVERSATION -> submitCommandResult(
                result,
                engineCommand(EngineContract.COMMAND_START_CONVERSATION)
                    .put(
                        EngineContract.COMMAND_CONTACT_ID,
                        call.argument<String>(EngineContract.ARG_CONTACT_ID).orEmpty(),
                    ),
                discardPayload = true,
            )
            EngineContract.SEND_MESSAGE -> submitCommandResult(
                result,
                engineCommand(EngineContract.COMMAND_SEND_MESSAGE)
                    .put(
                        EngineContract.COMMAND_CONVERSATION_ID,
                        call.argument<String>(EngineContract.ARG_ID).orEmpty(),
                    )
                    .put(
                        EngineContract.BODY,
                        call.argument<String>(EngineContract.ARG_TEXT).orEmpty(),
                    )
                    .apply {
                        call.argument<String>(EngineContract.ARG_REPLY_TO_MESSAGE_ID)?.let {
                            put(EngineContract.COMMAND_REPLY_TO_MESSAGE_ID, it)
                        }
                    },
                discardPayload = true,
            )
            EngineContract.RETRY_MESSAGE -> submitCommandResult(
                result,
                engineCommand(EngineContract.COMMAND_RETRY_MESSAGE)
                    .put(
                        EngineContract.MESSAGE_ID,
                        call.argument<String>(EngineContract.MESSAGE_ID).orEmpty(),
                    ),
                discardPayload = true,
            )
            EngineContract.DELETE_MESSAGE_LOCAL -> submitCommandResult(
                result,
                engineCommand(EngineContract.COMMAND_DELETE_MESSAGE_LOCAL)
                    .put(
                        EngineContract.MESSAGE_ID,
                        call.argument<String>(EngineContract.MESSAGE_ID).orEmpty(),
                    ),
                discardPayload = true,
            )
            EngineContract.SET_TYPING -> submitCommandResult(
                result,
                engineCommand(EngineContract.COMMAND_SET_TYPING)
                    .put(
                        EngineContract.COMMAND_CONVERSATION_ID,
                        call.argument<String>(EngineContract.CONVERSATION_ID).orEmpty(),
                    )
                    .put(
                        EngineContract.TYPING,
                        call.argument<Boolean>(EngineContract.TYPING) ?: false,
                    ),
                discardPayload = true,
            )
            EngineContract.SET_PRESENCE -> submitCommandResult(
                result,
                engineCommand(EngineContract.COMMAND_SET_PRESENCE)
                    .put(
                        EngineContract.ONLINE,
                        call.argument<Boolean>(EngineContract.ONLINE) ?: false,
                    ),
                discardPayload = true,
            )
            EngineContract.SEND_READ_RECEIPTS -> submitCommandResult(
                result,
                engineCommand(EngineContract.COMMAND_SEND_READ_RECEIPTS)
                    .put(
                        EngineContract.COMMAND_CONVERSATION_ID,
                        call.argument<String>(EngineContract.ARG_ID).orEmpty(),
                    ),
                discardPayload = true,
            )
            EngineContract.PLATFORM_FACT -> runAsync(result) {
                val rawFact = call.argument<Map<*, *>>(EngineContract.FACT)
                    ?: error("Platform fact is missing")
                val fact = JSONObject().apply {
                    rawFact.forEach { (key, value) -> put(key.toString(), value) }
                }
                readyEngineHost().publishPlatformFact(fact)
                null
            }
            else -> result.notImplemented()
        }
    }

    private fun submitPairingCommand(
        result: MethodChannel.Result,
        commandType: String,
        pairingId: String,
    ) {
        submitCommandResult(
            result,
            engineCommand(commandType).put(EngineContract.COMMAND_PAIRING_ID, pairingId),
            discardPayload = true,
        )
    }

    private fun submitQueryResult(result: MethodChannel.Result, commandType: String) {
        runAsync(result) { readyEngineHost().submitQueryAndAwait(commandType) }
    }

    private fun submitCommandResult(
        result: MethodChannel.Result,
        command: JSONObject,
        discardPayload: Boolean = false,
    ) {
        runAsync(result) {
            val payload = readyEngineHost().submitCommandAndAwait(command)
            if (discardPayload) null else payload
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
        introPlayer?.release()
        introPlayer = null
        TorChatForegroundService.eventListener = null
        scope.cancel()
        super.onDestroy()
    }
}
