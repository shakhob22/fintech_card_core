/// EMV TLV tag constants (ISO 7816-4 / EMV Book 3).
///
/// Tags are integer values derived from the TLV encoding:
///   - Single-byte tags  : 0x50, 0x57, etc.
///   - Two-byte tags     : encoded as `(b1 << 8) | b2` → 0x5F24, 0x9F02, etc.
abstract final class EmvTags {
  // ── File / Application structure ──────────────────────────────────────────
  static const int fciTemplate = 0x6F;
  static const int fciProprietaryTemplate = 0xA5;
  static const int fciIssuerDiscretionary = 0xBF0C;
  static const int directoryEntry = 0x61;
  static const int applicationId = 0x84;
  static const int applicationLabel = 0x50;
  static const int applicationPriorityIndicator = 0x87;
  static const int applicationPreferredName = 0x9F12;

  // ── Card data ─────────────────────────────────────────────────────────────

  /// Primary Account Number (BCD-encoded card number).
  static const int pan = 0x5A;

  /// Track 2 Equivalent Data (PAN + expiry + service code).
  static const int track2EquivalentData = 0x57;

  /// Application Expiry Date — YYMMDD in BCD.
  static const int expiryDate = 0x5F24;

  /// Cardholder Name — ASCII string.
  static const int cardholderName = 0x5F20;

  /// Service Code — 3 BCD digits.
  static const int serviceCode = 0x5F30;

  // ── Processing Options ────────────────────────────────────────────────────

  /// Application Interchange Profile.
  static const int aip = 0x82;

  /// Application File Locator — list of (SFI, first record, last record).
  static const int afl = 0x94;

  /// Response Message Template Format 1 (primitive, GPO response).
  static const int responseTemplate1 = 0x80;

  /// Response Message Template Format 2 (constructed, GPO response).
  static const int responseTemplate2 = 0x77;

  /// Record template tag wrapping READ RECORD data.
  static const int record = 0x70;

  // ── Transaction data ──────────────────────────────────────────────────────
  static const int authorisedAmount = 0x9F02;
  static const int transactionCurrencyCode = 0x5F2A;
  static const int transactionDate = 0x9A;
  static const int transactionType = 0x9C;
  static const int unpredictableNumber = 0x9F37;
  static const int applicationTransactionCounter = 0x9F36;
  static const int cryptogramInformationData = 0x9F27;
  static const int applicationCryptogram = 0x9F26;
  static const int issuerApplicationData = 0x9F10;

  // ── PDOL ──────────────────────────────────────────────────────────────────

  /// Processing Data Object List — specifies the data elements the card
  /// requires in the GET PROCESSING OPTIONS command data field.
  static const int pdol = 0x9F38;
}
