import Testing
import Foundation
@testable import CeolCore

/// The part of the purchase logic that does not need StoreKit: who counts as a
/// customer of the earlier, paid Fonn.
struct PurchaseRulesTests {

    private let before = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21
    private let after  = Date(timeIntervalSince1970: 1_792_000_000) // 2026-10-14

    @Test("a production download from the paid era is grandfathered")
    func paidEraProduction() {
        #expect(PurchaseStore.grandfathers(originalPurchaseDate: before, isProduction: true))
    }

    @Test("a production download after the cut-over is not")
    func freeEraProduction() {
        #expect(!PurchaseStore.grandfathers(originalPurchaseDate: after, isProduction: true))
    }

    @Test("TestFlight and App Review are never grandfathered, whatever date they report")
    func sandboxIsNeverTrusted() {
        #expect(!PurchaseStore.grandfathers(originalPurchaseDate: before, isProduction: false))
        #expect(!PurchaseStore.grandfathers(originalPurchaseDate: .distantPast, isProduction: false))
    }

    @Test("the cut-over is the day Fonn came off sale")
    func cutOverDate() {
        let expected = ISO8601DateFormatter().date(from: "2026-10-05T00:00:00Z")!
        #expect(PurchaseStore.paidEraEnds == expected)
    }
}
