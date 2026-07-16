package com.example.fintech_card_core

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
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
import java.io.File
import java.io.IOException

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
     * Run ML Kit on-device text recognition on [imagePath] and return the
     * full recognised text as a single newline-separated string.
     *
     * Before recognition the bitmap goes through a preprocessing pipeline
     * optimised for shiny/embossed payment cards:
     *   1. EXIF-aware load — rotates the bitmap to match the screen orientation.
     *   2. ROI crop — crops to the card-frame area (88 % of width, ISO 7810
     *      aspect ratio, centered) to exclude background noise.
     *   3. Grayscale — removes gold/silver color noise around digit edges.
     *   4. Contrast boost — compresses specular highlights so glare does not
     *      fully erase individual digit segments.
     *
     * Uses the bundled Latin recogniser (no network, no model download).
     */
    private fun handleRecognizeText(imagePath: String, result: Result) {
        val file = File(imagePath)
        if (!file.exists()) {
            result.error("OCR_FAILED", "Image file not found: $imagePath", null)
            return
        }

        // ── 1. Load with EXIF rotation ────────────────────────────────────────
        val oriented = try {
            loadOrientedBitmap(imagePath)
        } catch (e: Exception) {
            result.error("OCR_FAILED", "Could not load image: ${e.message}", null)
            return
        }

        // ── 2. Grayscale + contrast preprocessing ─────────────────────────────
        // No ROI crop: the camera image aspect ratio (4:3 or 16:9) differs from
        // the screen aspect ratio (~19.5:9), so a screen-derived crop rect does
        // not map correctly to camera image coordinates. Cropping to the card-frame
        // formula caused the PAN to be cut off on off-centre or aspect-mismatched
        // captures. Processing the full (EXIF-rotated) image is the safe approach.
        val processedBitmap = applyPreprocessing(oriented)

        // InputImage.fromBitmap with rotation = 0 (already corrected by EXIF load)
        val inputImage = InputImage.fromBitmap(processedBitmap, 0)

        val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
        recognizer.process(inputImage)
            .addOnSuccessListener { visionText ->
                result.success(visionText.text)
            }
            .addOnFailureListener { e ->
                result.error("OCR_FAILED", e.message ?: "Text recognition failed", null)
            }
    }

    /**
     * Decode [imagePath] as a Bitmap and apply the rotation indicated by the
     * file's EXIF orientation tag so that the resulting bitmap is upright
     * (matching what the user sees on screen).
     */
    private fun loadOrientedBitmap(imagePath: String): Bitmap {
        val raw = BitmapFactory.decodeFile(imagePath)
            ?: throw IOException("BitmapFactory returned null for $imagePath")

        val exif = ExifInterface(imagePath)
        val orientation = exif.getAttributeInt(
            ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL
        )
        val degrees = when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90  -> 90f
            ExifInterface.ORIENTATION_ROTATE_180 -> 180f
            ExifInterface.ORIENTATION_ROTATE_270 -> 270f
            else -> return raw
        }
        val matrix = android.graphics.Matrix().apply { postRotate(degrees) }
        return Bitmap.createBitmap(raw, 0, 0, raw.width, raw.height, matrix, true)
    }

    /**
     * Apply a grayscale + moderate contrast-boost ColorMatrix to [src] and
     * return the result as a new ARGB_8888 bitmap of the same dimensions.
     *
     * Grayscale (rec. 601 weights) removes gold/silver color noise that creates
     * false luminance gradients around embossed digit edges.
     *
     * Contrast 1.3× (previously 1.6×) improves separation between embossing
     * shadows and glare hotspots without clipping bright areas so aggressively
     * that non-shiny cards get artefacts around digit boundaries.
     */
    private fun applyPreprocessing(src: Bitmap): Bitmap {
        val out = Bitmap.createBitmap(src.width, src.height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)

        // Combined grayscale + contrast matrix.
        // Row format: [ R_scale  G_scale  B_scale  A_scale  offset ]
        // Grayscale weights (rec. 601): R=0.299, G=0.587, B=0.114, scaled by contrast.
        val c = 1.3f           // contrast multiplier (moderate — avoids clipping)
        val b = -0.03f * 255f  // slight brightness shift to counter glare
        val rW = 0.299f * c; val gW = 0.587f * c; val bW = 0.114f * c
        val cm = ColorMatrix(floatArrayOf(
            rW,  gW,  bW,  0f, b,
            rW,  gW,  bW,  0f, b,
            rW,  gW,  bW,  0f, b,
            0f,  0f,  0f,  1f, 0f,
        ))

        val paint = Paint().apply { colorFilter = ColorMatrixColorFilter(cm) }
        canvas.drawBitmap(src, 0f, 0f, paint)
        return out
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private fun sendEvent(type: String, message: String?) {
        val payload = mutableMapOf<String, Any>("type" to type)
        if (message != null) payload["message"] = message
        activity?.runOnUiThread { eventSink?.success(payload) }
    }

    private fun IsoDep.safeClose() {
        try { close() } catch (_: Exception) {}
    }
}
