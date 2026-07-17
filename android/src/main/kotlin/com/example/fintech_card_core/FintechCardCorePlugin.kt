package com.example.fintech_card_core

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.Matrix
import android.graphics.Paint
import android.media.ExifInterface
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.IsoDep
import android.os.Bundle
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
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
import kotlin.math.max
import kotlin.math.min
/**
 * FintechCardCorePlugin — Android NFC bridge.
 *
 * Architecture contract
 * ─────────────────────
 * This class is a THIN BRIDGE ONLY.
 *
 * Responsibility:
 *   1. Enable / disable the OS NFC ReaderMode on the current Activity.
 *   2. Surface tag-detection events to Dart via EventChannel.
 *   3. Forward raw APDU byte arrays between Dart and IsoDep.transceive().
 *
 * What this class does NOT do:
 *   - Build or interpret APDU commands.
 *   - Parse EMV/TLV data.
 *   - Make any payment or network call.
 *
 * All protocol logic lives in the Dart layer (nfc_card_reader.dart, emv_parser.dart).
 */
class FintechCardCorePlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    NfcAdapter.ReaderCallback {

    // ── Channels ──────────────────────────────────────────────────────────────
    private lateinit var methodChannel: MethodChannel
    private lateinit var ocrChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null

    // ── NFC state ─────────────────────────────────────────────────────────────
    private var activity: Activity? = null
    private var nfcAdapter: NfcAdapter? = null
    private var currentTag: IsoDep? = null
    private var sessionActive = false

    // ── OCR ───────────────────────────────────────────────────────────────────
    private val ocrExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val textRecognizer by lazy {
        TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
    }
    private val digitRunRegex = Regex("""\d{13,19}""")

    // ── FlutterPlugin ─────────────────────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel = MethodChannel(binding.binaryMessenger, "fintech_card_core/nfc")
        methodChannel.setMethodCallHandler(this)

