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
import java.net.URI
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
        // TorService owns the generated torrc, SOCKS port and private data
        // directory. Do not overwrite it here: replacing its template with a
        // one-line file discarded cache/persistence settings and turned many
        // application restarts into cold Tor starts.
        val prepared = TorRuntimeConfig(
            dataDirectory = torrc.parentFile ?: context.filesDir,
            torrc = torrc,
            socksPort = 0,
        )
        config = prepared
        return prepared
    }

    fun start(
        relayOnionUrl: String,
        onBootstrapProgress: (Int, String) -> Unit = { _, _ -> },
    ): TorRuntimeConfig {
        check(service == null) { "Tor runtime is already running" }
        val prepared = config ?: prepare()
        val relayUri = URI(relayOnionUrl)
        val relayHost = relayUri.host?.lowercase().orEmpty()
        require(relayHost.matches(Regex("^[a-z2-7]{56}\\.onion$"))) {
            "Relay URL must contain a Tor v3 onion host"
        }
        val relayPort = relayUri.port.takeIf { it > 0 }
            ?: if (relayUri.scheme.equals("https", ignoreCase = true)) 443 else 80
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

            val bootstrapStartedAt = System.nanoTime()
            val bootstrapTimeoutNanos = TimeUnit.MINUTES.toNanos(3)
            var onionReady = false
            var attempt = 0
            while (System.nanoTime() - bootstrapStartedAt < bootstrapTimeoutNanos) {
                attempt += 1
                onionReady = probeOnion(socksPort, relayHost, relayPort)
                if (onionReady) break
                val elapsedSeconds = TimeUnit.NANOSECONDS.toSeconds(
                    System.nanoTime() - bootstrapStartedAt,
                )
                val progress = (5 + elapsedSeconds * 90 / 180).toInt().coerceIn(5, 95)
                val summary = "Budowanie obwodu do $relayHost (próba $attempt)"
                onBootstrapProgress(progress, summary)
                if (attempt == 1 || attempt % 10 == 0) {
                    Log.i("TorChat-Tor", "$summary progress=$progress%")
                }
                Thread.sleep(1_000)
            }
            check(onionReady) {
                "Tor nie zbudował obwodu do $relayHost w ciągu 3 minut"
            }
            Log.i("TorChat-Tor", "Onion circuit ready through SOCKS5 port $socksPort: $relayHost:$relayPort")
            onBootstrapProgress(100, "Tor gotowy · obwód onion działa")
            return prepared.copy(socksPort = socksPort)
        } catch (error: Throwable) {
            failure = error
            stop()
            throw failure
        }
    }

    private fun probeOnion(port: Int, host: String, targetPort: Int): Boolean = runCatching {
        val domain = host.toByteArray(Charsets.US_ASCII)
        require(domain.size in 1..255) { "Invalid SOCKS5 domain length" }
        Socket().use { socket ->
            socket.connect(InetSocketAddress("127.0.0.1", port), 5_000)
            socket.soTimeout = 5_000
            val output = socket.getOutputStream()
            val input = socket.getInputStream()
            output.write(byteArrayOf(0x05, 0x01, 0x00))
            output.flush()
            val greeting = input.readNBytes(2)
            check(greeting.size == 2 && greeting[0] == 0x05.toByte() && greeting[1] == 0x00.toByte())

            val request = ByteArray(7 + domain.size)
            request[0] = 0x05
            request[1] = 0x01
            request[2] = 0x00
            request[3] = 0x03
            request[4] = domain.size.toByte()
            domain.copyInto(request, destinationOffset = 5)
            request[request.lastIndex - 1] = (targetPort ushr 8).toByte()
            request[request.lastIndex] = targetPort.toByte()
            output.write(request)
            output.flush()

            val response = input.readNBytes(4)
            response.size == 4 &&
                response[0] == 0x05.toByte() &&
                response[1] == 0x00.toByte()
        }
    }.getOrDefault(false)

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
