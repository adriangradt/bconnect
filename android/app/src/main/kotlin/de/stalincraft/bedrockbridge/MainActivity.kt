package de.stalincraft.bedrockbridge

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address
import java.net.NetworkInterface

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "acquireMulticastLock" -> {
                        acquireMulticastLock()
                        result.success(null)
                    }
                    "releaseMulticastLock" -> {
                        releaseMulticastLock()
                        result.success(null)
                    }
                    "getBroadcastAddresses" -> result.success(broadcastAddresses())
                    "startBridgeService" -> {
                        requestNotificationPermission()
                        val intent = Intent(this, BridgeService::class.java)
                            .putExtra(BridgeService.EXTRA_TITLE, call.argument<String>("title") ?: "BedrockBridge")
                            .putExtra(BridgeService.EXTRA_TEXT, call.argument<String>("text") ?: "")
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
                        result.success(null)
                    }
                    "stopBridgeService" -> {
                        stopService(Intent(this, BridgeService::class.java))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("native_error", e.message, null)
            }
        }
    }

    // Many Android devices drop incoming broadcast datagrams unless a
    // multicast lock is held. Without it consoles' LAN pings never arrive.
    private fun acquireMulticastLock() {
        if (multicastLock?.isHeld == true) return
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicastLock = wifi.createMulticastLock("BedrockBridge").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseMulticastLock() {
        multicastLock?.let { if (it.isHeld) it.release() }
        multicastLock = null
    }

    private fun broadcastAddresses(): List<String> {
        val out = mutableListOf<String>()
        for (nif in NetworkInterface.getNetworkInterfaces() ?: return out) {
            if (!nif.isUp || nif.isLoopback) continue
            for (ia in nif.interfaceAddresses) {
                if (ia.address is Inet4Address) ia.broadcast?.hostAddress?.let { out.add(it) }
            }
        }
        return out.distinct()
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }

    override fun onDestroy() {
        releaseMulticastLock()
        super.onDestroy()
    }

    companion object {
        const val CHANNEL = "de.stalincraft.bedrockbridge/network"
    }
}
