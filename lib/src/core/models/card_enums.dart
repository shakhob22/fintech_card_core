/// How the card data was acquired.
enum CardReadMode { nfc, ocr, manual }

/// Payment network detected from the BIN (Bank Identification Number).
///
/// Includes Uzbek local networks [humo] and [uzcard].
enum CardType { visa, mastercard, amex, discover, unionPay, jcb, humo, uzcard, unknown }

/// Declares which card networks [SmartCardInput] should accept and how it
/// should format and validate card data.
///
/// | Scheme | PAN digits | Grouping | CVC |
/// |---|---|---|---|
/// | [autoDetect] | 15–16 | detected | per network |
/// | [visaAndMastercard] | 16 | 4-4-4-4 | 3-digit, required |
/// | [humoAndUzcard] | 16 | 4-4-4-4 | hidden |
/// | [americanExpress] | 15 | 4-6-5 | 4-digit CID, required |
enum CardInputScheme {
  /// BIN prefix is read in real-time; format, length, and CVC requirements
  /// adapt automatically as the user types.
  autoDetect,

  /// Forces 16-digit 4-4-4-4 layout with a mandatory 3-digit CVV.
  visaAndMastercard,

  /// Forces 16-digit 4-4-4-4 layout and hides the CVC field entirely
  /// (Humo and Uzcard cards do not carry a CVV).
  humoAndUzcard,

  /// Forces 15-digit 4-6-5 layout with a mandatory 4-digit CID field.
  americanExpress,
}
