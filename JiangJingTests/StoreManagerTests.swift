import XCTest
@testable import JiangJing

@MainActor
final class StoreManagerTests: XCTestCase {
    private let bundle = "com.jiangjing.magnifier"
    private let tip = ProductInfo(id: StoreCatalog.tipSmallID, displayName: "Tip", description: "", displayPrice: "$0.99")
    private let proInfo = ProductInfo(id: StoreCatalog.proID, displayName: "Pro", description: "", displayPrice: "$2.99")

    private func proEntitlement(verified: Bool = true) -> Entitlement {
        Entitlement(productID: StoreCatalog.proID, bundleID: bundle, isVerified: verified, isRevoked: false)
    }

    private func makeManager(_ backend: MockStoreBackend) -> StoreManager {
        StoreManager(backend: backend, bundleID: bundle)
    }

    func testTipSuccessThanksAndNeverTouchesPro() async {
        let backend = MockStoreBackend()
        backend.set(purchase: StoreCatalog.tipSmallID, .success)
        let store = makeManager(backend)
        await store.buyTip()
        XCTAssertEqual(store.notice, .tipThanks)
        XCTAssertEqual(store.proStatus, .unknown, "a tip must never unlock or lock Pro")
        XCTAssertEqual(backend.purchaseCalls, [StoreCatalog.tipSmallID])
    }

    func testTipOutcomesMapToNotices() async {
        let cases: [(PurchaseOutcome, StoreManager.Notice?)] = [
            (.cancelled, nil), (.busy, nil), (.pending, .pending), (.unverified, .unverified),
            (.failed, .failed), (.unavailable, .unavailable)
        ]
        for (outcome, expected) in cases {
            let backend = MockStoreBackend()
            backend.set(purchase: StoreCatalog.tipSmallID, outcome)
            let store = makeManager(backend)
            await store.buyTip()
            XCTAssertEqual(store.notice, expected, "\(outcome)")
            XCTAssertEqual(store.proStatus, .unknown)
        }
    }

    func testProPurchaseUnlocks() async {
        let backend = MockStoreBackend()
        backend.set(purchase: StoreCatalog.proID, .success)
        let store = makeManager(backend)
        await store.buyPro()
        XCTAssertEqual(store.proStatus, .unlocked)
        XCTAssertEqual(store.notice, .proUnlocked)
    }

    func testPendingProPurchaseDoesNotUnlock() async {
        let backend = MockStoreBackend()
        backend.set(purchase: StoreCatalog.proID, .pending)
        let store = makeManager(backend)
        await store.buyPro()
        XCTAssertEqual(store.proStatus, .unknown)
        XCTAssertEqual(store.notice, .pending)
    }

    func testLaunchEntitlementUnlocksOrLocks() async {
        let owned = MockStoreBackend()
        owned.set(entitlements: .completed([proEntitlement()]))
        let ownedStore = makeManager(owned)
        await ownedStore.refreshEntitlements()
        XCTAssertEqual(ownedStore.proStatus, .unlocked)

        let free = MockStoreBackend()
        let freeStore = makeManager(free)
        await freeStore.refreshEntitlements()
        XCTAssertEqual(freeStore.proStatus, .locked)
    }

    func testSlowLookupStaysUnknownThenUnlocksPurchasedCustomerLate() async {
        let backend = MockStoreBackend()
        backend.set(entitlements: .completed([proEntitlement()]), delayMilliseconds: 600)
        let store = makeManager(backend)
        let status = await store.resolvedProStatus(timeout: 0.2)
        XCTAssertEqual(status, .unknown, "a slow lookup must not become locked")
        try? await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertEqual(store.proStatus, .unlocked, "the late answer still unlocks a purchased customer")
    }

    func testUnverifiedOnlyResultStaysUnknown() async {
        let backend = MockStoreBackend()
        backend.set(entitlements: .completed([proEntitlement(verified: false)]))
        let store = makeManager(backend)
        await store.refreshEntitlements()
        XCTAssertEqual(store.proStatus, .unknown)
    }

    func testRestoreFindsPurchaseOrReportsNone() async {
        let owned = MockStoreBackend()
        owned.set(entitlements: .completed([proEntitlement()]))
        let ownedStore = makeManager(owned)
        await ownedStore.restore()
        XCTAssertEqual(ownedStore.proStatus, .unlocked)
        XCTAssertEqual(ownedStore.notice, .restored)

        let free = MockStoreBackend()
        let freeStore = makeManager(free)
        await freeStore.restore()
        XCTAssertEqual(freeStore.proStatus, .locked)
        XCTAssertEqual(freeStore.notice, .restoreNone)

        let failing = MockStoreBackend()
        failing.set(syncFails: true)
        let failingStore = makeManager(failing)
        await failingStore.restore()
        XCTAssertEqual(failingStore.notice, .failed)
        XCTAssertEqual(failingStore.proStatus, .unknown)
    }

