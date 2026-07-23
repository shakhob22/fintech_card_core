import Flutter
import UIKit
import CoreImage
import CoreNFC
import Vision

/**
 * FintechCardCorePlugin — iOS NFC bridge.
 *
 * Architecture contract
 * ─────────────────────
 * This class is a THIN BRIDGE ONLY.
 *
 * Responsibility:
 *   1. Start / stop an NFCTagReaderSession for ISO 7816 (ISO 14443) cards.
 *   2. Surface tag-detection events to Dart via FlutterEventChannel.
 *   3. Forward raw APDU byte arrays between Dart and NFCISO7816Tag.sendCommand().
 *
 * What this class does NOT do:
 *   - Build or interpret APDU commands.
 *   - Parse EMV / TLV data.
 *   - Make any payment or network call.
 *
 * All protocol logic lives in the Dart layer (nfc_card_reader.dart).
 */
@available(iOS 13.0, *)
public class FintechCardCorePlugin: NSObject, FlutterPlugin {

    // ── Channels ──────────────────────────────────────────────────────────────
    private var methodChannel: FlutterMethodChannel?
    private var ocrChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?

    // ── NFC state ─────────────────────────────────────────────────────────────
    private var nfcSession: NFCTagReaderSession?
    private var connectedTag: NFCISO7816Tag?

    // ── OCR shared context ────────────────────────────────────────────────────
    // CIContext is expensive to create (GPU initialisation). Reuse one instance
    // across all recognition calls instead of constructing per-frame.
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // ── FlutterPlugin ─────────────────────────────────────────────────────────

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = FintechCardCorePlugin()

        let method = FlutterMethodChannel(
            name: "fintech_card_core/nfc",
            binaryMessenger: registrar.messenger()
        )
        let ocr = FlutterMethodChannel(
            name: "fintech_card_core/ocr",
            binaryMessenger: registrar.messenger()
        )
        let event = FlutterEventChannel(
            name: "fintech_card_core/nfc/events",
            binaryMessenger: registrar.messenger()
        )

        instance.methodChannel = method
        instance.ocrChannel    = ocr
        instance.eventChannel  = event

