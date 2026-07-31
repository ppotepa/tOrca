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
    private var activeServiceId: String? = null
    private var activeLocalPort: Int? = null
    private var activeVirtualPort: Int? = null

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
        require(relayOnionUrl.isNotBlank()) { "Control-plane onion URL is required" }
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

            Log.i("TorChat-Tor", "Tor SOCKS ready on port $socksPort; onion circuits are on demand")
            // A listening SOCKS port proves that the local Tor process is
            // usable, not that the first remote onion circuit has completed.
            // Reporting 100 here made the UI show "Tor gotowy" and then
            // regress while the shared engine was still connecting to relay.
            onBootstrapProgress(85, "Tor SOCKS gotowy · rozgrzewanie obwodu relay")
            return prepared.copy(socksPort = socksPort)
        } catch (error: Throwable) {
            failure = error
            stop()
            throw failure
        }
    }

    private fun isListening(port: Int): Boolean = runCatching {
        Socket().use { it.connect(InetSocketAddress("127.0.0.1", port), 500) }
        true
    }.getOrDefault(false)

    @Synchronized
    fun configureOnionService(
        localPort: Int,
        virtualPort: Int,
        generation: Long,
        secrets: LocalSecretStore,
    ): String {
        require(localPort in 1..65535) { "Invalid peer listener port" }
        require(virtualPort in 1..65535) { "Invalid onion virtual port" }
        val control = service?.torControlConnection
            ?: error("Tor control connection is not available")
        val previousServiceId = activeServiceId ?: secrets.onionServiceId(generation)
        if (!previousServiceId.isNullOrBlank()) {
            runCatching { control.delOnion(previousServiceId) }
        }
        val key = secrets.onionPrivateKey(generation) ?: "NEW:ED25519-V3"
        val result = control.addOnion(
            key,
            mapOf(virtualPort to "127.0.0.1:$localPort"),
        )
        val serviceId = result.entries
            .firstOrNull {
                it.key.equals("ServiceID", ignoreCase = true) ||
                    it.key.equals("onionAddress", ignoreCase = true)
            }
            ?.value
            ?.trim()
            ?.lowercase()
            ?.removeSuffix(".onion")
            ?: error("Tor ADD_ONION did not return ServiceID (keys=${result.keys})")
        require(serviceId.matches(Regex("^[a-z2-7]{56}$"))) {
            "Tor ADD_ONION returned an invalid service ID"
        }
        result.entries
            .firstOrNull {
                it.key.equals("PrivateKey", ignoreCase = true) ||
                    it.key.equals("onionPrivKey", ignoreCase = true)
            }
            ?.value
            ?.takeIf { it.isNotBlank() }
            ?.let { secrets.storeOnionPrivateKey(generation, it) }
        secrets.storeOnionServiceId(generation, serviceId)
        activeServiceId = serviceId
        activeLocalPort = localPort
        activeVirtualPort = virtualPort
        return "$serviceId.onion"
    }

    @Synchronized
    fun rotateOnionService(generation: Long, secrets: LocalSecretStore): Pair<String, Int> {
        val localPort = activeLocalPort ?: error("Peer listener has not been configured")
        val virtualPort = activeVirtualPort ?: error("Onion virtual port has not been configured")
        return configureOnionService(localPort, virtualPort, generation, secrets) to virtualPort
    }

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
        activeServiceId = null
        activeLocalPort = null
        activeVirtualPort = null
        Log.i("TorChat-Tor", "Native Tor service released")
    }
}
