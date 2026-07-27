package com.shakhob.fintech_card_core.cardscan

import android.content.Context
import android.graphics.Bitmap
import android.graphics.RectF
import android.util.Size
import org.tensorflow.lite.Interpreter
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.MappedByteBuffer
import java.nio.channels.FileChannel
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Headless SSD PAN OCR engine ported from getbouncer/cardscan-android
 * `scan-payment` SSDOcr (MIT). Bundled model: assets/cardscan/darknite_1_1_1_16.tflite
 */
class SsdOcrEngine(context: Context) : AutoCloseable {

    data class Detection(val rect: RectF, val confidence: Float, val label: Int)

    data class Result(
        val pan: String?,
        val expiryDate: String?,
        val confidence: Float,
        val boxes: List<Detection>,
    )

    private val interpreter: Interpreter
    private val priors: Array<FloatArray>

    init {
        val model = loadModelFile(context, MODEL_ASSET)
        val options = Interpreter.Options().setNumThreads(4)
        interpreter = Interpreter(model, options)
        priors = combinePriors(TRAINED_IMAGE_SIZE)
    }

    fun recognize(bitmap: Bitmap): Result {
        val scaled = Bitmap.createScaledBitmap(
            bitmap,
            TRAINED_IMAGE_SIZE.width,
            TRAINED_IMAGE_SIZE.height,
            true,
        )
        val input = bitmapToMlBuffer(scaled, IMAGE_MEAN, IMAGE_STD)
        if (scaled !== bitmap) scaled.recycle()

        val outputClasses = arrayOf(FloatArray(NUM_CLASS))
        val outputLocations = arrayOf(FloatArray(NUM_LOC))
        val outputs = mapOf(0 to outputClasses, 1 to outputLocations)
        interpreter.runForMultipleInputsOutputs(arrayOf(input), outputs)

        val boxes = rearrangeOcrArray(
            locations = outputLocations,
            featureMapSizes = FEATURE_MAP_SIZES,
            numberOfPriors = NUM_OF_PRIORS_PER_ACTIVATION,
            locationsPerPrior = NUM_OF_COORDINATES,
        ).reshape(NUM_OF_COORDINATES)
        boxes.adjustLocations(priors, CENTER_VARIANCE, SIZE_VARIANCE)
        boxes.forEach { it.toRectForm() }

        val scores = rearrangeOcrArray(
            locations = outputClasses,
            featureMapSizes = FEATURE_MAP_SIZES,
            numberOfPriors = NUM_OF_PRIORS_PER_ACTIVATION,
            locationsPerPrior = NUM_OF_CLASSES,
        ).reshape(NUM_OF_CLASSES)
        scores.forEach { it.softMax() }

        val allDetections = extractPredictions(
            scores = scores,
            boxes = boxes,
            probabilityThreshold = PROB_THRESHOLD,
            intersectionOverUnionThreshold = IOU_THRESHOLD,
            limit = LIMIT,
            classifierToLabel = { if (it == 10) 0 else it },
        )
        val detected = determineLayoutAndFilter(allDetections, VERTICAL_THRESHOLD)

        val pan = detected.joinToString("") { it.label.toString() }
            .takeIf { it.length in 12..19 }
        val meanConf = if (detected.isEmpty()) {
            0f
        } else {
            detected.map { it.confidence }.average().toFloat()
        }
        val expiry = guessExpiryFromDetections(allDetections, panBoxes = detected)

        return Result(
            pan = pan,
            expiryDate = expiry,
            confidence = meanConf,
            boxes = detected,
        )
    }

    override fun close() {
        interpreter.close()
    }

