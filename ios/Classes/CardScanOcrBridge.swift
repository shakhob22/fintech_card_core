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
        // Prefer the plugin bundle for the compiled CoreML model.
        CSBundle.cardScanBundle = Bundle(for: CardScanOcrBridge.self)
        CSBundle.bundleIdentifier = Bundle(for: CardScanOcrBridge.self).bundleIdentifier
            ?? CSBundle.bundleIdentifier
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
        guard let cgImage = Self.bgraToCGImage(
            bytes: bytes,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        ) else {
            return emptyResult()
        }

        var image = cgImage
        if rotationDegrees % 360 != 0, let rotated = Self.rotate(cgImage, degrees: rotationDegrees) {
            image = rotated
        }

        let roiRect: CGRect
        if let roi = roi, roi.count == 4 {
            roiRect = CGRect(
                x: CGFloat(roi[0]) * CGFloat(image.width),
                y: CGFloat(roi[1]) * CGFloat(image.height),
                width: CGFloat(roi[2]) * CGFloat(image.width),
                height: CGFloat(roi[3]) * CGFloat(image.height)
            )
        } else {
            roiRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        }

        guard let (cropped, _) = image.croppedImageForSsd(roiRectangle: roiRect) else {
            return emptyResult()
        }

        let pan = ocr.perform(croppedCardImage: cropped)
        return [
            "pan": pan,
            "expiryDate": nil,
            "confidence": pan == nil ? 0.0 : 0.85,
            "engine": "cardscan_ssd",
        ]
    }

    /// Recognize PAN from OpenCV gray8 canvas.
    func recognizeGray8(bytes: Data, width: Int, height: Int) -> [String: Any?] {
        ensureInitialized()
        guard let cgImage = Self.gray8ToCGImage(bytes: bytes, width: width, height: height) else {
            return emptyResult()
        }
        let pan = ocr.perform(croppedCardImage: cgImage)
        return [
            "pan": pan,
            "expiryDate": nil,
            "confidence": pan == nil ? 0.0 : 0.85,
            "engine": "cardscan_ssd",
        ]
    }

    private func emptyResult() -> [String: Any?] {
        [
            "pan": nil,
            "expiryDate": nil,
            "confidence": 0.0,
            "engine": "cardscan_ssd",
        ]
    }

    // MARK: - Image helpers

    private static func bgraToCGImage(
        bytes: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        return bytes.withUnsafeBytes { raw -> CGImage? in
            guard let base = raw.baseAddress else { return nil }
            guard let context = CGContext(
                data: UnsafeMutableRawPointer(mutating: base),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else { return nil }
            return context.makeImage()
        }
    }

    private static func gray8ToCGImage(bytes: Data, width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        return bytes.withUnsafeBytes { raw -> CGImage? in
            guard let base = raw.baseAddress else { return nil }
            guard let context = CGContext(
                data: UnsafeMutableRawPointer(mutating: base),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return nil }
            return context.makeImage()
        }
    }

    private static func rotate(_ image: CGImage, degrees: Int) -> CGImage? {
        let radians = CGFloat(degrees) * .pi / 180
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        var transform = CGAffineTransform.identity
        switch degrees % 360 {
        case 90, -270:
            transform = transform.translatedBy(x: height, y: 0).rotated(by: radians)
        case 180, -180:
            transform = transform.translatedBy(x: width, y: height).rotated(by: radians)
        case 270, -90:
            transform = transform.translatedBy(x: 0, y: width).rotated(by: radians)
        default:
            return image
        }
        let newSize: CGSize
        if degrees % 180 == 0 {
            newSize = CGSize(width: width, height: height)
        } else {
            newSize = CGSize(width: height, height: width)
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