        registrar.addMethodCallDelegate(instance, channel: method)
        ocr.setMethodCallHandler { call, result in
            instance.handleOcr(call, result: result)
        }
        event.setStreamHandler(instance)
    }

    // ── Method handler ────────────────────────────────────────────────────────

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]

        switch call.method {

        case "nfc/isAvailable":
            result(NFCTagReaderSession.readingAvailable)

        case "nfc/startSession":
            let alert = args["alertMessage"] as? String
                ?? "Hold your card near the top of your iPhone"
            startSession(alertMessage: alert, result: result)

        case "nfc/stopSession":
            let error = args["errorMessage"] as? String
            stopSession(errorMessage: error)
            result(nil)

        case "nfc/transceive":
            guard let apduList = args["apdu"] as? [Int] else {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "Missing or invalid 'apdu' argument",
                    details: nil
                ))
                return
            }
            transceive(apduList: apduList, result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // ── Session control ───────────────────────────────────────────────────────

    private func startSession(alertMessage: String, result: @escaping FlutterResult) {
        guard NFCTagReaderSession.readingAvailable else {
            result(FlutterError(
                code: "NFC_NOT_AVAILABLE",
                message: "NFC is not available on this device",
                details: nil
            ))
            return
        }

        nfcSession = NFCTagReaderSession(
            pollingOption: [.iso14443],
            delegate: self,
            queue: .global(qos: .userInteractive)
        )
        nfcSession?.alertMessage = alertMessage
        nfcSession?.begin()
        result(nil)
    }

    private func stopSession(errorMessage: String?) {
        if let msg = errorMessage {
            nfcSession?.invalidate(errorMessage: msg)
        } else {
            nfcSession?.invalidate()
        }
        nfcSession    = nil
        connectedTag  = nil
    }

    // ── APDU transceive ───────────────────────────────────────────────────────

    /**
     * Send [apduList] bytes to the connected ISO 7816 tag and return the raw
     * response (data + SW1 + SW2) as a plain List<Int>.
     *
     * This is the single "wire" between Dart and the NFC hardware — bytes are
     * forwarded verbatim, mirroring how a microcontroller sends signals over SPI
     * and waits for the peripheral reply without interpreting the payload.
     */
    private func transceive(apduList: [Int], result: @escaping FlutterResult) {
        guard let tag = connectedTag else {
            result(FlutterError(
                code: "NO_TAG",
                message: "No NFC tag connected — start a session first",
                details: nil
            ))
            return
        }

        let bytes = Data(apduList.map { UInt8($0 & 0xFF) })

        guard let apdu = NFCISO7816APDU(data: bytes) else {
            result(FlutterError(
                code: "INVALID_APDU",
                message: "Could not construct APDU from provided bytes",
                details: nil
            ))
            return
        }

        tag.sendCommand(apdu: apdu) { responseData, sw1, sw2, error in
            if let error = error {
                result(FlutterError(
                    code: "TRANSCEIVE_ERROR",
                    message: error.localizedDescription,
                    details: nil
                ))
                return
            }

            // Append status word bytes to the payload — same layout as Android IsoDep
            var response = [UInt8](responseData)
            response.append(sw1)
            response.append(sw2)
            result(response.map { Int($0) })
        }
    }

    // ── OCR ───────────────────────────────────────────────────────────────────

    /// Routes calls on the `fintech_card_core/ocr` channel.
    private func handleOcr(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "ocr/recognizeText":
            let args = call.arguments as? [String: Any] ?? [:]
            guard let imagePath = args["imagePath"] as? String else {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "Missing 'imagePath' argument",
                    details: nil
                ))
                return
            }
            recognizeText(imagePath: imagePath, result: result)

        case "ocr/recognizeFrame":
            recognizeFrame(call.arguments as? [String: Any] ?? [:], result: result)

        // OpenCV-warped gray8 canvas from Dart FFI (Phase 1 output).
        case "ocr/recognizeGray8":
            recognizeGray8(call.arguments as? [String: Any] ?? [:], result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /**
     * Still-photo path (debug / fallback). Live scanning uses `recognizeFrame`.
     */
    private func recognizeText(imagePath: String, result: @escaping FlutterResult) {
        guard let uiImage = UIImage(contentsOfFile: imagePath),
              let cgImageRaw = uiImage.cgImage else {
            result(FlutterError(
                code: "OCR_FAILED",
                message: "Could not load image at path: \(imagePath)",
                details: nil
            ))
            return
        }

        guard let orientedCG = flattenOrientation(uiImage: uiImage, cgImage: cgImageRaw) else {
            result(FlutterError(code: "OCR_FAILED", message: "Could not produce oriented CGImage", details: nil))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let text = try self.recognizeCGImage(orientedCG, roi: nil)
                result(text)
            } catch {
                result(FlutterError(
                    code: "OCR_FAILED",
                    message: error.localizedDescription,
                    details: nil
                ))
            }
        }
    }

    /**
     * OCR a tightly packed 8-bit grayscale buffer from the OpenCV Phase-1
     * pipeline (perspective-corrected + CLAHE, often PAN-banded).
     * Light Vision passes only — heavy preprocessing already ran in C++.
     */
    private func recognizeGray8(_ args: [String: Any], result: @escaping FlutterResult) {
        guard let width = args["width"] as? Int,
              let height = args["height"] as? Int,
              let flutterData = args["bytes"] as? FlutterStandardTypedData else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Missing or invalid gray8 frame arguments",
                details: nil
            ))
            return
        }

        guard flutterData.data.count >= width * height else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "gray8 buffer shorter than width×height",
                details: nil
            ))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                guard let cgImage = self.cgImageFromGray8(
                    data: flutterData.data,
                    width: width,
                    height: height
                ) else {
                    result(FlutterError(
                        code: "OCR_FAILED",
                        message: "Failed to create CGImage from gray8 buffer",
                        details: nil
                    ))
                    return
                }

                var candidates: [String] = []
                candidates.append(try self.runVision(on: cgImage, accurate: true))
                if self.scoreOcrText(candidates.last ?? "") < 1000 {
                    let inverted = self.invertCGImage(cgImage) ?? cgImage
                    candidates.append(try self.runVision(on: inverted, accurate: true))
                }
                result(self.joinPanCandidates(candidates))
            } catch {
                result(FlutterError(
                    code: "OCR_FAILED",
                    message: error.localizedDescription,
                    details: nil
                ))
            }
        }
    }

    /**
     * Live camera-stream path. Expects BGRA8888 bytes plus optional normalized ROI.
     */
    private func recognizeFrame(_ args: [String: Any], result: @escaping FlutterResult) {
        guard let format = args["format"] as? String, format == "bgra8888",
              let width = args["width"] as? Int,
              let height = args["height"] as? Int,
              let flutterData = args["bytes"] as? FlutterStandardTypedData else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Missing or invalid BGRA frame arguments",
                details: nil
            ))
            return
        }

        let bytesPerRow = (args["bytesPerRow"] as? Int) ?? (width * 4)
        let rotation = args["rotation"] as? Int ?? 0

        var roi: CGRect?
        if let left = args["roiLeft"] as? Double,
           let top = args["roiTop"] as? Double,
           let w = args["roiWidth"] as? Double,
           let h = args["roiHeight"] as? Double {
            roi = CGRect(x: left, y: top, width: w, height: h)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                guard var cgImage = self.cgImageFromBGRA(
                    data: flutterData.data,
                    width: width,
                    height: height,
                    bytesPerRow: bytesPerRow
                ) else {
                    result(FlutterError(
                        code: "OCR_FAILED",
                        message: "Failed to create CGImage from BGRA buffer",
                        details: nil
                    ))
                    return
                }

                if rotation != 0 {
                    cgImage = self.rotateCGImage(cgImage, degrees: rotation) ?? cgImage
                }

                let text = try self.recognizeCGImage(cgImage, roi: roi)
                result(text)
            } catch {
                result(FlutterError(
                    code: "OCR_FAILED",
                    message: error.localizedDescription,
                    details: nil
                ))
            }
        }
    }

    private func flattenOrientation(uiImage: UIImage, cgImage: CGImage) -> CGImage? {
        let w = Int(uiImage.size.width)
        let h = Int(uiImage.size.height)
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }

    private func cgImageFromBGRA(
        data: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Tightly packed gray8 rows → DeviceGray CGImage for Vision.
    private func cgImageFromGray8(data: Data, width: Int, height: Int) -> CGImage? {
        let expected = width * height
        let slice = data.prefix(expected)
        guard let provider = CGDataProvider(data: Data(slice) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func invertCGImage(_ image: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: image).applyingFilter("CIColorInvert")
        return ciContext.createCGImage(ci, from: ci.extent)
    }

    private func rotateCGImage(_ image: CGImage, degrees: Int) -> CGImage? {
        let radians = CGFloat(degrees) * .pi / 180
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        var transform = CGAffineTransform.identity
        var outW = w
        var outH = h

        switch degrees % 360 {
        case 90, -270:
            transform = CGAffineTransform(translationX: h, y: 0).rotated(by: radians)
            outW = h; outH = w
        case 180, -180:
            transform = CGAffineTransform(translationX: w, y: h).rotated(by: radians)
        case 270, -90:
            transform = CGAffineTransform(translationX: 0, y: w).rotated(by: radians)
            outW = h; outH = w
        default:
            return image
        }

        guard let ctx = CGContext(
            data: nil,
            width: Int(outW),
            height: Int(outH),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        ctx.concatenate(transform)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Crop → multi-pass Vision → best candidate by digit-run score.
    private func recognizeCGImage(_ image: CGImage, roi: CGRect?) throws -> String {
        var working = image
        if let roi, roi.width > 0.05, roi.height > 0.05 {
            let x = Int(roi.origin.x * CGFloat(image.width))
            let y = Int(roi.origin.y * CGFloat(image.height))
            let w = Int(roi.width * CGFloat(image.width))
            let h = Int(roi.height * CGFloat(image.height))
            let rect = CGRect(
                x: max(0, x),
                y: max(0, y),
                width: max(16, min(w, image.width - max(0, x))),
                height: max(16, min(h, image.height - max(0, y)))
            )
            if let cropped = image.cropping(to: rect) {
                working = cropped
            }
        }

        working = downscaleIfNeeded(working, maxSide: 1600)
        let mean = meanLuminance(working)
        var candidates: [String] = []

        func consider(_ cg: CGImage, accurate: Bool = false) throws {
            candidates.append(try runVision(on: cg, accurate: accurate))
        }

        // A single pass can misread embossed digits systematically (7→1,
        // 6→5, 4→1 stroke loss) and the wrong string may even pass Luhn:
        // early exit only when two independent passes agree on a digit run,
        // and return all PAN-bearing pass outputs joined with " ; " so the
        // Dart layer can cross-check conflicting readings.
        try consider(preprocess(working, boost: false, lowContrast: false))
        try consider(preprocess(working, boost: true, lowContrast: true))
        if hasCrossPassAgreement(candidates) {
            return joinPanCandidates(candidates)
        }

        try consider(preprocessHighPass(working, invert: false), accurate: true)
        try consider(preprocessHighPass(working, invert: true), accurate: true)
        if hasCrossPassAgreement(candidates) {
            return joinPanCandidates(candidates)
        }

        if mean > 150 {
            try consider(preprocessThreshold(working), accurate: true)
        }

        if let centre = cropCentreBand(working) {
            try consider(preprocessHighPass(centre, invert: false), accurate: true)
            try consider(preprocessHighPass(centre, invert: true), accurate: true)
            try consider(preprocess(centre, boost: true, lowContrast: true), accurate: true)
            if mean > 150 {
                try consider(preprocessThreshold(centre), accurate: true)
            }
        }

        return joinPanCandidates(candidates)
    }

    /// Longest 13–19 digit run in `text` with separators stripped.
    private func longestDigitRun(_ text: String) -> String? {
        let compact = text.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard let regex = try? NSRegularExpression(pattern: #"\d{13,19}"#) else { return nil }
        let ns = compact as NSString
        var best: String?
        for match in regex.matches(in: compact, range: NSRange(location: 0, length: ns.length)) {
            let run = ns.substring(with: match.range)
            if run.count > (best?.count ?? 0) { best = run }
        }
        return best
    }

    /// True when two *different* preprocessing passes read the same
    /// PAN-length digit run — strong evidence vs. systematic emboss misreads.
    private func hasCrossPassAgreement(_ candidates: [String]) -> Bool {
        let runs = candidates.compactMap { longestDigitRun($0) }.filter { $0.count >= 15 }
        var counts: [String: Int] = [:]
        for run in runs {
            counts[run, default: 0] += 1
            if counts[run]! >= 2 { return true }
        }
        return false
    }

    /// Every pass output containing a PAN-shaped digit run, joined with
    /// " ; " (the ';' breaks the Dart PAN regexes between passes) so
    /// conflicting readings stay distinct and are arbitrated in Dart.
    private func joinPanCandidates(_ candidates: [String]) -> String {
        var seen = Set<String>()
        var useful: [String] = []
        for candidate in candidates where scoreOcrText(candidate) >= 1000 {
            if seen.insert(candidate).inserted { useful.append(candidate) }
        }
        if useful.isEmpty { return pickBestOcrText(candidates) }
        return useful.joined(separator: " ; ")
    }

    private func scoreOcrText(_ text: String) -> Int {
        let compact = text.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        if let range = compact.range(of: #"\d{13,19}"#, options: .regularExpression) {
            return 1000 + compact[range].count
        }
        return compact.count
    }

    private func pickBestOcrText(_ candidates: [String]) -> String {
        candidates.max(by: { scoreOcrText($0) < scoreOcrText($1) }) ?? ""
    }

    private func meanLuminance(_ image: CGImage) -> Double {
        guard let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return 128 }
        let w = image.width
        let h = image.height
        let bpp = max(1, image.bitsPerPixel / 8)
        let rowBytes = image.bytesPerRow
        let stepX = max(1, w / 40)
        let stepY = max(1, h / 40)
        var sum = 0.0
        var count = 0
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                let offset = y * rowBytes + x * bpp
                let v: Int
                if bpp >= 3 {
                    let b = Int(ptr[offset])
                    let g = Int(ptr[offset + 1])
                    let r = Int(ptr[offset + 2])
                    v = (r * 30 + g * 59 + b * 11) / 100
                } else {
                    v = Int(ptr[offset])
                }
                sum += Double(v)
                count += 1
                x += stepX
            }
            y += stepY
        }
        return count == 0 ? 128 : sum / Double(count)
    }

    private func cropCentreBand(_ image: CGImage) -> CGImage? {
        let top = Int(Double(image.height) * 0.30)
        let height = max(24, Int(Double(image.height) * 0.40))
        let left = Int(Double(image.width) * 0.04)
        let width = max(32, Int(Double(image.width) * 0.92))
        let rect = CGRect(
            x: max(0, left),
            y: max(0, top),
            width: min(width, image.width - max(0, left)),
            height: min(height, image.height - max(0, top))
        )
        guard rect.width >= 32, rect.height >= 24 else { return nil }
        return image.cropping(to: rect)
    }

    private func preprocessHighPass(_ cgImage: CGImage, invert: Bool) -> CGImage {
        var ciImage = CIImage(cgImage: cgImage)
        ciImage = ciImage.applyingFilter("CIColorMonochrome",
            parameters: ["inputColor": CIColor.gray, "inputIntensity": 1.0])
        let blurred = ciImage.applyingFilter("CIGaussianBlur",
            parameters: ["inputRadius": 3.5])
        var residual = ciImage.applyingFilter("CIUnsharpMask",
            parameters: ["inputRadius": 3.5, "inputIntensity": 2.2])
        residual = residual.applyingFilter("CIColorControls",
            parameters: ["inputContrast": 2.2, "inputBrightness": -0.02])
        // Prefer unsharp over subtract — subtract extent can mismatch after blur.
        _ = blurred
        if invert {
            residual = residual.applyingFilter("CIColorInvert")
        }
        residual = residual.applyingFilter("CISharpenLuminance",
            parameters: ["inputSharpness": 0.9])
        return ciContext.createCGImage(residual, from: residual.extent) ?? cgImage
    }

    private func downscaleIfNeeded(_ image: CGImage, maxSide: Int) -> CGImage {
        let longSide = max(image.width, image.height)
        guard longSide > maxSide else { return image }
        let scale = CGFloat(maxSide) / CGFloat(longSide)
        let outW = max(1, Int(CGFloat(image.width) * scale))
        let outH = max(1, Int(CGFloat(image.height) * scale))
        guard let ctx = CGContext(
            data: nil,
            width: outW,
            height: outH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        return ctx.makeImage() ?? image
    }

    /**
     * Fast path: monochrome + contrast.
     * Boost / low-contrast: highlight-shadow + unsharp (+ sharpen for emboss).
     */
    private func preprocess(_ cgImage: CGImage, boost: Bool, lowContrast: Bool) -> CGImage {
        var ciImage = CIImage(cgImage: cgImage)

        ciImage = ciImage.applyingFilter("CIColorMonochrome",
            parameters: ["inputColor": CIColor.gray, "inputIntensity": 1.0])

        if boost || lowContrast {
            ciImage = ciImage.applyingFilter("CIHighlightShadowAdjust",
                parameters: [
                    "inputShadowAmount": 0.55,
                    "inputHighlightAmount": 0.55,
                ])
            ciImage = ciImage.applyingFilter("CIColorControls",
                parameters: ["inputContrast": 1.5, "inputBrightness": -0.03])
            ciImage = ciImage.applyingFilter("CIUnsharpMask",
                parameters: ["inputRadius": 1.6, "inputIntensity": 0.8])
            if lowContrast {
                ciImage = ciImage.applyingFilter("CISharpenLuminance",
                    parameters: ["inputSharpness": 0.7])
            }
        } else {
            ciImage = ciImage.applyingFilter("CIColorControls",
                parameters: ["inputContrast": 1.25, "inputBrightness": -0.02])
        }

        return ciContext.createCGImage(ciImage, from: ciImage.extent) ?? cgImage
    }

    /// Strong local contrast pass for flat low-contrast printed digits.
    private func preprocessThreshold(_ cgImage: CGImage) -> CGImage {
        var ciImage = CIImage(cgImage: cgImage)
        ciImage = ciImage.applyingFilter("CIColorMonochrome",
            parameters: ["inputColor": CIColor.gray, "inputIntensity": 1.0])
        ciImage = ciImage.applyingFilter("CIColorControls",
            parameters: ["inputContrast": 2.0, "inputBrightness": -0.05])
        ciImage = ciImage.applyingFilter("CIUnsharpMask",
            parameters: ["inputRadius": 2.0, "inputIntensity": 1.0])
        ciImage = ciImage.applyingFilter("CISharpenLuminance",
            parameters: ["inputSharpness": 1.0])
        return ciContext.createCGImage(ciImage, from: ciImage.extent) ?? cgImage
    }

    private func runVision(on cgImage: CGImage, accurate: Bool = false) throws -> String {
        var collected = ""
        var visionError: Error?
        let minConfidence: Float = accurate ? 0.20 : 0.28

        let request = VNRecognizeTextRequest { request, error in
            if let error {
                visionError = error
                return
            }
            let observations = request.results as? [VNRecognizedTextObservation] ?? []
            collected = observations.compactMap { obs -> String? in
                guard let candidate = obs.topCandidates(1).first,
                      candidate.confidence >= minConfidence else { return nil }
                return candidate.string
            }.joined(separator: "\n")
        }

        request.recognitionLevel = accurate ? .accurate : .fast
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        if let visionError { throw visionError }
        return collected
    }

    // ── Events helper ─────────────────────────────────────────────────────────

    private func emit(type: String, message: String? = nil) {
        var payload: [String: Any] = ["type": type]
        if let msg = message { payload["message"] = msg }
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(payload)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// NFCTagReaderSessionDelegate
// ─────────────────────────────────────────────────────────────────────────────

@available(iOS 13.0, *)
extension FintechCardCorePlugin: NFCTagReaderSessionDelegate {

    public func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        // Session is active — waiting for a tag
    }

    public func tagReaderSession(
        _ session: NFCTagReaderSession,
        didInvalidateWithError error: Error
    ) {
        connectedTag = nil
        let nfcError = error as? NFCReaderError
        if nfcError?.code == .readerSessionInvalidationErrorUserCanceled {
            emit(type: "sessionEnded")
        } else {
            emit(type: "error", message: error.localizedDescription)
        }
    }

    public func tagReaderSession(
        _ session: NFCTagReaderSession,
        didDetect tags: [NFCTag]
    ) {
        guard let firstTag = tags.first else { return }

        session.connect(to: firstTag) { [weak self] error in
            guard let self else { return }

            if let error = error {
                session.invalidate(errorMessage: "Tag connection failed")
                self.emit(type: "error", message: error.localizedDescription)
                return
            }

            // Only ISO 7816 (ISO 14443-4) cards carry EMV applets
            guard case .iso7816(let iso7816Tag) = firstTag else {
                session.invalidate(
                    errorMessage: "Unsupported card type. Use an EMV chip card."
                )
                self.emit(type: "error", message: "Unsupported NFC card type")
                return
            }

            self.connectedTag = iso7816Tag
            self.emit(type: "tagDetected")
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FlutterStreamHandler (EventChannel)
// ─────────────────────────────────────────────────────────────────────────────

@available(iOS 13.0, *)
extension FintechCardCorePlugin: FlutterStreamHandler {

    public func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }
}
