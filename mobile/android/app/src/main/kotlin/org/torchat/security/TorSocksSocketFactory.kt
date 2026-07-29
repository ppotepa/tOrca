package org.torchat.security

import android.util.Log
import okhttp3.Dns
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketAddress
import java.nio.channels.SocketChannel
import javax.net.SocketFactory

/**
 * Performs the SOCKS5 domain-name handshake explicitly.
 *
 * Android's java.net SOCKS implementation can stall while connecting to a
 * .onion host even though the same local Tor listener is healthy. This socket
 * never resolves the destination locally: it sends ATYP=DOMAIN and the exact
 * v3 onion hostname to Tor.
 */
class TorSocksSocketFactory(private val socksPort: Int) : SocketFactory() {
    init {
        require(socksPort in 1..65535) { "Invalid Tor SOCKS port" }
    }

    override fun createSocket(): Socket = TorSocksSocket(socksPort)

    override fun createSocket(host: String, port: Int): Socket =
        createSocket().apply { connect(InetSocketAddress.createUnresolved(host, port)) }

    override fun createSocket(host: String, port: Int, localHost: InetAddress, localPort: Int): Socket =
        createSocket().apply {
            bind(InetSocketAddress(localHost, localPort))
            connect(InetSocketAddress.createUnresolved(host, port))
        }

    override fun createSocket(host: InetAddress, port: Int): Socket =
        createSocket(host.hostName, port)

    override fun createSocket(
        address: InetAddress,
        port: Int,
        localAddress: InetAddress,
        localPort: Int,
    ): Socket = createSocket(address.hostName, port, localAddress, localPort)
}

/**
 * OkHttp still asks Dns for route candidates before opening a plain HTTP
 * socket. Return a synthetic address carrying the original hostname; the
 * custom socket ignores its bytes and forwards hostString to Tor.
 */
object TorRemoteDns : Dns {
    override fun lookup(hostname: String): List<InetAddress> {
        require(TorTransport.validateOnionAddress(hostname)) {
            "TorChat attempted to resolve a non-onion host"
        }
        Log.i(LOG_TAG, "Routing ${hostname.take(12)}… through Tor remote DNS")
        return listOf(InetAddress.getByAddress(hostname, byteArrayOf(0, 0, 0, 1)))
    }
}

private class TorSocksSocket(private val socksPort: Int) : Socket() {
    private val delegate = Socket()
    private var logicalRemote: InetSocketAddress? = null

    override fun connect(endpoint: SocketAddress) = connect(endpoint, 60_000)

    override fun connect(endpoint: SocketAddress, timeout: Int) {
        check(logicalRemote == null) { "Socket is already connected" }
        val destination = endpoint as? InetSocketAddress
            ?: throw IllegalArgumentException("SOCKS destination must be an InetSocketAddress")
        val hostname = destination.hostString.lowercase()
        if (!TorTransport.validateOnionAddress(hostname)) {
            throw IOException("TorChat blocked a non-onion socket destination")
        }

        Log.i(LOG_TAG, "Opening SOCKS5 connection to ${hostname.take(12)}…:${destination.port} via 127.0.0.1:$socksPort")
        try {
            delegate.connect(InetSocketAddress("127.0.0.1", socksPort), timeout)
            // The connection to Tor is local, but the SOCKS CONNECT reply
            // waits for a fresh onion circuit and can take well over 20s.
            delegate.soTimeout = SOCKS_HANDSHAKE_TIMEOUT_MS
            Log.i(LOG_TAG, "Local Tor SOCKS listener accepted the socket")
            performSocks5Handshake(delegate, hostname, destination.port)
            logicalRemote = destination
            Log.i(LOG_TAG, "Tor SOCKS5 onion circuit established")
        } catch (error: Throwable) {
            Log.w(LOG_TAG, "Tor SOCKS5 connection failed: ${error.message}")
            runCatching { delegate.close() }
            throw error
        }
    }

    override fun bind(bindpoint: SocketAddress?) = delegate.bind(bindpoint)
    override fun getInputStream(): InputStream = delegate.getInputStream()
    override fun getOutputStream(): OutputStream = delegate.getOutputStream()
    override fun close() = delegate.close()
    override fun shutdownInput() = delegate.shutdownInput()
    override fun shutdownOutput() = delegate.shutdownOutput()
    override fun sendUrgentData(data: Int) = delegate.sendUrgentData(data)
    override fun getChannel(): SocketChannel? = delegate.channel

