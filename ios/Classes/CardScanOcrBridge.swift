//
//  CardScanOcrBridge.swift
//  fintech_card_core
//
//  Headless wrapper around getbouncer SSD OCR (MIT). No ScanViewController / camera UI.
//

import CoreGraphics
import Foundation
import UIKit

@available(iOS 13.0, *)
final class CardScanOcrBridge {
    static let shared = CardScanOcrBridge()

    private var ocr = OcrDD()
    private var warmedUp = false
    private let lock = NSLock()

    func ensureInitialized() {
        lock.lock()
        defer { lock.unlock() }
        guard !warmedUp else { return }
        // Prefer the plugin framework bundle; model lives in nested resource bundle.
        CSBundle.cardScanBundle = Bundle(for: CardScanOcrBridge.self)
        CSBundle.bundleIdentifier = Bundle(for: CardScanOcrBridge.self).bundleIdentifier
            ?? CSBundle.bundleIdentifier
        if CSBundle.compiledModel(forResource: "SSDOcr", withExtension: "mlmodelc") == nil {
            NSLog("[CardScanOcrBridge] SSDOcr.mlmodelc not found — OCR will return empty")
        } else {
            NSLog("[CardScanOcrBridge] SSDOcr.mlmodelc found")
        }
        OcrDD.configure()
        ocr = OcrDD()
        warmedUp = true
    }

    /// Recognize PAN from a BGRA8888 buffer (Flutter camera on iOS).
    func recognizeBgra(
        bytes: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        rotationDegrees: Int,
        roi: [Double]?
    ) -> [String: Any?] {
        ensureInitialized()
        guard width > 0, height > 0, !bytes.isEmpty else {
            return emptyResult(reason: "empty_frame")
        }
        guard let cgImage = Self.bgraToCGImage(
            bytes: bytes,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        ) else {
            return emptyResult(reason: "bgra_decode_failed")
        }

        var image = cgImage
        if rotationDegrees % 360 != 0, let rotated = Self.rotate(cgImage, degrees: rotationDegrees) {
            image = rotated
        }

        // Android-style: clamp-crop normalized ROI; never abort the frame.
        if let roi = roi, roi.count == 4 {
            image = Self.cropNormalizedRoi(image, roi: roi) ?? image
        }

        // CardScan SSD prefers a 600:375 card strip; fall back to the image as-is.
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let cropped = image.croppedImageForSsd(roiRectangle: full)?.0 ?? image

        let modelReady = ocr.ssdOcr.ssdOcrModel != nil
        let pan = ocr.perform(croppedCardImage: cropped)
        return [
            "pan": pan,
            "expiryDate": nil,
            "confidence": pan == nil ? 0.0 : 0.85,
            "engine": "cardscan_ssd",
            "debug": modelReady
                ? "img=\(image.width)x\(image.height) crop=\(cropped.width)x\(cropped.height) rot=\(rotationDegrees) pan=\(pan ?? "nil")"
                : "model_not_loaded",
        ]
    }

    /// Recognize PAN from OpenCV gray8 canvas.
    func recognizeGray8(bytes: Data, width: Int, height: Int) -> [String: Any?] {
        ensureInitialized()
        guard let cgImage = Self.gray8ToCGImage(bytes: bytes, width: width, height: height) else {
            return emptyResult(reason: "gray8_decode_failed")
        }
        let pan = ocr.perform(croppedCardImage: cgImage)
        return [
            "pan": pan,
            "expiryDate": nil,
            "confidence": pan == nil ? 0.0 : 0.85,
            "engine": "cardscan_ssd",
        ]
    }

    private func emptyResult(reason: String? = nil) -> [String: Any?] {
        if let reason {
            NSLog("[CardScanOcrBridge] empty result: %@", reason)
        }
        return [
            "pan": nil,
            "expiryDate": nil,
            "confidence": 0.0,
            "engine": "cardscan_ssd",
        ]
    }

    // MARK: - Image helpers

    /// Copy BGRA into an owned tightly-packed buffer for CGContext.
    private static func bgraToCGImage(
        bytes: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let srcRow = bytesPerRow > 0 ? bytesPerRow : (width * 4)
        let dstRow = width * 4
        guard bytes.count >= dstRow else { return nil }

        var owned = [UInt8](repeating: 0, count: dstRow * height)
        bytes.withUnsafeBytes { raw in
            guard let src = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0..<height {
                let srcOff = y * srcRow
                let need = width * 4
                guard srcOff + need <= bytes.count else { break }
                memcpy(&owned[y * dstRow], src.advanced(by: srcOff), need)
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // Camera BGRA uses skipped alpha (not premultiplied) — wrong alpha info
        // yields washed-out / inverted-looking buffers and kills SSD digits.
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
        )
        guard let context = CGContext(
            data: &owned,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: dstRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ), let image = context.makeImage() else {
            return nil
        }
        // Force a copy so `owned` can leave scope safely.
        return image.copy() ?? image
    }

    private static func gray8ToCGImage(bytes: Data, width: Int, height: Int) -> CGImage? {
        let expected = width * height
        guard bytes.count >= expected, width > 0, height > 0 else { return nil }
        var owned = [UInt8](bytes.prefix(expected))
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: &owned,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let image = context.makeImage() else {
            return nil
        }
        return image.copy() ?? image
    }

    /// Normalized upright ROI → pixel crop, clamped (Android `cropRoi` parity).
    private static func cropNormalizedRoi(_ image: CGImage, roi: [Double]) -> CGImage? {
        let imgW = image.width
        let imgH = image.height
        var left = Int((roi[0] * Double(imgW)).rounded(.down))
        var top = Int((roi[1] * Double(imgH)).rounded(.down))
        var width = Int((roi[2] * Double(imgW)).rounded(.up))
        var height = Int((roi[3] * Double(imgH)).rounded(.up))

        left = max(0, min(left, imgW - 1))
        top = max(0, min(top, imgH - 1))
        width = max(1, min(width, imgW - left))
        height = max(1, min(height, imgH - top))

        if width < 16 || height < 16 {
            return nil // caller keeps full image
        }

        let rect = CGRect(x: left, y: top, width: width, height: height)
        return image.cropping(to: rect)
    }

    private static func rotate(_ image: CGImage, degrees: Int) -> CGImage? {
        let normalized = ((degrees % 360) + 360) % 360
        if normalized == 0 { return image }

        let radians = CGFloat(normalized) * .pi / 180
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)

        var transform = CGAffineTransform.identity
        let newSize: CGSize
        switch normalized {
        case 90:
            // Clockwise 90° (matches Android Matrix.postRotate(90)).
            transform = CGAffineTransform(translationX: height, y: 0).rotated(by: .pi / 2)
            newSize = CGSize(width: height, height: width)
        case 180:
            transform = CGAffineTransform(translationX: width, y: height).rotated(by: .pi)
            newSize = CGSize(width: width, height: height)
        case 270:
            transform = CGAffineTransform(translationX: 0, y: width).rotated(by: -.pi / 2)
            newSize = CGSize(width: height, height: width)
        default:
            // Arbitrary angle — uncommon for camera sensorOrientation.
            transform = CGAffineTransform(rotationAngle: radians)
            newSize = CGSize(width: width, height: height)
        }

        guard let context = CGContext(
            data: nil,
            width: Int(newSize.width),
            height: Int(newSize.height),
            bitsPerComponent: image.bitsPerComponent,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: image.bitmapInfo.rawValue
        ) else { return nil }
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