    func testBackgroundEventsApproveRefundAndThank() async {
        let backend = MockStoreBackend()
        let store = makeManager(backend)
        store.begin()
        try? await Task.sleep(nanoseconds: 200_000_000)
        backend.push(.entitlement(proEntitlement()))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(store.proStatus, .unlocked)
        backend.push(.entitlement(Entitlement(productID: StoreCatalog.proID, bundleID: bundle, isVerified: true, isRevoked: true)))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(store.proStatus, .locked)
        backend.push(.tipThanks)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(store.notice, .tipThanks)
        XCTAssertEqual(store.proStatus, .locked, "a tip must not change Pro")
    }

    func testProductLoadingStatesAndPrices() async {
        let backend = MockStoreBackend()
        backend.set(products: [tip, proInfo])
        let store = makeManager(backend)
        await store.loadProducts()
        XCTAssertEqual(store.loadState, .ready)
        XCTAssertEqual(store.tipProduct?.displayPrice, "$0.99")
        XCTAssertEqual(store.proProduct?.displayPrice, "$2.99")

        let failing = MockStoreBackend()
        failing.set(loadFails: true)
        let failingStore = makeManager(failing)
        await failingStore.loadProducts()
        XCTAssertEqual(failingStore.loadState, .unavailable)
        XCTAssertNil(failingStore.tipProduct)

        let empty = MockStoreBackend()
        let emptyStore = makeManager(empty)
        await emptyStore.loadProducts()
        XCTAssertEqual(emptyStore.loadState, .unavailable)
    }

    func testStaleEmptyQueryCannotRelockAfterApprovalEvent() async {
        let backend = MockStoreBackend()
        backend.set(entitlements: .completed([]), delayMilliseconds: 700)
        let store = makeManager(backend)
        store.begin()
        try? await Task.sleep(nanoseconds: 200_000_000)
        backend.push(.entitlement(proEntitlement()))
        try? await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertEqual(store.proStatus, .unlocked, "an older empty query must not relock an approved customer")
    }

    func testStaleOwnedQueryCannotUndoRefundEvent() async {
        let backend = MockStoreBackend()
        backend.set(entitlements: .completed([proEntitlement()]), delayMilliseconds: 700)
        let store = makeManager(backend)
        store.begin()
        try? await Task.sleep(nanoseconds: 200_000_000)
        backend.push(.entitlement(Entitlement(productID: StoreCatalog.proID, bundleID: bundle, isVerified: true, isRevoked: true)))
        try? await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertEqual(store.proStatus, .locked, "an older owned query must not undo a refund")
    }

    func testOlderSlowQueryCannotRelockAfterNewerRestoreQuery() async {
        let backend = MockStoreBackend()
        backend.set(entitlements: .completed([]), delayMilliseconds: 700) // launch query captures this: empty, slow
        let store = makeManager(backend)
        store.begin()
        try? await Task.sleep(nanoseconds: 150_000_000)
        backend.set(entitlements: .completed([proEntitlement()]), delayMilliseconds: 0) // restore sees Pro at once
        await store.restore()
        XCTAssertEqual(store.proStatus, .unlocked)
        try? await Task.sleep(nanoseconds: 900_000_000) // let the older empty query finish
        XCTAssertEqual(store.proStatus, .unlocked, "an older query finishing after Restore must not relock Pro")
    }

    func testRefundEventWithoutStatusChangeStillInvalidatesOwnedQuery() async {
        let backend = MockStoreBackend()
        backend.set(entitlements: .completed([]), delayMilliseconds: 0)
        let store = makeManager(backend)
        await store.refreshEntitlements()
        XCTAssertEqual(store.proStatus, .locked)
        store.begin()
        try? await Task.sleep(nanoseconds: 100_000_000) // let the launch query settle (locked)
        backend.set(entitlements: .completed([proEntitlement()]), delayMilliseconds: 700) // stale owned query
        let slow = Task { await store.refreshEntitlements() }
        try? await Task.sleep(nanoseconds: 150_000_000)
        backend.push(.entitlement(Entitlement(productID: StoreCatalog.proID, bundleID: bundle, isVerified: true, isRevoked: true)))
        await slow.value
        XCTAssertEqual(store.proStatus, .locked, "a refund while locked must still outrank an older owned query")
    }
}