        ocrChannel = MethodChannel(binding.binaryMessenger, "fintech_card_core/ocr")
        ocrChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "ocr/recognizeText" -> {
                    val imagePath = call.argument<String>("imagePath")
                        ?: return@setMethodCallHandler result.error(
                            "INVALID_ARGS", "Missing 'imagePath' argument", null
                        )
                    handleRecognizeText(imagePath, result)
                }
                "ocr/recognizeFrame" -> handleRecognizeFrame(call, result)
                else -> result.notImplemented()
            }
        }
        eventChannel = EventChannel(binding.binaryMessenger, "fintech_card_core/nfc/events")
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
            }
            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        ocrChannel.setMethodCallHandler(null)
    }

    // ── MethodCallHandler ─────────────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "nfc/isAvailable" -> handleIsAvailable(result)
            "nfc/startSession" -> handleStartSession(result)
            "nfc/stopSession"  -> handleStopSession(result)
            "nfc/transceive"   -> {
                @Suppress("UNCHECKED_CAST")
                val apdu = call.argument<List<Int>>("apdu")
                    ?: return result.error("INVALID_ARGS", "Missing 'apdu' argument", null)
                handleTransceive(apdu, result)
            }
            else -> result.notImplemented()
        }
    }

    // ── NFC methods ───────────────────────────────────────────────────────────

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

    /**
     * Send [apduBytes] to the connected IsoDep tag and return the raw response.
     *
     * Runs on a background thread because IsoDep.transceive() is blocking.
     * The response is a plain List<Int> (unsigned byte values 0-255).
     */
    private fun handleTransceive(apduBytes: List<Int>, result: Result) {
        val tag = currentTag
        if (tag == null || !tag.isConnected) {
            return result.error("NO_TAG", "No NFC tag connected", null)
        }

        Thread {
            try {
                val command = ByteArray(apduBytes.size) { apduBytes[it].toByte() }
                val response = tag.transceive(command)
                // Convert to List<Int> with unsigned values (0-255) for Dart
                val unsigned = response.map { it.toInt() and 0xFF }
                // Post back to the main thread — Flutter result must be called
                // on the platform thread.
                activity?.runOnUiThread { result.success(unsigned) }
                    ?: result.success(unsigned)
            } catch (e: IOException) {
                activity?.runOnUiThread {
                    result.error("TRANSCEIVE_ERROR", e.message ?: "IO error", null)
                }
            }
        }.start()
    }

    // ── NfcAdapter.ReaderCallback ─────────────────────────────────────────────

    /**
     * Called by the OS when an NFC tag enters the field.
     * Only ISO-DEP (ISO 14443-4) tags are accepted — these carry EMV applets.
     */
    override fun onTagDiscovered(tag: Tag?) {
        if (!sessionActive) return

        val isoDep = IsoDep.get(tag)
        if (isoDep == null) {
            sendEvent("error", "Unsupported card type — only ISO 14443-4 cards are supported")
            return
        }

        try {
            isoDep.connect()
            isoDep.timeout = 5_000 // 5 s per APDU command
            currentTag = isoDep
            sendEvent("tagDetected", null)
        } catch (e: IOException) {
            sendEvent("error", e.message ?: "Tag connection failed")
        }
    }

    // ── ActivityAware ─────────────────────────────────────────────────────────

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

    // ── OCR ───────────────────────────────────────────────────────────────────

    /**
     * Still-photo path (debug / fallback). Live scanning uses [handleRecognizeFrame].
     */
    private fun handleRecognizeText(imagePath: String, result: Result) {
        ocrExecutor.execute {
            try {
                val oriented = loadOrientedBitmap(imagePath)
                val text = recognizeBitmap(oriented, roi = null)
                result.success(text)
            } catch (e: Exception) {
                result.error("OCR_FAILED", e.message ?: "Text recognition failed", null)
            }
        }
    }

    /**
     * Live camera-stream path. Expects NV21 bytes from Dart plus optional
     * normalized ROI (0–1) in upright preview coordinates.
     */
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
                // Y-plane → grayscale bitmap (skips expensive JPEG round-trip).
                var bitmap = nv21YToGrayBitmap(bytes, width, height)
                bitmap = rotateBitmap(bitmap, rotation.toFloat())
                val text = recognizeBitmap(bitmap, roi)
                result.success(text)
            } catch (e: Exception) {
                result.error("OCR_FAILED", e.message ?: "Frame recognition failed", null)
            }
        }
    }

    /**
     * Crop → optional downscale → fast contrast pass → ML Kit.
     * CLAHE + stronger contrast only when the first pass finds no digit run.
     */
    private fun recognizeBitmap(src: Bitmap, roi: FloatArray?): String {
        var cropped = cropRoi(src, roi)
        cropped = downscaleIfNeeded(cropped, maxSide = 960)
        val processed = applyPreprocessing(cropped, contrast = 1.3f, clahe = false)
        var text = runMlKitSync(processed)

        if (!digitRunRegex.containsMatchIn(text.replace(" ", "").replace("-", ""))) {
            val boosted = applyPreprocessing(cropped, contrast = 1.5f, clahe = true)
            text = runMlKitSync(boosted)
        }
        return text
    }

    private fun runMlKitSync(bitmap: Bitmap): String {
        val inputImage = InputImage.fromBitmap(bitmap, 0)
        val task = textRecognizer.process(inputImage)
        // Block on the worker thread only — never on the main thread.
        return com.google.android.gms.tasks.Tasks.await(task).text
    }

    /**
     * Build a grayscale ARGB bitmap from the NV21 Y plane only.
     * Chroma is unused for embossed PAN OCR and JPEG encode/decode is far slower.
     */
    private fun nv21YToGrayBitmap(nv21: ByteArray, width: Int, height: Int): Bitmap {
        val pixels = IntArray(width * height)
        val yCount = width * height
        val limit = min(yCount, nv21.size)
        for (i in 0 until limit) {
            val y = nv21[i].toInt() and 0xFF
            pixels[i] = -0x1000000 or (y shl 16) or (y shl 8) or y
        }
        return Bitmap.createBitmap(pixels, width, height, Bitmap.Config.ARGB_8888)
    }

    private fun downscaleIfNeeded(src: Bitmap, maxSide: Int): Bitmap {
        val longSide = max(src.width, src.height)
        if (longSide <= maxSide) return src
        val scale = maxSide.toFloat() / longSide
        val w = max(1, (src.width * scale).toInt())
        val h = max(1, (src.height * scale).toInt())
        return Bitmap.createScaledBitmap(src, w, h, true)
    }

    private fun rotateBitmap(src: Bitmap, degrees: Float): Bitmap {
        if (degrees == 0f) return src
        val matrix = Matrix().apply { postRotate(degrees) }
        return Bitmap.createBitmap(src, 0, 0, src.width, src.height, matrix, true)
    }

    /**
     * Crop [src] using a normalized ROI (left, top, width, height in 0–1)
     * expressed in upright image coordinates (after rotation).
     */
    private fun cropRoi(src: Bitmap, roi: FloatArray?): Bitmap {
        if (roi == null) return src
        val left = (roi[0] * src.width).toInt().coerceIn(0, src.width - 1)
        val top = (roi[1] * src.height).toInt().coerceIn(0, src.height - 1)
        val width = (roi[2] * src.width).toInt().coerceAtLeast(1)
        val height = (roi[3] * src.height).toInt().coerceAtLeast(1)
        val w = min(width, src.width - left)
        val h = min(height, src.height - top)
        if (w < 16 || h < 16) return src
        return Bitmap.createBitmap(src, left, top, w, h)
    }

    private fun loadOrientedBitmap(imagePath: String): Bitmap {
        val raw = BitmapFactory.decodeFile(imagePath)
            ?: throw IOException("BitmapFactory returned null for $imagePath")

        val exif = ExifInterface(imagePath)
        val orientation = exif.getAttributeInt(
            ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL
        )
        val degrees = when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> 90f
            ExifInterface.ORIENTATION_ROTATE_180 -> 180f
            ExifInterface.ORIENTATION_ROTATE_270 -> 270f
            else -> return raw
        }
        return rotateBitmap(raw, degrees)
    }

    /**
     * Grayscale → optional tile CLAHE → global contrast → mild unsharp via
     * a second pass sharpen kernel approximation (contrast edge boost).
     */
    private fun applyPreprocessing(
        src: Bitmap,
        contrast: Float,
        clahe: Boolean,
    ): Bitmap {
        val gray = toGrayscale(src, contrast)
        return if (clahe) applyClahe(gray, tileSize = 8, clipLimit = 2.5f) else gray
    }

    private fun toGrayscale(src: Bitmap, contrast: Float): Bitmap {
        val out = Bitmap.createBitmap(src.width, src.height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        val c = contrast
        val b = -0.03f * 255f
        val rW = 0.299f * c
        val gW = 0.587f * c
        val bW = 0.114f * c
        val cm = ColorMatrix(
            floatArrayOf(
                rW, gW, bW, 0f, b,
                rW, gW, bW, 0f, b,
                rW, gW, bW, 0f, b,
                0f, 0f, 0f, 1f, 0f,
            )
        )
        val paint = Paint().apply { colorFilter = ColorMatrixColorFilter(cm) }
        canvas.drawBitmap(src, 0f, 0f, paint)
        return out
    }

    /**
     * Lightweight CLAHE-style local contrast: equalize luminance histograms
     * per tile with a clip limit, then bilinear-blend neighbouring tiles.
     * Recovers embossed digits under specular glare better than global contrast.
     */
    private fun applyClahe(src: Bitmap, tileSize: Int, clipLimit: Float): Bitmap {
        val w = src.width
        val h = src.height
        if (w < tileSize * 2 || h < tileSize * 2) return src

        val pixels = IntArray(w * h)
        src.getPixels(pixels, 0, w, 0, 0, w, h)

        val tilesX = tileSize
        val tilesY = tileSize
        val tileW = max(1, w / tilesX)
        val tileH = max(1, h / tilesY)

        // Build CDF lookup per tile (256 bins).
        val luts = Array(tilesY) { Array(tilesX) { IntArray(256) } }

        for (ty in 0 until tilesY) {
            for (tx in 0 until tilesX) {
                val x0 = tx * tileW
                val y0 = ty * tileH
                val x1 = if (tx == tilesX - 1) w else x0 + tileW
                val y1 = if (ty == tilesY - 1) h else y0 + tileH
                val hist = IntArray(256)
                var count = 0
                for (y in y0 until y1) {
                    val row = y * w
                    for (x in x0 until x1) {
                        hist[Color.red(pixels[row + x])]++
                        count++
                    }
                }
                if (count == 0) continue

                // Clip histogram.
                val clip = max(1, (clipLimit * count / 256f).toInt())
                var clipped = 0
                for (i in 0 until 256) {
                    if (hist[i] > clip) {
                        clipped += hist[i] - clip
                        hist[i] = clip
                    }
                }
                val redistribute = clipped / 256
                val remainder = clipped % 256
                for (i in 0 until 256) hist[i] += redistribute
                for (i in 0 until remainder) hist[i]++

                val lut = luts[ty][tx]
                var cdf = 0
                var cdfMin = 0
                var foundMin = false
                for (i in 0 until 256) {
                    cdf += hist[i]
                    if (!foundMin && cdf > 0) {
                        cdfMin = cdf
                        foundMin = true
                    }
                    val denom = (count - cdfMin).coerceAtLeast(1)
                    lut[i] = (((cdf - cdfMin).toFloat() / denom) * 255f)
                        .toInt()
                        .coerceIn(0, 255)
                }
            }
        }

        // Bilinear interpolate LUT values across tiles.
        val outPixels = IntArray(w * h)
        for (y in 0 until h) {
            val ty = min(tilesY - 1, y / tileH)
            val ty1 = min(tilesY - 1, ty + 1)
            val fy = if (ty == ty1) 0f else {
                ((y % tileH).toFloat() / tileH)
            }
            for (x in 0 until w) {
                val tx = min(tilesX - 1, x / tileW)
                val tx1 = min(tilesX - 1, tx + 1)
                val fx = if (tx == tx1) 0f else {
                    ((x % tileW).toFloat() / tileW)
                }
                val v = Color.red(pixels[y * w + x])
                val v00 = luts[ty][tx][v]
                val v10 = luts[ty][tx1][v]
                val v01 = luts[ty1][tx][v]
                val v11 = luts[ty1][tx1][v]
                val top = v00 * (1 - fx) + v10 * fx
                val bot = v01 * (1 - fx) + v11 * fx
                val mapped = (top * (1 - fy) + bot * fy).toInt().coerceIn(0, 255)
                outPixels[y * w + x] = Color.argb(255, mapped, mapped, mapped)
            }
        }

        val out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        out.setPixels(outPixels, 0, w, 0, 0, w, h)
        return out
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

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
