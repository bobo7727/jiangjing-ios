import XCTest
@testable import CaptureCore

final class StoreStateTests: XCTestCase {
    private let bundle = "com.jiangjing.magnifier"

    private func pro(verified: Bool = true, revoked: Bool = false, bundle: String? = nil) -> Entitlement {
        Entitlement(productID: StoreCatalog.proID, bundleID: bundle ?? self.bundle, isVerified: verified, isRevoked: revoked)
    }

    func testProductIdentifiersMatchTheApprovedCatalog() {
        XCTAssertEqual(StoreCatalog.tipSmallID, "com.jiangjing.magnifier.tip.small")
        XCTAssertEqual(StoreCatalog.proID, "com.jiangjing.magnifier.pro")
        XCTAssertEqual(StoreCatalog.tipIDs, [StoreCatalog.tipSmallID])
        XCTAssertFalse(StoreCatalog.tipIDs.contains(StoreCatalog.proID))
    }

    func testStartsUnknown() {
        XCTAssertEqual(ProTracker(bundleID: bundle).status, .unknown)
    }

    func testTipsNeverGrantPro() {
        var tracker = ProTracker(bundleID: bundle)
        let tip = Entitlement(productID: StoreCatalog.tipSmallID, bundleID: bundle, isVerified: true, isRevoked: false)
        tracker.apply(.completed([tip]))
        XCTAssertEqual(tracker.status, .locked)
        tracker.apply(update: tip)
        XCTAssertEqual(tracker.status, .locked)
        XCTAssertFalse(StoreRules.grantsPro(tip, bundleID: bundle))
    }

    func testCompletedQueryWithVerifiedProUnlocks() {
        var tracker = ProTracker(bundleID: bundle)
        tracker.apply(.completed([pro()]))
        XCTAssertEqual(tracker.status, .unlocked)
    }

    func testCompletedQueryWithNothingLocks() {
        var tracker = ProTracker(bundleID: bundle)
        tracker.apply(.completed([]))
        XCTAssertEqual(tracker.status, .locked)
    }

    func testFailedOrTimedOutQueryNeverLocks() {
        var tracker = ProTracker(bundleID: bundle)
        tracker.apply(.failed)
        XCTAssertEqual(tracker.status, .unknown)
        tracker.apply(.completed([pro()]))
        tracker.apply(.failed)
        XCTAssertEqual(tracker.status, .unlocked, "a later failed query must not take Pro away")
    }

    func testUnverifiedOnlyResultStaysUnknown() {
        var tracker = ProTracker(bundleID: bundle)
        tracker.apply(.completed([pro(verified: false)]))
        XCTAssertEqual(tracker.status, .unknown)
    }

    func testLateAnswerForPurchasedCustomerUnlocks() {
        var tracker = ProTracker(bundleID: bundle)
        tracker.apply(.failed) // timed out first
        XCTAssertEqual(tracker.status, .unknown)
        tracker.apply(.completed([pro()])) // the real answer arrives late
        XCTAssertEqual(tracker.status, .unlocked)
    }

    func testRefundLocksAgain() {
        var tracker = ProTracker(bundleID: bundle)
        tracker.apply(.completed([pro()]))
        tracker.apply(update: pro(revoked: true))
        XCTAssertEqual(tracker.status, .locked)
    }

    func testUnverifiedUpdateDoesNotChangeStatus() {
        var tracker = ProTracker(bundleID: bundle)
        tracker.apply(.completed([pro()]))
        tracker.apply(update: pro(verified: false))
        XCTAssertEqual(tracker.status, .unlocked)
    }

    func testOtherBundleNeverGrants() {
        var tracker = ProTracker(bundleID: bundle)
        tracker.apply(.completed([pro(bundle: "com.example.other")]))
        XCTAssertEqual(tracker.status, .locked)
        tracker.apply(update: pro(bundle: "com.example.other"))
        XCTAssertEqual(tracker.status, .locked)
    }

    func testSuccessfulPurchaseUnlocksAndOtherOutcomesDoNot() {
        for outcome in [PurchaseOutcome.cancelled, .pending, .unverified, .busy, .failed, .unavailable] {
            var tracker = ProTracker(bundleID: bundle)
            tracker.apply(purchase: outcome)
            XCTAssertEqual(tracker.status, .unknown, "\(outcome)")
        }
        var tracker = ProTracker(bundleID: bundle)
        tracker.apply(purchase: .success)
        XCTAssertEqual(tracker.status, .unlocked)
    }

    func testLabelTextIsNormalized() {
        XCTAssertEqual(LabelLayout.normalized("  Ana\nStudio  "), "Ana Studio")
        XCTAssertEqual(LabelLayout.normalized(String(repeating: "x", count: 90)).count, LabelLayout.maxCharacters)
        XCTAssertEqual(LabelLayout.composed(name: "Ana", date: "Nov 23, 2026"), "Ana · Nov 23, 2026")
        XCTAssertEqual(LabelLayout.composed(name: "  ", date: "Nov 23, 2026"), "Nov 23, 2026")
        XCTAssertEqual(LabelLayout.composed(name: "Ana", date: nil), "Ana")
        XCTAssertEqual(LabelLayout.composed(name: "", date: nil), "")
    }

    func testLabelLayoutScalesAndKeepsTheBoxInsideTheImage() {
        let small = LabelLayout.make(imageWidth: 600, imageHeight: 800)
        let large = LabelLayout.make(imageWidth: 3000, imageHeight: 4000)
        XCTAssertGreaterThan(large.fontSize, small.fontSize)
        XCTAssertGreaterThanOrEqual(small.fontSize, 14)
        XCTAssertEqual(small.originX(position: .bottomLeft, imageWidth: 600, boxWidth: 200), small.margin)
        XCTAssertEqual(small.originX(position: .bottomRight, imageWidth: 600, boxWidth: 200), 600 - small.margin - 200)
        XCTAssertEqual(small.originX(position: .bottomRight, imageWidth: 600, boxWidth: 9999), small.margin)
        XCTAssertEqual(small.originY(imageHeight: 800, boxHeight: 40), 800 - small.margin - 40)
    }

    func testLabelPreferencesRoundTripAndNormalize() {
        let suite = "label-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(LabelPreferences.load(defaults), LabelStyle())
        LabelPreferences.save(LabelStyle(name: " Ana\nStudio ", showDate: true, position: .bottomRight), defaults)
        XCTAssertEqual(LabelPreferences.load(defaults), LabelStyle(name: "Ana Studio", showDate: true, position: .bottomRight))
        defaults.set("nonsense", forKey: "label.position")
        XCTAssertEqual(LabelPreferences.load(defaults).position, .bottomLeft)
    }

    func testStampTextUsesDateOnlyWhenAsked() {
        let date = Date(timeIntervalSince1970: 1_795_000_000) // fixed instant
        let locale = Locale(identifier: "en_US")
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(LabelStyle(name: "Ana", showDate: false).stampText(date: date, locale: locale, timeZone: utc), "Ana")
        let withDate = LabelStyle(name: "Ana", showDate: true).stampText(date: date, locale: locale, timeZone: utc)
        XCTAssertTrue(withDate.hasPrefix("Ana · "))
        XCTAssertGreaterThan(withDate.count, 6)
        XCTAssertEqual(LabelStyle(name: "", showDate: false).stampText(date: date), "")
    }
}