    companion object {
        private const val MODEL_ASSET = "cardscan/darknite_1_1_1_16.tflite"
        private const val IMAGE_MEAN = 127.5f
        private const val IMAGE_STD = 128.5f
        private const val NUM_OF_PRIORS = 3420
        private const val NUM_OF_PRIORS_PER_ACTIVATION = 3
        private const val NUM_OF_CLASSES = 11
        private const val NUM_OF_COORDINATES = 4
        private const val NUM_LOC = NUM_OF_COORDINATES * NUM_OF_PRIORS
        private const val NUM_CLASS = NUM_OF_CLASSES * NUM_OF_PRIORS
        private const val PROB_THRESHOLD = 0.50f
        private const val IOU_THRESHOLD = 0.50f
        private const val CENTER_VARIANCE = 0.1f
        private const val SIZE_VARIANCE = 0.2f
        private const val LIMIT = 20
        private const val VERTICAL_THRESHOLD = 2.0f
        private const val QUICK_READ_LENGTH = 16
        private const val QUICK_READ_GROUP_LENGTH = 4

        val TRAINED_IMAGE_SIZE = Size(600, 375)

        private val FEATURE_MAP_SIZES = OcrFeatureMapSizes(38, 24, 19, 12)

        private fun loadModelFile(context: Context, assetPath: String): MappedByteBuffer {
            val fd = context.assets.openFd(assetPath)
            try {
                FileInputStream(fd.fileDescriptor).channel.use { channel ->
                    return channel.map(
                        FileChannel.MapMode.READ_ONLY,
                        fd.startOffset,
                        fd.declaredLength,
                    )
                }
            } finally {
                fd.close()
            }
        }

        private fun bitmapToMlBuffer(bitmap: Bitmap, mean: Float, std: Float): ByteBuffer {
            val w = bitmap.width
            val h = bitmap.height
            val pixels = IntArray(w * h)
            bitmap.getPixels(pixels, 0, w, 0, 0, w, h)
            val buf = ByteBuffer.allocateDirect(w * h * 3 * 4).order(ByteOrder.nativeOrder())
            for (pixel in pixels) {
                buf.putFloat(((pixel shr 16 and 0xFF) - mean) / std)
                buf.putFloat(((pixel shr 8 and 0xFF) - mean) / std)
                buf.putFloat(((pixel and 0xFF) - mean) / std)
            }
            buf.rewind()
            return buf
        }

        /**
         * Expiry heuristic: digit boxes in the lower-right that are not part of the PAN line.
         */
        private fun guessExpiryFromDetections(
            all: List<Detection>,
            panBoxes: List<Detection>,
        ): String? {
            if (all.isEmpty()) return null
            val panSet = panBoxes.toSet()
            val candidates = all
                .filter { it !in panSet }
                .filter { it.rect.centerX() > 0.45f && it.rect.centerY() > 0.45f }
                .sortedBy { it.rect.left }
            if (candidates.size < 4) return null

            val digits = candidates.map { it.label }
            // Prefer contiguous 4 digits as MMYY.
            for (i in 0..digits.size - 4) {
                val month = "${digits[i]}${digits[i + 1]}"
                val year2 = "${digits[i + 2]}${digits[i + 3]}"
                val monthInt = month.toIntOrNull() ?: continue
                if (monthInt in 1..12) {
                    return "$month/$year2"
                }
            }
            // Five digits with a mistaken '/' → '1' in the middle.
            if (digits.size >= 5) {
                for (i in 0..digits.size - 5) {
                    if (digits[i + 2] != 1) continue
                    val month = "${digits[i]}${digits[i + 1]}"
                    val year2 = "${digits[i + 3]}${digits[i + 4]}"
                    val monthInt = month.toIntOrNull() ?: continue
                    if (monthInt in 1..12) return "$month/$year2"
                }
            }
            return null
        }
    }

    // ── SSD helpers (from getbouncer scan-framework / scan-payment) ─────────

    private data class OcrFeatureMapSizes(
        val layerOneWidth: Int,
        val layerOneHeight: Int,
        val layerTwoWidth: Int,
        val layerTwoHeight: Int,
    )

    private fun rearrangeOcrArray(
        locations: Array<FloatArray>,
        featureMapSizes: OcrFeatureMapSizes,
        numberOfPriors: Int,
        locationsPerPrior: Int,
    ): Array<FloatArray> {
        val total =
            featureMapSizes.layerOneWidth * featureMapSizes.layerOneHeight *
                numberOfPriors * locationsPerPrior +
                featureMapSizes.layerTwoWidth * featureMapSizes.layerTwoHeight *
                numberOfPriors * locationsPerPrior
        val rearranged = Array(1) { FloatArray(total) }
        val heights = arrayOf(featureMapSizes.layerOneHeight, featureMapSizes.layerTwoHeight)
        val widths = arrayOf(featureMapSizes.layerOneWidth, featureMapSizes.layerTwoWidth)
        var offset = 0
        for (layer in heights.indices) {
            val height = heights[layer]
            val width = widths[layer]
            val totalForLayer = height * width * numberOfPriors * locationsPerPrior
            val stepsForLoop = height - 1
            var i = 0
            var step = 0
            while (i < totalForLayer) {
                while (step < height) {
                    var j = step
                    while (j < totalForLayer - stepsForLoop + step) {
                        rearranged[0][offset + i] = locations[0][offset + j]
                        i++
                        j += height
                    }
                    step++
                }
                offset += totalForLayer
            }
        }
        return rearranged
    }

