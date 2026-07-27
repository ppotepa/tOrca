package org.torchat.security

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import android.util.Log
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.torproject.jni.TorService

data class TorRuntimeConfig(
    val dataDirectory: File,
    val torrc: File,
    val socksPort: Int,
)

/**
 * Owns the app's native Tor Android service.
 *
 * TorService ships the normal Tor client (including onion-service client
 * support) and exposes its SOCKS port after its control socket is ready.
 */
class TorRuntime(private val context: Context) {
    private var service: TorService? = null
    private var connection: ServiceConnection? = null
    private var config: TorRuntimeConfig? = null

    fun prepare(): TorRuntimeConfig {
        val torrc = TorService.getTorrc(context)
        torrc.parentFile?.mkdirs()
        // TorService supplies the private DataDirectory and defaults torrc.
        // Keep this file deliberately small: relay traffic must go through the
        // SOCKS listener selected by the native service.
        torrc.writeText("ClientOnly 1\n")
        val prepared = TorRuntimeConfig(
            dataDirectory = torrc.parentFile ?: context.filesDir,
            torrc = torrc,
            socksPort = 0,
        )
        config = prepared
        return prepared
    }

    fun start(onBootstrapProgress: (Int, String) -> Unit = { _, _ -> }): TorRuntimeConfig {
        check(service == null) { "Tor runtime is already running" }
        val prepared = config ?: prepare()
        val ready = CountDownLatch(1)
        var failure: Throwable? = null

        val serviceConnection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                service = (binder as? TorService.LocalBinder)?.service
                Log.i("TorChat-Tor", "Native Tor service bound")
                ready.countDown()
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                service = null
            }
        }
        connection = serviceConnection

        val intent = Intent(context, TorService::class.java).setAction(TorService.ACTION_START)
        check(context.bindService(intent, serviceConnection, Context.BIND_AUTO_CREATE)) {
            "Unable to bind native Tor service"
        }
        try {
            context.startService(intent)
            check(ready.await(10, TimeUnit.SECONDS)) { "Native Tor service did not bind" }

            var socksPort = 0
            for (attempt in 0 until 240) {
                val publishedPort = service?.socksPort ?: 0
                socksPort = publishedPort
                // TorService selects 9050 when it is free. This fallback also
                // covers the short window before its control thread publishes
                // getSocksPort(), without weakening the SOCKS-only transport.
                if (socksPort <= 0 && isListening(9050)) socksPort = 9050
                if (attempt == 0 || socksPort > 0) {
                    Log.i("TorChat-Tor", "SOCKS probe attempt=$attempt servicePort=$publishedPort selected=$socksPort")
                }
                // The service publishes the port from Tor's control socket;
                // the relay layer already has retry/backoff for circuit bootstrapping.
                if (publishedPort > 0 || socksPort > 0) break
                Thread.sleep(500)
            }
            Log.i("TorChat-Tor", "Native Tor SOCKS port detected: $socksPort")
            check(socksPort > 0) { "Native Tor did not publish a SOCKS port" }

            var bootstrapProgress = 0
            var bootstrapSummary = "Uruchamianie sieci Tor"
            for (attempt in 0 until 360) {
                val phase = runCatching {
                    service?.getInfo("status/bootstrap-phase").orEmpty()
                }.getOrDefault("")
                val progress = Regex("""PROGRESS=(\d+)""")
                    .find(phase)?.groupValues?.getOrNull(1)?.toIntOrNull()
                val summary = Regex("""SUMMARY="([^"]+)"""")
                    .find(phase)?.groupValues?.getOrNull(1)
                if (progress != null && (progress != bootstrapProgress || attempt == 0)) {
                    bootstrapProgress = progress
                    bootstrapSummary = summary ?: bootstrapSummary
                    Log.i("TorChat-Tor", "Bootstrap $bootstrapProgress%: $bootstrapSummary")
                    onBootstrapProgress(bootstrapProgress, bootstrapSummary)
                }
                if (bootstrapProgress >= 100) break
                Thread.sleep(500)
            }
            check(bootstrapProgress >= 100) {
                "Tor bootstrap zatrzymał się na $bootstrapProgress%: $bootstrapSummary"
            }
            return prepared.copy(socksPort = socksPort)
        } catch (error: Throwable) {
            failure = error
            release()
            throw failure
        }
    }

    private fun isListening(port: Int): Boolean = runCatching {
        Socket().use { it.connect(InetSocketAddress("127.0.0.1", port), 500) }
        true
    }.getOrDefault(false)

    fun stop() {
        release()
        runCatching { context.stopService(Intent(context, TorService::class.java)) }
        Log.i("TorChat-Tor", "Native Tor service stopped")
    }

    /** Detaches the Activity while allowing Tor to keep its circuits alive. */
    fun release() {
        val boundConnection = connection
        if (boundConnection != null) {
            runCatching { context.unbindService(boundConnection) }
        }
        connection = null
        service = null
        Log.i("TorChat-Tor", "Native Tor service released")
    }
}
