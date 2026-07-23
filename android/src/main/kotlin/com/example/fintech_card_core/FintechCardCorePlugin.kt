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
import kotlin.math.sqrt
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
                // OpenCV-warped gray8 canvas from Dart FFI (Phase 1 output).
                "ocr/recognizeGray8" -> handleRecognizeGray8(call, result)
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
     * OCR a tightly packed 8-bit grayscale buffer produced by the OpenCV
     * Phase-1 pipeline (perspective-corrected + CLAHE, often PAN-banded).
     *
     * Light passes only — heavy multi-pass preprocessing already ran in C++.
     */
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
                val bitmap = gray8ToBitmap(bytes, width, height)
                val candidates = ArrayList<String>(3)
                candidates.add(runMlKitSync(bitmap))
                if (scoreOcrText(candidates.last()) < 1000) {
                    candidates.add(runMlKitSync(invertGray(bitmap)))
                    candidates.add(runMlKitSync(applyUnsharp(bitmap)))
                }
                result.success(joinPanCandidates(candidates))
            } catch (e: Exception) {
                result.error("OCR_FAILED", e.message ?: "Gray8 recognition failed", null)
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
     * Crop → multi-pass OCR → return candidate texts.
     *
     * Passes target different card classes without colour hardcoding:
     * 1) mild contrast (high-contrast flat)
     * 2) CLAHE + unsharp (glare / weak print)
     * 3) high-pass residual ± invert (same-hue emboss relief)
     * 4) adaptive threshold only on bright faces (white/pastel flat print)
     * 5) centre PAN strip + high-pass (extra emboss chance, full card kept too)
     *
     * A single pass can misread embossed digits *systematically* (7→1, 6→5,
     * 4→1 stroke loss) and the wrong string may even pass Luhn, so:
     * - early exit requires TWO independent passes to agree on a digit run;
     * - all PAN-bearing pass outputs are returned joined with " ; " so the
     *   Dart layer can cross-check conflicting readings.
     */
    private fun recognizeBitmap(src: Bitmap, roi: FloatArray?): String {
        var cropped = cropRoi(src, roi)
        cropped = downscaleIfNeeded(cropped, maxSide = 1600)
        val mean = meanLuminance(cropped)
        val candidates = ArrayList<String>(8)

        fun consider(bitmap: Bitmap) {
            candidates.add(runMlKitSync(bitmap))
        }

        consider(applyPreprocessing(cropped, contrast = 1.3f, clahe = false, unsharp = false))
        consider(applyPreprocessing(cropped, contrast = 1.55f, clahe = true, unsharp = true))
        if (hasCrossPassAgreement(candidates)) return joinPanCandidates(candidates)

        consider(applyHighPass(cropped, amount = 2.8f, invert = false))
        consider(applyHighPass(cropped, amount = 2.8f, invert = true))
        if (hasCrossPassAgreement(candidates)) return joinPanCandidates(candidates)

        // Bright flat print (white/pastel) — threshold helps; hurts emboss shadows.
        if (mean > 150.0) {
            consider(applyAdaptiveThreshold(cropped))
            consider(
                applyPreprocessing(cropped, contrast = 1.9f, clahe = true, unsharp = true),
            )
        }

        val centre = cropCentreBand(cropped)
        if (centre !== cropped) {
            consider(applyHighPass(centre, amount = 3.0f, invert = false))
            consider(applyHighPass(centre, amount = 3.0f, invert = true))
            consider(applyPreprocessing(centre, contrast = 1.6f, clahe = true, unsharp = true))
            if (mean > 150.0) {
                consider(applyAdaptiveThreshold(centre))
            }
        }

        return joinPanCandidates(candidates)
    }

    private fun scoreOcrText(text: String): Int {
        val compact = text.replace(" ", "").replace("-", "")
        val match = digitRunRegex.find(compact)
        return if (match != null) 1000 + match.value.length else compact.length
    }

    private fun pickBestOcrText(candidates: List<String>): String {
        if (candidates.isEmpty()) return ""
        return candidates.maxBy { scoreOcrText(it) }
    }

    /** Longest 13–19 digit run in [text] with separators stripped. */
    private fun longestDigitRun(text: String): String? {
        val compact = text.replace(" ", "").replace("-", "")
        return digitRunRegex.findAll(compact).maxByOrNull { it.value.length }?.value
    }

    /**
     * True when two *different* preprocessing passes read the same PAN-length
     * digit run. One pass agreeing with itself is worthless against
     * systematic emboss misreads; two independent styles agreeing is strong.
     */
    private fun hasCrossPassAgreement(candidates: List<String>): Boolean {
        val runs = candidates.mapNotNull { longestDigitRun(it) }.filter { it.length >= 15 }
        return runs.groupingBy { it }.eachCount().values.any { it >= 2 }
    }

    /**
     * Every pass output containing a PAN-shaped digit run, joined with " ; ".
     * The ';' separator breaks the Dart PAN regexes between passes so
     * conflicting readings stay distinct and can be arbitrated in Dart
     * (stroke-loss heuristic + consensus) instead of trusting one pass.
     */
    private fun joinPanCandidates(candidates: List<String>): String {
        val useful = candidates.filter { scoreOcrText(it) >= 1000 }.distinct()
        if (useful.isEmpty()) return pickBestOcrText(candidates)
        return useful.joinToString(" ; ")
    }

    private fun meanLuminance(src: Bitmap): Double {
        val w = src.width
        val h = src.height
        if (w < 2 || h < 2) return 128.0
        val stepX = max(1, w / 40)
        val stepY = max(1, h / 40)
        val pixels = IntArray(w * h)
        src.getPixels(pixels, 0, w, 0, 0, w, h)
        var sum = 0L
        var count = 0
        var y = 0
        while (y < h) {
            var x = 0
            val row = y * w
            while (x < w) {
                sum += Color.red(pixels[row + x])
                count++
                x += stepX
            }
            y += stepY
        }
        return if (count == 0) 128.0 else sum.toDouble() / count
    }

    /** Middle horizontal strip where PANs usually sit (relative to upright card). */
    private fun cropCentreBand(src: Bitmap): Bitmap {
        val top = (src.height * 0.30f).toInt().coerceIn(0, src.height - 1)
        val height = (src.height * 0.40f).toInt().coerceAtLeast(16)
        val h = min(height, src.height - top)
        val left = (src.width * 0.04f).toInt().coerceIn(0, src.width - 1)
        val width = (src.width * 0.92f).toInt().coerceAtLeast(16)
        val w = min(width, src.width - left)
        if (w < 32 || h < 24) return src
        return Bitmap.createBitmap(src, left, top, w, h)
    }

    /**
     * High-pass residual: amplifies emboss relief shadows that global contrast
     * flattens. [invert] flips polarity for light-vs-dark lighting angles.
     */
    private fun applyHighPass(src: Bitmap, amount: Float, invert: Boolean): Bitmap {
        val gray = toGrayscale(src, contrast = 1.15f)
        val blur = boxBlur(gray, radius = 4)
        val w = gray.width
        val h = gray.height
        val a = gray.copyPixels()
        val b = blur.copyPixels()
        val outPixels = IntArray(w * h)
        for (i in 0 until w * h) {
            val g = Color.red(a[i])
            val bv = Color.red(b[i])
            var v = (128 + amount * (g - bv)).toInt()
            if (invert) v = 255 - v
            v = v.coerceIn(0, 255)
            outPixels[i] = Color.argb(255, v, v, v)
        }
        val out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        out.setPixels(outPixels, 0, w, 0, 0, w, h)
        return applyUnsharp(out)
    }

    private fun Bitmap.copyPixels(): IntArray {
        val px = IntArray(width * height)
        getPixels(px, 0, width, 0, 0, width, height)
        return px
    }

    private fun boxBlur(src: Bitmap, radius: Int): Bitmap {
        val w = src.width
        val h = src.height
        if (radius < 1 || w < 3 || h < 3) return src
        val srcPx = src.copyPixels()
        val tmp = IntArray(w * h)
        val out = IntArray(w * h)
        val div = radius * 2 + 1

        // Horizontal.
        for (y in 0 until h) {
            for (x in 0 until w) {
                var sum = 0
                for (k in -radius..radius) {
                    val xx = (x + k).coerceIn(0, w - 1)
                    sum += Color.red(srcPx[y * w + xx])
                }
                val v = sum / div
                tmp[y * w + x] = Color.argb(255, v, v, v)
            }
        }
        // Vertical.
        for (y in 0 until h) {
            for (x in 0 until w) {
                var sum = 0
                for (k in -radius..radius) {
                    val yy = (y + k).coerceIn(0, h - 1)
                    sum += Color.red(tmp[yy * w + x])
                }
                val v = sum / div
                out[y * w + x] = Color.argb(255, v, v, v)
            }
        }
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        bmp.setPixels(out, 0, w, 0, 0, w, h)
        return bmp
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
        return gray8ToBitmap(nv21, width, height)
    }

    /** Tightly packed gray8 rows → ARGB_8888 (R=G=B=luma). */
    private fun gray8ToBitmap(gray: ByteArray, width: Int, height: Int): Bitmap {
        val pixels = IntArray(width * height)
        val limit = min(width * height, gray.size)
        for (i in 0 until limit) {
            val y = gray[i].toInt() and 0xFF
            pixels[i] = -0x1000000 or (y shl 16) or (y shl 8) or y
        }
        return Bitmap.createBitmap(pixels, width, height, Bitmap.Config.ARGB_8888)
    }

    private fun invertGray(src: Bitmap): Bitmap {
        val w = src.width
        val h = src.height
        val px = src.copyPixels()
        for (i in px.indices) {
            val y = 255 - Color.red(px[i])
            px[i] = Color.argb(255, y, y, y)
        }
        val out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        out.setPixels(px, 0, w, 0, 0, w, h)
        return out
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
     * Grayscale + contrast → optional CLAHE → optional unsharp (emboss edges).
     */
    private fun applyPreprocessing(
        src: Bitmap,
        contrast: Float,
        clahe: Boolean,
        unsharp: Boolean,
    ): Bitmap {
        var out = toGrayscale(src, contrast)
        if (clahe) out = applyClahe(out, tileSize = 8, clipLimit = 2.5f)
        if (unsharp) out = applyUnsharp(out)
        return out
    }

    /** 3×3 sharpen kernel to lift same-hue emboss relief shadows. */
    private fun applyUnsharp(src: Bitmap): Bitmap {
        val w = src.width
        val h = src.height
        if (w < 3 || h < 3) return src

        val pixels = IntArray(w * h)
        src.getPixels(pixels, 0, w, 0, 0, w, h)
        val outPixels = IntArray(w * h)

        for (y in 0 until h) {
            for (x in 0 until w) {
                val c = Color.red(pixels[y * w + x])
                if (x == 0 || y == 0 || x == w - 1 || y == h - 1) {
                    outPixels[y * w + x] = Color.argb(255, c, c, c)
                    continue
                }
                val n = Color.red(pixels[(y - 1) * w + x])
                val s = Color.red(pixels[(y + 1) * w + x])
                val e = Color.red(pixels[y * w + x + 1])
                val west = Color.red(pixels[y * w + x - 1])
                val sharpened = (c * 5 - n - s - e - west).coerceIn(0, 255)
                outPixels[y * w + x] = Color.argb(255, sharpened, sharpened, sharpened)
            }
        }

        val out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        out.setPixels(outPixels, 0, w, 0, 0, w, h)
        return out
    }

    /**
     * Local mean adaptive threshold for flat low-contrast printed digits.
     * Block size ~15% of the shorter side (odd, ≥ 15).
     */
    private fun applyAdaptiveThreshold(src: Bitmap): Bitmap {
        val gray = toGrayscale(src, contrast = 1.4f)
        val w = gray.width
        val h = gray.height
        if (w < 16 || h < 16) return gray

        val pixels = IntArray(w * h)
        gray.getPixels(pixels, 0, w, 0, 0, w, h)
        val lum = IntArray(w * h) { Color.red(pixels[it]) }

        // Integral image for O(1) block means.
        val integral = LongArray((w + 1) * (h + 1))
        for (y in 1..h) {
            var rowSum = 0L
            for (x in 1..w) {
                rowSum += lum[(y - 1) * w + (x - 1)]
                integral[y * (w + 1) + x] = integral[(y - 1) * (w + 1) + x] + rowSum
            }
        }

        var block = (min(w, h) * 0.15).toInt()
        if (block % 2 == 0) block++
        block = block.coerceIn(15, 63)
        val half = block / 2
        val t = 8 // bias below local mean → ink darker than background

        val outPixels = IntArray(w * h)
        for (y in 0 until h) {
            for (x in 0 until w) {
                val x0 = (x - half).coerceAtLeast(0)
                val y0 = (y - half).coerceAtLeast(0)
                val x1 = (x + half).coerceAtMost(w - 1)
                val y1 = (y + half).coerceAtMost(h - 1)
                val count = (x1 - x0 + 1) * (y1 - y0 + 1)
                val sum = integral[(y1 + 1) * (w + 1) + (x1 + 1)] -
                    integral[y0 * (w + 1) + (x1 + 1)] -
                    integral[(y1 + 1) * (w + 1) + x0] +
                    integral[y0 * (w + 1) + x0]
                val mean = (sum / count).toInt()
                val v = if (lum[y * w + x] < mean - t) 0 else 255
                outPixels[y * w + x] = Color.argb(255, v, v, v)
            }
        }

        val out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        out.setPixels(outPixels, 0, w, 0, 0, w, h)
        return out
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
