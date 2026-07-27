/// How the card data was acquired.
enum CardReadMode { nfc, ocr, manual }

/// Payment network detected from the BIN (Bank Identification Number).
///
/// Includes Uzbek local networks [humo] and [uzcard].
enum CardType {
  visa,
  mastercard,
  amex,
  discover,
  unionPay,
  jcb,
  humo,
  uzcard,
  unknown;

  /// Identifies the network from a PAN / BIN prefix (spaces and dashes ignored).
  ///
  /// Progressive: returns a positive match as soon as enough digits are typed
  /// (e.g. Visa after `4`, Amex after `34`/`37`, Humo after `9860`).
  static CardType fromPan(String pan) {
    final p = pan.replaceAll(RegExp(r'[\s\-]'), '');
    if (p.isEmpty) return CardType.unknown;

    // Uzbek local networks — check before generic ranges
    if (p.length >= 4 && p.startsWith('9860')) return CardType.humo;
    if (p.length >= 4 && (p.startsWith('8600') || p.startsWith('5614'))) {
      return CardType.uzcard;
    }

    // American Express: 34 / 37
    if (p.length >= 2 && RegExp(r'^3[47]').hasMatch(p)) return CardType.amex;

    // JCB: 3528–3589
    if (p.length >= 4 && RegExp(r'^35(2[89]|[3-8])').hasMatch(p)) {
      return CardType.jcb;
    }

    // Visa
    if (p.startsWith('4')) return CardType.visa;

    // Mastercard: 51–55 or 2221–2720
    if (p.length >= 2 && RegExp(r'^5[1-5]').hasMatch(p)) {
      return CardType.mastercard;
    }
    if (p.length >= 4 &&
        RegExp(r'^2(2[2-9][1-9]|2[3-9]\d|[3-6]\d{2}|7[01]\d|720)').hasMatch(p)) {
      return CardType.mastercard;
    }

    // Discover: 6011, 644–649, 65, and 6221–6229 (before UnionPay’s broader 62)
    if (RegExp(r'^6(011|22[1-9]|[45])').hasMatch(p)) return CardType.discover;

    // UnionPay: 62
    if (p.length >= 2 && p.startsWith('62')) return CardType.unionPay;

    return CardType.unknown;
  }
}

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
