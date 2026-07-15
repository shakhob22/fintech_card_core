import Flutter
import UIKit
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
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /**
     * Run on-device text recognition on the JPEG at [imagePath] using
     * Vision.framework (VNRecognizeTextRequest, iOS 13+).
     *
     * Returns the concatenated text of all recognised observations as a
     * single newline-separated String — identical in shape to ML Kit output
     * so that OcrParser.parse() works without modification.
     */
    private func recognizeText(imagePath: String, result: @escaping FlutterResult) {
        guard let image = UIImage(contentsOfFile: imagePath),
              let cgImage = image.cgImage else {
            result(FlutterError(
                code: "OCR_FAILED",
                message: "Could not load image at path: \(imagePath)",
                details: nil
            ))
            return
        }

        let request = VNRecognizeTextRequest { request, error in
            if let error = error {
                result(FlutterError(
                    code: "OCR_FAILED",
                    message: error.localizedDescription,
                    details: nil
                ))
                return
            }

            let observations = request.results as? [VNRecognizedTextObservation] ?? []
            let text = observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")

            result(text)
        }

        // accurate > fast — card numbers require precise recognition
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
            } catch {
                result(FlutterError(
                    code: "OCR_FAILED",
                    message: error.localizedDescription,
                    details: nil
                ))
            }
        }
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
