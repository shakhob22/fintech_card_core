/// How the card data was acquired.
enum CardReadMode { nfc, ocr, manual, mock }

/// Payment network detected from the BIN (Bank Identification Number).
enum CardType { visa, mastercard, amex, discover, unionPay, jcb, unknown }

/// Pre-defined mock card scenarios for developer testing.
enum MockCardPreset { visa, mastercard, amex, discover, declined, expired }