    override fun getInetAddress(): InetAddress? = logicalRemote?.address
    override fun getLocalAddress(): InetAddress = delegate.localAddress
    override fun getPort(): Int = logicalRemote?.port ?: 0
    override fun getLocalPort(): Int = delegate.localPort
    override fun getRemoteSocketAddress(): SocketAddress? = logicalRemote
    override fun getLocalSocketAddress(): SocketAddress? = delegate.localSocketAddress
    override fun isBound(): Boolean = delegate.isBound
    override fun isConnected(): Boolean = logicalRemote != null && delegate.isConnected
    override fun isClosed(): Boolean = delegate.isClosed
    override fun isInputShutdown(): Boolean = delegate.isInputShutdown
    override fun isOutputShutdown(): Boolean = delegate.isOutputShutdown

    override fun setSoTimeout(timeout: Int) { delegate.soTimeout = timeout }
    override fun getSoTimeout(): Int = delegate.soTimeout
    override fun setTcpNoDelay(on: Boolean) { delegate.tcpNoDelay = on }
    override fun getTcpNoDelay(): Boolean = delegate.tcpNoDelay
    override fun setKeepAlive(on: Boolean) { delegate.keepAlive = on }
    override fun getKeepAlive(): Boolean = delegate.keepAlive
    override fun setReuseAddress(on: Boolean) { delegate.reuseAddress = on }
    override fun getReuseAddress(): Boolean = delegate.reuseAddress
    override fun setReceiveBufferSize(size: Int) { delegate.receiveBufferSize = size }
    override fun getReceiveBufferSize(): Int = delegate.receiveBufferSize
    override fun setSendBufferSize(size: Int) { delegate.sendBufferSize = size }
    override fun getSendBufferSize(): Int = delegate.sendBufferSize
    override fun setSoLinger(on: Boolean, linger: Int) { delegate.setSoLinger(on, linger) }
    override fun getSoLinger(): Int = delegate.soLinger
    override fun setOOBInline(on: Boolean) { delegate.oobInline = on }
    override fun getOOBInline(): Boolean = delegate.oobInline
    override fun setTrafficClass(tc: Int) { delegate.trafficClass = tc }
    override fun getTrafficClass(): Int = delegate.trafficClass
    override fun setPerformancePreferences(connectionTime: Int, latency: Int, bandwidth: Int) =
        delegate.setPerformancePreferences(connectionTime, latency, bandwidth)
}

private fun performSocks5Handshake(socket: Socket, hostname: String, port: Int) {
    val input = socket.getInputStream()
    val output = socket.getOutputStream()

    output.write(byteArrayOf(0x05, 0x01, 0x00))
    output.flush()
    val greeting = input.readExactly(2)
    if (greeting[0] != 0x05.toByte() || greeting[1] != 0x00.toByte()) {
        throw IOException("Tor SOCKS5 proxy rejected unauthenticated negotiation")
    }

    val host = hostname.toByteArray(Charsets.US_ASCII)
    if (host.isEmpty() || host.size > 255) throw IOException("Invalid SOCKS5 hostname")
    val request = ByteArray(7 + host.size)
    request[0] = 0x05
    request[1] = 0x01
    request[2] = 0x00
    request[3] = 0x03
    request[4] = host.size.toByte()
    host.copyInto(request, destinationOffset = 5)
    request[5 + host.size] = (port ushr 8).toByte()
    request[6 + host.size] = port.toByte()
    output.write(request)
    output.flush()

    val response = input.readExactly(4)
    if (response[0] != 0x05.toByte()) throw IOException("Invalid Tor SOCKS5 response")
    if (response[1] != 0x00.toByte()) {
        throw IOException("Tor SOCKS5 connection failed with code ${response[1].toInt() and 0xff}")
    }
    when (response[3].toInt() and 0xff) {
        0x01 -> input.readExactly(4)
        0x03 -> input.readExactly(input.readExactly(1)[0].toInt() and 0xff)
        0x04 -> input.readExactly(16)
        else -> throw IOException("Invalid Tor SOCKS5 address type")
    }
    input.readExactly(2)
}

private fun InputStream.readExactly(length: Int): ByteArray {
    val result = ByteArray(length)
    var offset = 0
    while (offset < length) {
        val read = read(result, offset, length - offset)
        if (read < 0) throw IOException("Tor SOCKS5 proxy closed the connection")
        offset += read
    }
    return result
}

private const val LOG_TAG = "TorChat-SOCKS"
// Cold v3 onion circuits on Android can exceed a minute. Match the service
// readiness budget so Tor can finish one circuit before the app rotates it.
private const val SOCKS_HANDSHAKE_TIMEOUT_MS = 180_000
