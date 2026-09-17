import Foundation

/// Reads the amount encoded in a BOLT11 Lightning invoice's own
/// human-readable prefix, without a full bech32 decode.
///
/// Mirrors `Registry/tipme_registry/lightning_node.py`'s
/// `_bolt11_amount_sats` -- same multiplier table, same "the last `1` in the
/// string is always the bech32 data separator" trick (the bech32 alphabet
/// excludes the digit `1`, so it can never appear before that point),
/// verified against the same real Voltage invoices that function was.
enum BOLT11 {
    private static let hrpPattern = try! NSRegularExpression(pattern: "^ln[a-z]*?([0-9]+)([munp])?$")

    /// `nil` for anything that isn't a recognisable BOLT11 invoice, or one
    /// with no amount encoded (a "zero-amount" invoice) -- Registry's
    /// withdraw endpoint only accepts fixed-amount invoices, so there is
    /// nothing useful to return for either case.
    static func amountSats(from paymentRequest: String) -> Int64? {
        let invoice = paymentRequest.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard invoice.hasPrefix("ln"), let separatorIndex = invoice.lastIndex(of: "1") else {
            return nil
        }
        let hrp = String(invoice[..<separatorIndex])
        let range = NSRange(hrp.startIndex..<hrp.endIndex, in: hrp)
        guard let match = hrpPattern.firstMatch(in: hrp, range: range),
              let amountRange = Range(match.range(at: 1), in: hrp),
              let amount = Int64(hrp[amountRange])
        else { return nil }

        let multiplierRange = match.range(at: 2)
        let multiplier = multiplierRange.location != NSNotFound ? String(hrp[Range(multiplierRange, in: hrp)!]) : nil

        let amountMsat: Int64
        switch multiplier {
        case "p":
            guard amount % 10 == 0 else { return nil }
            amountMsat = amount / 10
        case "m": amountMsat = amount * 100_000_000
        case "u": amountMsat = amount * 100_000
        case "n": amountMsat = amount * 100
        default: amountMsat = amount * 100_000_000_000
        }
        return amountMsat / 1000
    }
}
