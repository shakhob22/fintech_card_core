package com.example.fintech_card_core

import android.app.Activity
import android.graphics.BitmapFactory
import android.media.ExifInterface
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.IsoDep
import android.os.Bundle
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.Result
import java.io.IOException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * FintechCardCorePlugin — Android NFC + CardScan SSD OCR bridge.
 *
 * NFC: thin IsoDep relay (APDU/EMV stay in Dart).
 * OCR: headless getbouncer SSD TFLite via [CardScanOcrBridge] (no CardScan UI).
 */
class FintechCardCorePlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    NfcAdapter.ReaderCallback {

    private lateinit var methodChannel: MethodChannel
    private lateinit var ocrChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null

    private var activity: Activity? = null
    private var nfcAdapter: NfcAdapter? = null
    private var currentTag: IsoDep? = null
    private var sessionActive = false

    private val ocrExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private var cardScanBridge: CardScanOcrBridge? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        cardScanBridge = CardScanOcrBridge(binding.applicationContext)
        // Warm TFLite on a background thread so the first camera frame is faster.
        ocrExecutor.execute {
            try {
                cardScanBridge?.ensureInitialized()
            } catch (e: Exception) {
                // First recognizeFrame will retry / surface the error.
            }
        }

        methodChannel = MethodChannel(binding.binaryMessenger, "fintech_card_core/nfc")
        methodChannel.setMethodCallHandler(this)

