package io.github.nphil.videoengine.sample

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.SocketException

/** Finds the IPv4 address other devices on the same network can use to reach this one. */
object LocalAddress {
    /**
     * The best address to show, or null when the device has none: a private address on Wi-Fi or Ethernet first, then
     * any other private address, a VPN's last. It asks the connectivity service, and only when that has nothing it
     * looks at the network interfaces.
     */
    @Suppress("DEPRECATION")
    fun find(context: Context): String? {
        val found = ArrayList<Pair<Int, String>>()
        val manager = context.getSystemService(ConnectivityManager::class.java)
        for (network in manager.allNetworks) {
            val capabilities = manager.getNetworkCapabilities(network)
            val lan = capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true ||
                capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true
            val vpn = capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
            for (link in manager.getLinkProperties(network)?.linkAddresses.orEmpty()) {
                val address = link.address as? Inet4Address ?: continue
                if (address.isLoopbackAddress || address.isLinkLocalAddress) continue
                val text = address.hostAddress ?: continue
                val rank = when {
                    lan && address.isSiteLocalAddress -> 0
                    lan -> 1
                    vpn -> 3
                    address.isSiteLocalAddress -> 2
                    else -> 3
                }
                found += rank to text
            }
        }
        if (found.isEmpty()) {
            val interfaces = try {
                NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
            } catch (_: SocketException) {
                emptyList()
            }
            for (networkInterface in interfaces) {
                for (address in networkInterface.inetAddresses.toList()) {
                    if (address !is Inet4Address || address.isLoopbackAddress || address.isLinkLocalAddress) continue
                    val text = address.hostAddress ?: continue
                    found += (if (address.isSiteLocalAddress) 4 else 5) to text
                }
            }
        }
        return found.minByOrNull { it.first }?.second
    }
}
