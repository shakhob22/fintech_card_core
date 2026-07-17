/// Luhn (mod-10) checksum for payment-card PANs.
///
/// Shared by manual entry validation and the OCR scan path so a glare-induced
/// single-digit substitution is rejected before a [CardData] is emitted.
abstract final class Luhn {
  /// Returns `true` when [pan] is 13–19 digits and passes the Luhn check.
  static bool validate(String pan) {
    if (pan.length < 13 || pan.length > 19) return false;
    if (!RegExp(r'^\d+$').hasMatch(pan)) return false;

    var sum = 0;
    var alternate = false;
    for (var i = pan.length - 1; i >= 0; i--) {
      var digit = int.parse(pan[i]);
      if (alternate) {
        digit *= 2;
        if (digit > 9) digit -= 9;
      }
      sum += digit;
      alternate = !alternate;
    }
    return sum % 10 == 0;
  }
}