        ocrChannel = MethodChannel(binding.binaryMessenger, "fintech_card_core/ocr")
        ocrChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "ocr/recognizeText" -> {
                    val imagePath = call.argument<String>("imagePath")
                        ?: return@setMethodCallHandler result.error(
                            "INVALID_ARGS",
                            "Missing 'imagePath' argument",
                            null,
                        )
                    handleRecognizeText(imagePath, result)
                }
                "ocr/recognizeFrame" -> handleRecognizeFrame(call, result)
                "ocr/recognizeGray8" -> handleRecognizeGray8(call, result)
                else -> result.notImplemented()
            }
        }
        eventChannel = EventChannel(binding.binaryMessenger, "fintech_card_core/nfc/events")
        eventChannel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            },
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        ocrChannel.setMethodCallHandler(null)
        cardScanBridge?.close()
        cardScanBridge = null
        ocrExecutor.shutdownNow()
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "nfc/isAvailable" -> handleIsAvailable(result)
            "nfc/startSession" -> handleStartSession(result)
            "nfc/stopSession" -> handleStopSession(result)
            "nfc/transceive" -> {
                @Suppress("UNCHECKED_CAST")
                val apdu = call.argument<List<Int>>("apdu")
                    ?: return result.error("INVALID_ARGS", "Missing 'apdu' argument", null)
                handleTransceive(apdu, result)
            }
            else -> result.notImplemented()
        }
    }

    private fun handleIsAvailable(result: Result) {
        val act = activity ?: return result.success(false)
        val adapter = NfcAdapter.getDefaultAdapter(act)
        result.success(adapter != null && adapter.isEnabled)
    }

    private fun handleStartSession(result: Result) {
        val act = activity
            ?: return result.error("NO_ACTIVITY", "Plugin not attached to an Activity", null)

        nfcAdapter = NfcAdapter.getDefaultAdapter(act)
        if (nfcAdapter == null || !nfcAdapter!!.isEnabled) {
            return result.error("NFC_NOT_AVAILABLE", "NFC is not available or disabled", null)
        }

        val flags =
            NfcAdapter.FLAG_READER_NFC_A or
                NfcAdapter.FLAG_READER_NFC_B or
                NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK

        val extras = Bundle().apply {
            putInt(NfcAdapter.EXTRA_READER_PRESENCE_CHECK_DELAY, 250)
        }

        nfcAdapter!!.enableReaderMode(act, this, flags, extras)
        sessionActive = true
        result.success(null)
    }

    private fun handleStopSession(result: Result) {
        sessionActive = false
        currentTag?.safeClose()
        currentTag = null
        activity?.let { nfcAdapter?.disableReaderMode(it) }
        result.success(null)
    }

    private fun handleTransceive(apduBytes: List<Int>, result: Result) {
        val tag = currentTag
        if (tag == null || !tag.isConnected) {
            return result.error("NO_TAG", "No NFC tag connected", null)
        }

        Thread {
            try {
                val command = ByteArray(apduBytes.size) { apduBytes[it].toByte() }
                val response = tag.transceive(command)
                val unsigned = response.map { it.toInt() and 0xFF }
                activity?.runOnUiThread { result.success(unsigned) }
                    ?: result.success(unsigned)
            } catch (e: IOException) {
                activity?.runOnUiThread {
                    result.error("TRANSCEIVE_ERROR", e.message ?: "IO error", null)
                }
            }
        }.start()
    }

    override fun onTagDiscovered(tag: Tag?) {
        if (!sessionActive) return

        val isoDep = IsoDep.get(tag)
        if (isoDep == null) {
            sendEvent("error", "Unsupported card type — only ISO 14443-4 cards are supported")
            return
        }

        try {
            isoDep.connect()
            isoDep.timeout = 5_000
            currentTag = isoDep
            sendEvent("tagDetected", null)
        } catch (e: IOException) {
            sendEvent("error", e.message ?: "Tag connection failed")
        }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {}

    override fun onDetachedFromActivity() {
        sessionActive = false
        currentTag?.safeClose()
        currentTag = null
        activity = null
    }

    // ── OCR (CardScan SSD) ────────────────────────────────────────────────────

    private fun handleRecognizeText(imagePath: String, result: Result) {
        ocrExecutor.execute {
            try {
                val bridge = cardScanBridge
                    ?: return@execute result.error("OCR_FAILED", "OCR bridge not ready", null)
                val raw = BitmapFactory.decodeFile(imagePath)
                    ?: throw IOException("BitmapFactory returned null for $imagePath")
                val oriented = orientFromExif(raw, imagePath)
                val map = bridge.recognizeBitmap(oriented)
                if (oriented !== raw) oriented.recycle()
                raw.recycle()
                result.success(map)
            } catch (e: Exception) {
                result.error("OCR_FAILED", e.message ?: "Text recognition failed", null)
            }
        }
    }

    private fun handleRecognizeGray8(call: MethodCall, result: Result) {
        val width = call.argument<Int>("width")
        val height = call.argument<Int>("height")
        val bytes = call.argument<ByteArray>("bytes")

        if (width == null || height == null || bytes == null) {
            result.error("INVALID_ARGS", "Missing gray8 width/height/bytes", null)
            return
        }
        if (bytes.size < width * height) {
            result.error("INVALID_ARGS", "gray8 buffer shorter than width×height", null)
            return
        }

        ocrExecutor.execute {
            try {
                val bridge = cardScanBridge
                    ?: return@execute result.error("OCR_FAILED", "OCR bridge not ready", null)
                result.success(bridge.recognizeGray8(bytes, width, height))
            } catch (e: Exception) {
                result.error("OCR_FAILED", e.message ?: "Gray8 recognition failed", null)
            }
        }
    }

    private fun handleRecognizeFrame(call: MethodCall, result: Result) {
        val format = call.argument<String>("format") ?: "nv21"
        val width = call.argument<Int>("width")
        val height = call.argument<Int>("height")
        val rotation = call.argument<Int>("rotation") ?: 0
        val bytes = call.argument<ByteArray>("bytes")

        if (width == null || height == null || bytes == null) {
            result.error("INVALID_ARGS", "Missing frame width/height/bytes", null)
            return
        }

        val roiLeft = call.argument<Double>("roiLeft")
        val roiTop = call.argument<Double>("roiTop")
        val roiWidth = call.argument<Double>("roiWidth")
        val roiHeight = call.argument<Double>("roiHeight")
        val roi = if (roiLeft != null && roiTop != null &&
            roiWidth != null && roiHeight != null
        ) {
            floatArrayOf(
                roiLeft.toFloat(),
                roiTop.toFloat(),
                roiWidth.toFloat(),
                roiHeight.toFloat(),
            )
        } else {
            null
        }

        ocrExecutor.execute {
            try {
                if (format != "nv21") {
                    result.error("OCR_FAILED", "Unsupported Android frame format: $format", null)
                    return@execute
                }
                val bridge = cardScanBridge
                    ?: return@execute result.error("OCR_FAILED", "OCR bridge not ready", null)
                result.success(
                    bridge.recognizeNv21(bytes, width, height, rotation, roi),
                )
            } catch (e: Exception) {
                result.error("OCR_FAILED", e.message ?: "Frame recognition failed", null)
            }
        }
    }

    private fun orientFromExif(raw: android.graphics.Bitmap, imagePath: String): android.graphics.Bitmap {
        val exif = ExifInterface(imagePath)
        val orientation = exif.getAttributeInt(
            ExifInterface.TAG_ORIENTATION,
            ExifInterface.ORIENTATION_NORMAL,
        )
        val degrees = when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> 90f
            ExifInterface.ORIENTATION_ROTATE_180 -> 180f
            ExifInterface.ORIENTATION_ROTATE_270 -> 270f
            else -> return raw
        }
        val matrix = android.graphics.Matrix().apply { postRotate(degrees) }
        return android.graphics.Bitmap.createBitmap(
            raw,
            0,
            0,
            raw.width,
            raw.height,
            matrix,
            true,
        )
    }

    private fun sendEvent(type: String, message: String?) {
        val payload = mutableMapOf<String, Any>("type" to type)
        if (message != null) payload["message"] = message
        activity?.runOnUiThread { eventSink?.success(payload) }
    }

    private fun IsoDep.safeClose() {
        try {
            close()
        } catch (_: Exception) {
        }
    }
}
