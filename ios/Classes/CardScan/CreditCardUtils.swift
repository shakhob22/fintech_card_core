// Minimal Luhn helper extracted from getbouncer/cardscan-ios (MIT).
// Full CardType / BIN tables intentionally omitted — Dart owns card typing.

import Foundation

enum CreditCardUtils {
    static func isValidNumber(cardNumber: String) -> Bool {
        let digits = cardNumber.filter(\.isNumber)
        guard (12...19).contains(digits.count) else { return false }

        var sum = 0
        var alternate = false
        for char in digits.reversed() {
            guard var n = char.wholeNumberValue else { return false }
            if alternate {
                n *= 2
                if n > 9 { n -= 9 }
            }
            sum += n
            alternate.toggle()
        }
        return sum % 10 == 0
    }
}
