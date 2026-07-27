package com.shakhob.fintech_card_core

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.util.Log
import com.shakhob.fintech_card_core.cardscan.SsdOcrEngine

/**
 * Headless CardScan OCR bridge — wraps [SsdOcrEngine] (getbouncer SSD TFLite, MIT).
 *
 * Returns structured maps for Dart: `{pan, expiryDate, confidence, engine}`.
 */
class CardScanOcrBridge(context: Context) : AutoCloseable {

    private val appContext = context.applicationContext
    private var engine: SsdOcrEngine? = null

    @Synchronized
    fun ensureInitialized() {
        if (engine == null) {
            engine = SsdOcrEngine(appContext)
            Log.i(TAG, "CardScan SSD OCR engine initialized")
        }
    }

    /**
     * Recognize PAN (+ optional expiry) from an upright ARGB bitmap (already
     * rotated / ROI-cropped by the caller).
     */
    fun recognizeBitmap(bitmap: Bitmap): Map<String, Any?> {
        ensureInitialized()
        val result = engine!!.recognize(bitmap)
        return mapOf(
            "pan" to result.pan,
            "expiryDate" to result.expiryDate,
            "confidence" to result.confidence.toDouble(),
            "engine" to "cardscan_ssd",
        )
    }

    /**
     * NV21 camera frame → upright bitmap → OCR.
     *
     * [roi] is normalized upright preview coords: left, top, width, height.
     */
    fun recognizeNv21(
        nv21: ByteArray,
        width: Int,
        height: Int,
        rotationDegrees: Int,
        roi: FloatArray?,
    ): Map<String, Any?> {
        var bitmap = nv21ToBitmap(nv21, width, height)
        if (rotationDegrees != 0) {
            val rotated = rotateBitmap(bitmap, rotationDegrees.toFloat())
            if (rotated !== bitmap) {
                bitmap.recycle()
                bitmap = rotated
            }
        }
        if (roi != null) {
            val cropped = cropRoi(bitmap, roi)
            if (cropped !== bitmap) {
                bitmap.recycle()
                bitmap = cropped
            }
        }
        return try {
            recognizeBitmap(bitmap)
        } finally {
            bitmap.recycle()
        }
    }

    /**
     * Gray8 (OpenCV Phase-1) canvas → OCR.
     */
    fun recognizeGray8(bytes: ByteArray, width: Int, height: Int): Map<String, Any?> {
        val bitmap = gray8ToBitmap(bytes, width, height)
        return try {
            recognizeBitmap(bitmap)
        } finally {
            bitmap.recycle()
        }
    }

    @Synchronized
    override fun close() {
        engine?.close()
        engine = null
    }

    companion object {
        private const val TAG = "CardScanOcrBridge"

        private fun nv21ToBitmap(nv21: ByteArray, width: Int, height: Int): Bitmap {
            // Y-plane only → grayscale ARGB. Avoids JPEG encode/decode (~10–40ms/frame).
            // SSD OCR was trained on RGB; R=G=B luminance is sufficient for digit boxes.
            return gray8ToBitmap(nv21, width, height)
        }

        private fun gray8ToBitmap(bytes: ByteArray, width: Int, height: Int): Bitmap {
            val pixels = IntArray(width * height)
            val limit = minOf(bytes.size, width * height)
            for (i in 0 until limit) {
                val v = bytes[i].toInt() and 0xFF
                pixels[i] = (0xFF shl 24) or (v shl 16) or (v shl 8) or v
            }
            return Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also {
                it.setPixels(pixels, 0, width, 0, 0, width, height)
            }
        }

        private fun rotateBitmap(src: Bitmap, degrees: Float): Bitmap {
            if (degrees % 360f == 0f) return src
            val m = Matrix().apply { postRotate(degrees) }
            return Bitmap.createBitmap(src, 0, 0, src.width, src.height, m, true)
        }

        private fun cropRoi(src: Bitmap, roi: FloatArray): Bitmap {
            val left = (roi[0] * src.width).toInt().coerceIn(0, src.width - 1)
            val top = (roi[1] * src.height).toInt().coerceIn(0, src.height - 1)
            val width = (roi[2] * src.width).toInt().coerceAtLeast(1)
            val height = (roi[3] * src.height).toInt().coerceAtLeast(1)
            val w = minOf(width, src.width - left)
            val h = minOf(height, src.height - top)
            if (w < 16 || h < 16) return src
            return Bitmap.createBitmap(src, left, top, w, h)
        }
    }
}
