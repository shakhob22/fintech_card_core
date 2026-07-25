import Flutter
import UIKit
import CoreNFC

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

    // ── OCR (CardScan SSD CoreML) ─────────────────────────────────────────────

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

        case "ocr/recognizeGray8":
            recognizeGray8(call.arguments as? [String: Any] ?? [:], result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func recognizeText(imagePath: String, result: @escaping FlutterResult) {
        guard let uiImage = UIImage(contentsOfFile: imagePath),
              let cgImage = uiImage.cgImage else {
            result(FlutterError(
                code: "OCR_FAILED",
                message: "Could not load image at path: \(imagePath)",
                details: nil
            ))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let roi = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
            let map: [String: Any?]
            if let (cropped, _) = cgImage.croppedImageForSsd(roiRectangle: roi) {
                CardScanOcrBridge.shared.ensureInitialized()
                let pan = OcrDD().perform(croppedCardImage: cropped)
                map = [
                    "pan": pan,
                    "expiryDate": nil,
                    "confidence": pan == nil ? 0.0 : 0.85,
                    "engine": "cardscan_ssd",
                ]
            } else {
                map = [
                    "pan": nil,
                    "expiryDate": nil,
                    "confidence": 0.0,
                    "engine": "cardscan_ssd",
                ]
            }
            DispatchQueue.main.async { result(map) }
        }
    }

    private func recognizeGray8(_ args: [String: Any], result: @escaping FlutterResult) {
        guard let width = Self.intValue(args["width"]),
              let height = Self.intValue(args["height"]),
              let flutterData = args["bytes"] as? FlutterStandardTypedData else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Missing or invalid gray8 frame arguments",
                details: nil
            ))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let map = CardScanOcrBridge.shared.recognizeGray8(
                bytes: flutterData.data,
                width: width,
                height: height
            )
            DispatchQueue.main.async { result(map) }
        }
    }

    private func recognizeFrame(_ args: [String: Any], result: @escaping FlutterResult) {
        guard let format = args["format"] as? String, format == "bgra8888",
              let width = Self.intValue(args["width"]),
              let height = Self.intValue(args["height"]),
              let flutterData = args["bytes"] as? FlutterStandardTypedData else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Missing or invalid BGRA frame arguments (format/width/height/bytes)",
                details: nil
            ))
            return
        }

        let bytesPerRow = Self.intValue(args["bytesPerRow"]) ?? (width * 4)
        let rotation = Self.intValue(args["rotation"]) ?? 0

        var roi: [Double]?
        if let left = Self.doubleValue(args["roiLeft"]),
           let top = Self.doubleValue(args["roiTop"]),
           let w = Self.doubleValue(args["roiWidth"]),
           let h = Self.doubleValue(args["roiHeight"]) {
            roi = [left, top, w, h]
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let map = CardScanOcrBridge.shared.recognizeBgra(
                bytes: flutterData.data,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                rotationDegrees: rotation,
                roi: roi
            )
            // FlutterResult must be invoked on the platform (main) thread on iOS.
            DispatchQueue.main.async { result(map) }
        }
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        if let n = raw as? NSNumber { return n.intValue }
        return nil
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        if let n = raw as? NSNumber { return n.doubleValue }
        return nil
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
