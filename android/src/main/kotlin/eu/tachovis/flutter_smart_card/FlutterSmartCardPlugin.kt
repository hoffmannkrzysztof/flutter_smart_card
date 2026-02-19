package eu.tachovis.flutter_smart_card

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.nio.ByteBuffer
import java.nio.ByteOrder

class FlutterSmartCardPlugin : FlutterPlugin, MethodCallHandler, ActivityAware {

    private lateinit var channel: MethodChannel
    private var applicationContext: Context? = null
    private var activity: Activity? = null

    private var usbManager: UsbManager? = null
    private var usbConnection: UsbDeviceConnection? = null
    private var usbInterface: UsbInterface? = null
    private var endpointIn: UsbEndpoint? = null
    private var endpointOut: UsbEndpoint? = null
    private var seq: Byte = 0
    private var pendingResult: Result? = null

    private val ACTION_USB_PERMISSION = "eu.tachovis.flutter_smart_card.USB_PERMISSION"

    // CCID Constants
    private val CCID_CLASS = 0x0B
    private val PC_to_RDR_IccPowerOn = 0x62.toByte()
    private val PC_to_RDR_XfrBlock = 0x6F.toByte()
    private val RDR_to_PC_DataBlock = 0x80.toByte()

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val action = intent.action
            if (ACTION_USB_PERMISSION == action) {
                synchronized(this) {
                    val device: UsbDevice? = if (Build.VERSION.SDK_INT >= 33) {
                        intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
                    }

                    if (intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)) {
                        if (device != null) {
                            connectToDevice(device)
                        } else {
                            Log.e(TAG, "Device reference lost after permission grant")
                            pendingResult?.error("DEVICE_LOST", "Device reference lost after permission grant", null)
                            pendingResult = null
                        }
                    } else {
                        Log.d(TAG, "permission denied for device $device")
                        pendingResult?.error("PERMISSION_DENIED", "User denied USB permission", null)
                        pendingResult = null
                    }
                }
            }
        }
    }

    private var receiverRegistered = false

    // FlutterPlugin

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = flutterPluginBinding.applicationContext
        usbManager = applicationContext?.getSystemService(Context.USB_SERVICE) as? UsbManager
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "flutter_smart_card")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        disconnect()
        applicationContext = null
        usbManager = null
    }

    // ActivityAware

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        registerReceiver()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        registerReceiver()
    }

    override fun onDetachedFromActivityForConfigChanges() {
        unregisterReceiver()
        activity = null
    }

    override fun onDetachedFromActivity() {
        unregisterReceiver()
        activity = null
    }

    private fun registerReceiver() {
        if (receiverRegistered) return
        val ctx = applicationContext ?: return
        val filter = IntentFilter(ACTION_USB_PERMISSION)
        if (Build.VERSION.SDK_INT >= 33) {
            ctx.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            ctx.registerReceiver(receiver, filter)
        }
        receiverRegistered = true
    }

    private fun unregisterReceiver() {
        if (!receiverRegistered) return
        try {
            applicationContext?.unregisterReceiver(receiver)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to unregister receiver: ${e.message}")
        }
        receiverRegistered = false
    }

    // MethodCallHandler

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "listReaders" -> listReaders(result)
            "connect" -> connect(call, result)
            "transmit" -> transmit(call, result)
            "disconnect" -> {
                disconnect()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // Smart card operations

    private fun listReaders(result: Result) {
        val mgr = usbManager
        if (mgr == null) {
            result.error("NO_USB", "USB manager not available", null)
            return
        }
        val readers = mutableListOf<String>()
        val deviceList = mgr.deviceList
        for (device in deviceList.values) {
            if (isSmartCardReader(device)) {
                readers.add(device.deviceName)
            }
        }
        result.success(readers)
    }

    private fun isSmartCardReader(device: UsbDevice): Boolean {
        for (i in 0 until device.interfaceCount) {
            if (device.getInterface(i).interfaceClass == CCID_CLASS) {
                return true
            }
        }
        return false
    }

    private fun connect(call: MethodCall, result: Result) {
        val mgr = usbManager
        if (mgr == null) {
            result.error("NO_USB", "USB manager not available", null)
            return
        }

        val readerName = call.argument<String>("reader")
        if (readerName == null) {
            result.error("INVALID_ARGUMENT", "Reader name is required", null)
            return
        }

        val device = mgr.deviceList[readerName]
        if (device == null) {
            result.error("DEVICE_NOT_FOUND", "Device not found", null)
            return
        }

        if (mgr.hasPermission(device)) {
            if (connectToDevice(device)) {
                result.success(true)
            } else {
                result.error("CONNECTION_FAILED", "Failed to connect to device", null)
            }
        } else {
            pendingResult = result
            val ctx = applicationContext ?: run {
                result.error("NO_CONTEXT", "Application context not available", null)
                pendingResult = null
                return
            }
            val usbPermissionIntent = Intent(ACTION_USB_PERMISSION).apply { setPackage(ctx.packageName) }
            val permissionIntent = PendingIntent.getBroadcast(ctx, 0, usbPermissionIntent, PendingIntent.FLAG_MUTABLE)
            mgr.requestPermission(device, permissionIntent)
        }
    }

    private fun connectToDevice(device: UsbDevice): Boolean {
        val mgr = usbManager ?: return false

        var intf: UsbInterface? = null
        for (i in 0 until device.interfaceCount) {
            if (device.getInterface(i).interfaceClass == CCID_CLASS) {
                intf = device.getInterface(i)
                break
            }
        }

        if (intf == null) return false

        val connection = mgr.openDevice(device) ?: return false
        if (!connection.claimInterface(intf, true)) {
            connection.close()
            return false
        }

        usbConnection = connection
        usbInterface = intf

        for (i in 0 until intf.endpointCount) {
            val ep = intf.getEndpoint(i)
            if (ep.type == UsbConstants.USB_ENDPOINT_XFER_BULK) {
                if (ep.direction == UsbConstants.USB_DIR_IN) {
                    endpointIn = ep
                } else {
                    endpointOut = ep
                }
            }
        }

        if (endpointIn == null || endpointOut == null) {
            disconnect()
            return false
        }

        // Setup pending result success if it was waiting for permission
        pendingResult?.success(true)
        pendingResult = null

        // Power On Card
        return powerOnCard()
    }

    private fun powerOnCard(): Boolean {
        val cmd = ByteBuffer.allocate(10)
        cmd.put(PC_to_RDR_IccPowerOn)
        cmd.putInt(0) // dwLength = 0
        cmd.put(0) // bSlot = 0
        cmd.put(seq++) // bSeq
        cmd.put(0) // bPowerSelect (0=Auto, 1=5V, 2=3V, 3=1.8V)
        cmd.put(0) // abRFU
        cmd.put(0) // abRFU

        val cmdBytes = cmd.array()
        val written = usbConnection?.bulkTransfer(endpointOut, cmdBytes, cmdBytes.size, 5000) ?: -1
        if (written < 0) return false

        val buffer = ByteArray(64)
        val read = usbConnection?.bulkTransfer(endpointIn, buffer, buffer.size, 5000) ?: -1
        if (read < 10) return false

        if (buffer[0] != RDR_to_PC_DataBlock) {
            Log.e(TAG, "PowerOn failed: Response Type ${buffer[0]}")
            return false
        }

        Thread.sleep(150)
        return true
    }

    private fun transmit(call: MethodCall, result: Result) {
        val apdu = call.argument<ByteArray>("apdu")
        if (apdu == null || usbConnection == null) {
            result.error("ERROR", "Invalid state or argument", null)
            return
        }

        try {
            val response = sendCcidCommand(apdu)
            result.success(response)
        } catch (e: Exception) {
            result.error("TRANSMIT_FAILED", e.message, null)
        }
    }

    private fun sendCcidCommand(apdu: ByteArray): ByteArray {
        val cmdLen = apdu.size
        val cmd = ByteBuffer.allocate(10 + cmdLen)
        cmd.order(ByteOrder.LITTLE_ENDIAN)
        cmd.put(PC_to_RDR_XfrBlock)
        cmd.putInt(cmdLen)
        cmd.put(0) // bSlot
        cmd.put(seq++) // bSeq
        cmd.put(4) // bBWI (Block Waiting Integer)
        cmd.putShort(0) // wLevelParameter
        cmd.put(apdu)

        val cmdBytes = cmd.array()
        val written = usbConnection?.bulkTransfer(endpointOut, cmdBytes, cmdBytes.size, 5000) ?: -1
        if (written < 0) throw Exception("Write failed")

        val buffer = ByteArray(1024)
        val read = usbConnection?.bulkTransfer(endpointIn, buffer, buffer.size, 5000) ?: -1
        if (read < 10) throw Exception("Read failed or too short")

        val responseBuffer = ByteBuffer.wrap(buffer, 0, read).order(ByteOrder.LITTLE_ENDIAN)
        val msgType = responseBuffer.get()
        val dataLen = responseBuffer.getInt()
        val slot = responseBuffer.get()
        val seqResp = responseBuffer.get()
        val status = responseBuffer.get()
        val error = responseBuffer.get()
        val chainParams = responseBuffer.get()

        if (stateHasError(status)) {
            throw Exception("CCID Error Status: $status, Error: $error")
        }

        if (msgType != RDR_to_PC_DataBlock) {
            throw Exception("Unexpected message type: $msgType")
        }

        val actualData = ByteArray(dataLen)
        if (read >= 10 + dataLen) {
            System.arraycopy(buffer, 10, actualData, 0, dataLen)
        }

        return actualData
    }

    private fun stateHasError(status: Byte): Boolean {
        val statusInt = status.toInt() and 0xFF
        val cmdStatus = (statusInt ushr 6) and 0x03
        return cmdStatus == 1
    }

    private fun disconnect() {
        if (usbConnection != null) {
            usbInterface?.let { usbConnection?.releaseInterface(it) }
            usbConnection?.close()
            usbConnection = null
            usbInterface = null
            endpointIn = null
            endpointOut = null
        }
    }

    companion object {
        private const val TAG = "FlutterSmartCard"
    }
}
