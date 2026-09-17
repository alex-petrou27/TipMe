import XCTest
@testable import TipMeCore

/// Mirrors Registry/tests/test_lightning_node.py's bolt11 amount tests --
/// same real invoices, same multiplier table, same edge cases. The Swift and
/// Python decoders must never disagree about what an invoice is worth.
final class BOLT11Tests: XCTestCase {
    // Real invoices from live testing against a Voltage Mutinynet wallet --
    // these amounts (1000 and 300 sats) are independently confirmed by what
    // was actually credited/paid, not just re-deriving the encoding.
    private let real1000SatInvoice =
        "lntbs10u1p42cer8pp5n22m02nyv8vflvaess8cxdsykstptkmvjsszhgykrrqezxrlp73q" +
        "dqqcqzzsxqrrsssp5ypj5qhhsgwwg9cpf0ql4s3s3jgzk05v6yjt3gk9w49fx5pcmmwxs9qx" +
        "pqysgqeglfk0gd0v8aths9sv9jw8asazdale9d0uw68lxtq0aaq6pk2cn8yf9re9mzqsl3f" +
        "tqqkg3f9zuayp6xm97w4l6njnnjnk4d4getfeqqad930y"

    private let real300SatInvoice =
        "lntbs3u1p42c6qapp5ekjg0cnv3tgnahk02tyvf0td4074plmrl9zc69rhxvduzkq3j55qd" +
        "qqcqzzsxqrrsssp58677fv2z9lm6je0pme4y8pqnp4htc8aqp4lm2kmakdx5cjuxdzys9qx" +
        "pqysgq6sccgfxzdzn9c2vxpzd6q7ezy4c3hmwhpz8dp0gyve7mzxj34tys9qe0hww6l2cg8" +
        "u64alp938eckge69atlkh7s4hkhz084pya3r8cq3g9ecj"

    func testMatchesRealConfirmedInvoices() {
        XCTAssertEqual(BOLT11.amountSats(from: real1000SatInvoice), 1000)
        XCTAssertEqual(BOLT11.amountSats(from: real300SatInvoice), 300)
    }

    func testIsCaseInsensitive() {
        XCTAssertEqual(BOLT11.amountSats(from: real300SatInvoice.uppercased()), 300)
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(BOLT11.amountSats(from: "  \(real300SatInvoice)\n"), 300)
    }

    func testHandlesEveryMultiplier() {
        XCTAssertEqual(BOLT11.amountSats(from: "lntb5m1p0mockdata"), 500_000)       // milli-bitcoin
        XCTAssertEqual(BOLT11.amountSats(from: "lntb10u1p0mockdata"), 1000)         // micro-bitcoin
        XCTAssertEqual(BOLT11.amountSats(from: "lntb5n1p0mockdata"), 0)             // nano, sub-satoshi rounds to 0
        XCTAssertEqual(BOLT11.amountSats(from: "lntb10000n1p0mockdata"), 1000)      // nano, whole sats
        XCTAssertEqual(BOLT11.amountSats(from: "lntb10000p1p0mockdata"), 1)         // pico, exactly 1 sat
    }

    func testRejectsNonInvoiceStrings() {
        XCTAssertNil(BOLT11.amountSats(from: "not-an-invoice"))
        XCTAssertNil(BOLT11.amountSats(from: ""))
    }

    func testRejectsZeroAmountInvoices() {
        XCTAssertNil(BOLT11.amountSats(from: "lntbs1p42cer8pp5mockdata"))
    }

    func testRejectsFractionalMillisatoshiPicoAmounts() {
        XCTAssertNil(BOLT11.amountSats(from: "lntbs15p1p0mockdata"))
    }
}