    private fun Array<FloatArray>.reshape(newColumns: Int): Array<FloatArray> {
        val oldRows = size
        val oldColumns = if (isNotEmpty()) this[0].size else 0
        val linearSize = oldRows * oldColumns
        val newRows = linearSize / newColumns + if (linearSize % newColumns != 0) 1 else 0
        var oldRow = 0
        var oldColumn = 0
        return Array(newRows) {
            FloatArray(newColumns) {
                val value = this@reshape[oldRow][oldColumn]
                if (++oldColumn == oldColumns) {
                    oldColumn = 0
                    oldRow++
                }
                value
            }
        }
    }

    private fun Array<FloatArray>.adjustLocations(
        priors: Array<FloatArray>,
        centerVariance: Float,
        sizeVariance: Float,
    ) {
        for (i in indices) {
            val box = this[i]
            val prior = priors[i]
            val cx = box[0] * centerVariance * prior[2] + prior[0]
            val cy = box[1] * centerVariance * prior[3] + prior[1]
            val w = exp(box[2] * sizeVariance) * prior[2]
            val h = exp(box[3] * sizeVariance) * prior[3]
            box[0] = cx
            box[1] = cy
            box[2] = w
            box[3] = h
        }
    }

    private fun FloatArray.toRectForm() {
        val left = this[0] - this[2] / 2
        val top = this[1] - this[3] / 2
        val right = this[0] + this[2] / 2
        val bottom = this[1] + this[3] / 2
        this[0] = left
        this[1] = top
        this[2] = right
        this[3] = bottom
    }

    private fun FloatArray.softMax() {
        val rowSumExp = fold(0f) { acc, v -> acc + exp(v) }
        for (i in indices) {
            this[i] = exp(this[i]) / rowSumExp
        }
    }

    private fun extractPredictions(
        scores: Array<FloatArray>,
        boxes: Array<FloatArray>,
        probabilityThreshold: Float,
        intersectionOverUnionThreshold: Float,
        limit: Int,
        classifierToLabel: (Int) -> Int,
    ): List<Detection> {
        val predictions = mutableListOf<Detection>()
        val classifiersScores = scores.transpose()
        for (classifier in 1 until classifiersScores.size) {
            val classifierScores = classifiersScores[classifier]
            val filteredIndexes = classifierScores.filteredIndexes { it >= probabilityThreshold }
            if (filteredIndexes.isEmpty()) continue
            val filteredScores = classifierScores.filterByIndexes(filteredIndexes)
            val filteredBoxes = boxes.filterByIndexes(filteredIndexes)
            val indexes = hardNms(
                boxes = filteredBoxes,
                probabilities = filteredScores,
                iouThreshold = intersectionOverUnionThreshold,
                limit = limit,
            )
            for (index in indexes) {
                val b = filteredBoxes[index]
                predictions.add(
                    Detection(
                        rect = RectF(b[0], b[1], b[2], b[3]),
                        confidence = filteredScores[index],
                        label = classifierToLabel(classifier),
                    ),
                )
            }
        }
        return predictions
    }

    private fun determineLayoutAndFilter(
        detectedBoxes: List<Detection>,
        verticalOffset: Float,
    ): List<Detection> {
        if (detectedBoxes.isEmpty()) return detectedBoxes
        val centers = detectedBoxes.map { it.rect.centerY() }.sorted()
        val heights = detectedBoxes.map { it.rect.height() }.sorted()
        val medianCenter = centers[centers.size / 2]
        val medianHeight = heights[heights.size / 2]
        val aggregateDeviation = centers.sumOf { abs(it - medianCenter).toDouble() }.toFloat()

        if (aggregateDeviation > verticalOffset * medianHeight &&
            detectedBoxes.size == QUICK_READ_LENGTH
        ) {
            val groups = detectedBoxes
                .sortedBy { it.rect.centerY() }
                .chunked(QUICK_READ_GROUP_LENGTH)
                .map { group -> group.sortedBy { it.rect.left } }
            if (groups.size >= 2 &&
                groups[1].first().rect.centerX() < groups[0].last().rect.centerX() &&
                groups[1].last().rect.centerX() > groups[0].first().rect.centerX()
            ) {
                return groups.flatten()
            }
        }

        return detectedBoxes
            .sortedBy { it.rect.left }
            .filter { abs(it.rect.centerY() - medianCenter) <= medianHeight }
    }

