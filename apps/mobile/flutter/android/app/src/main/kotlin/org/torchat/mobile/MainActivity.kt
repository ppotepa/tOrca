package org.torchat.mobile

import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaPlayer
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.torchat.generated.EngineContract

class MainActivity : FlutterActivity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val engineDispatcher by lazy {
        EngineMethodDispatcher(this, mainHandler, scope)
    }
    private var eventSink: EventChannel.EventSink? = null
    private var introPlayer: MediaPlayer? = null
    private var pendingNotificationOpen: Map<String, Any?>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        NativeLocaleManager.applyStoredPreference(this)
        super.onCreate(savedInstanceState)
        val serviceIntent = Intent(this, TorChatForegroundService::class.java)
        val resetDev = BuildConfig.DEBUG && intent.getBooleanExtra("reset_dev_state", false)
        val clean = intent.getBooleanExtra("clean_state", false)
        if (resetDev) serviceIntent.putExtra("reset_dev_state", true)
        if (clean) serviceIntent.putExtra("clean_state", true)
        intent.removeExtra("reset_dev_state")
        intent.removeExtra("clean_state")
        ensureForegroundService(serviceIntent)
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

    override fun onStart() {
        super.onStart()
        val serviceIntent = Intent(this, TorChatForegroundService::class.java)
            .putExtra("deploy_run_id", intent.getStringExtra("deploy_run_id"))
        ensureForegroundService(serviceIntent)
    }

    private fun ensureForegroundService(serviceIntent: Intent) {
        runCatching { ContextCompat.startForegroundService(this, serviceIntent) }
            .onFailure { error ->
                Log.e(
                    "Torca-Engine",
                    "Unable to request TorChatForegroundService start: ${error.message}",
                    error,
                )
            }
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
            .setMethodCallHandler(engineDispatcher::handle)
        MethodChannel(engine.dartExecutor.binaryMessenger, "org.torchat/locale")
            .setMethodCallHandler { call, result ->
                if (call.method != "setApplicationLocale") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val languageTag = call.argument<String>("languageTag")
                NativeLocaleManager.setApplicationLocale(this, languageTag)
                result.success(null)
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                    recreate()
                }
            }
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

    private fun emit(value: Map<String, Any?>) = mainHandler.post { eventSink?.success(value) }

    override fun onDestroy() {
        introPlayer?.release()
        introPlayer = null
        TorChatForegroundService.eventListener = null
        scope.cancel()
        super.onDestroy()
    }
}