    private fun hardNms(
        boxes: Array<FloatArray>,
        probabilities: FloatArray,
        iouThreshold: Float,
        limit: Int,
    ): List<Int> {
        val indexArray = probabilities.indices
            .sortedByDescending { probabilities[it] }
            .take(200)
            .toMutableList()
        val picked = ArrayList<Int>()
        while (indexArray.isNotEmpty()) {
            val current = indexArray.removeAt(0)
            picked.add(current)
            if (picked.size == limit) return picked
            val iterator = indexArray.iterator()
            while (iterator.hasNext()) {
                val next = iterator.next()
                if (iou(boxes[current], boxes[next]) >= iouThreshold) {
                    iterator.remove()
                }
            }
        }
        return picked
    }

    private fun iou(a: FloatArray, b: FloatArray): Float {
        val eps = 0.00001f
        val left = max(a[0], b[0])
        val top = max(a[1], b[1])
        val right = min(a[2], b[2])
        val bottom = min(a[3], b[3])
        val overlap = max(0f, right - left) * max(0f, bottom - top)
        val areaA = max(0f, a[2] - a[0]) * max(0f, a[3] - a[1])
        val areaB = max(0f, b[2] - b[0]) * max(0f, b[3] - b[1])
        return overlap / (areaA + areaB - overlap + eps)
    }

    private fun Array<FloatArray>.transpose(): Array<FloatArray> {
        if (isEmpty()) return this
        val rows = size
        val cols = this[0].size
        return Array(cols) { c -> FloatArray(rows) { r -> this[r][c] } }
    }

    private fun FloatArray.filteredIndexes(predicate: (Float) -> Boolean): IntArray {
        val out = ArrayList<Int>()
        for (i in indices) if (predicate(this[i])) out.add(i)
        return out.toIntArray()
    }

    private fun FloatArray.filterByIndexes(indexes: IntArray) =
        FloatArray(indexes.size) { this[indexes[it]] }

    private inline fun <reified T> Array<T>.filterByIndexes(indexes: IntArray) =
        Array(indexes.size) { this[indexes[it]] }

    private fun combinePriors(trainedImageSize: Size): Array<FloatArray> {
        val one = generatePriors(trainedImageSize, Size(38, 24), Size(16, 16), 14f, 30f, 3f)
        val two = generatePriors(trainedImageSize, Size(19, 12), Size(31, 31), 30f, 45f, 3f)
        return (one + two).also { arr ->
            for (p in arr) {
                for (i in p.indices) p[i] = p[i].coerceIn(0f, 1f)
            }
        }
    }

    private fun generatePriors(
        trainedImageSize: Size,
        featureMapSize: Size,
        shrinkage: Size,
        boxSizeMin: Float,
        boxSizeMax: Float,
        aspectRatio: Float,
    ): Array<FloatArray> {
        val scaleWidth = trainedImageSize.width.toFloat() / shrinkage.width
        val scaleHeight = trainedImageSize.height.toFloat() / shrinkage.height
        val ratio = sqrt(aspectRatio)
        fun prior(column: Int, row: Int, sizeFactor: Float, r: Float) = floatArrayOf(
            (column + 0.5f) / scaleWidth,
            (row + 0.5f) / scaleHeight,
            sizeFactor / trainedImageSize.width,
            sizeFactor / trainedImageSize.height * r,
        )
        return Array(featureMapSize.width * featureMapSize.height * 3) { index ->
            val row = index / 3 / featureMapSize.width
            val column = (index / 3) % featureMapSize.width
            when (index % 3) {
                0 -> prior(column, row, boxSizeMin, 1f)
                1 -> prior(column, row, sqrt(boxSizeMax * boxSizeMin), ratio)
                else -> prior(column, row, boxSizeMin, ratio)
            }
        }
    }
}
