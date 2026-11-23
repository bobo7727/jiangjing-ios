import XCTest
@testable import JiangJing

/// Scriptable StoreKit stand-in. All state is guarded by a lock so it can be `Sendable`.
private final class MockBackend: StoreBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _purchase: [String: PurchaseOutcome] = [:]
    private var _entitlements: EntitlementQuery = .completed([])
    private var _entitlementDelay: UInt64 = 0
    private var _products: [ProductInfo] = []
    private var _loadFails = false
    private var _syncFails = false
    private var continuation: AsyncStream<StoreEvent>.Continuation?
    private(set) var purchaseCalls: [String] = []

    func set(purchase id: String, _ outcome: PurchaseOutcome) { lock.withLock { _purchase[id] = outcome } }
    func set(entitlements: EntitlementQuery, delayMilliseconds: UInt64 = 0) {
        lock.withLock { _entitlements = entitlements; _entitlementDelay = delayMilliseconds }
    }
    func set(products: [ProductInfo]) { lock.withLock { _products = products } }
    func set(loadFails: Bool) { lock.withLock { _loadFails = loadFails } }
    func set(syncFails: Bool) { lock.withLock { _syncFails = syncFails } }
    func push(_ event: StoreEvent) { _ = lock.withLock { continuation }?.yield(event) }

    func loadProducts(ids: Set<String>) async throws -> [ProductInfo] {
        let (fails, list) = lock.withLock { (_loadFails, _products) }
        if fails { throw URLError(.notConnectedToInternet) }
        return list.filter { ids.contains($0.id) }
    }
    func purchase(id: String) async -> PurchaseOutcome {
        lock.withLock { purchaseCalls.append(id); return _purchase[id] ?? .failed }
    }
    func currentEntitlements() async -> EntitlementQuery {
        let (query, delay) = lock.withLock { (_entitlements, _entitlementDelay) }
        if delay > 0 { try? await Task.sleep(nanoseconds: delay * 1_000_000) }
        return query
    }
    func sync() async throws {
        if lock.withLock({ _syncFails }) { throw URLError(.userAuthenticationRequired) }
    }
    func events() -> AsyncStream<StoreEvent> {
        AsyncStream { continuation in lock.withLock { self.continuation = continuation } }
    }
}

@MainActor
final class StoreManagerTests: XCTestCase {
    private let bundle = "com.jiangjing.magnifier"
    private let tip = ProductInfo(id: StoreCatalog.tipSmallID, displayName: "Tip", description: "", displayPrice: "$0.99")
    private let proInfo = ProductInfo(id: StoreCatalog.proID, displayName: "Pro", description: "", displayPrice: "$2.99")

    private func proEntitlement(verified: Bool = true) -> Entitlement {
        Entitlement(productID: StoreCatalog.proID, bundleID: bundle, isVerified: verified, isRevoked: false)
    }

    private func makeManager(_ backend: MockBackend) -> StoreManager {
        StoreManager(backend: backend, bundleID: bundle)
    }

    func testTipSuccessThanksAndNeverTouchesPro() async {
        let backend = MockBackend()
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
            let backend = MockBackend()
            backend.set(purchase: StoreCatalog.tipSmallID, outcome)
            let store = makeManager(backend)
            await store.buyTip()
            XCTAssertEqual(store.notice, expected, "\(outcome)")
            XCTAssertEqual(store.proStatus, .unknown)
        }
    }

    func testProPurchaseUnlocks() async {
        let backend = MockBackend()
        backend.set(purchase: StoreCatalog.proID, .success)
        let store = makeManager(backend)
        await store.buyPro()
        XCTAssertEqual(store.proStatus, .unlocked)
        XCTAssertEqual(store.notice, .proUnlocked)
    }

    func testPendingProPurchaseDoesNotUnlock() async {
        let backend = MockBackend()
        backend.set(purchase: StoreCatalog.proID, .pending)
        let store = makeManager(backend)
        await store.buyPro()
        XCTAssertEqual(store.proStatus, .unknown)
        XCTAssertEqual(store.notice, .pending)
    }

    func testLaunchEntitlementUnlocksOrLocks() async {
        let owned = MockBackend()
        owned.set(entitlements: .completed([proEntitlement()]))
        let ownedStore = makeManager(owned)
        await ownedStore.refreshEntitlements()
        XCTAssertEqual(ownedStore.proStatus, .unlocked)

        let free = MockBackend()
        let freeStore = makeManager(free)
        await freeStore.refreshEntitlements()
        XCTAssertEqual(freeStore.proStatus, .locked)
    }

    func testSlowLookupStaysUnknownThenUnlocksPurchasedCustomerLate() async {
        let backend = MockBackend()
        backend.set(entitlements: .completed([proEntitlement()]), delayMilliseconds: 600)
        let store = makeManager(backend)
        let status = await store.resolvedProStatus(timeout: 0.2)
        XCTAssertEqual(status, .unknown, "a slow lookup must not become locked")
        try? await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertEqual(store.proStatus, .unlocked, "the late answer still unlocks a purchased customer")
    }

    func testUnverifiedOnlyResultStaysUnknown() async {
        let backend = MockBackend()
        backend.set(entitlements: .completed([proEntitlement(verified: false)]))
        let store = makeManager(backend)
        await store.refreshEntitlements()
        XCTAssertEqual(store.proStatus, .unknown)
    }

    func testRestoreFindsPurchaseOrReportsNone() async {
        let owned = MockBackend()
        owned.set(entitlements: .completed([proEntitlement()]))
        let ownedStore = makeManager(owned)
        await ownedStore.restore()
        XCTAssertEqual(ownedStore.proStatus, .unlocked)
        XCTAssertEqual(ownedStore.notice, .restored)

        let free = MockBackend()
        let freeStore = makeManager(free)
        await freeStore.restore()
        XCTAssertEqual(freeStore.proStatus, .locked)
        XCTAssertEqual(freeStore.notice, .restoreNone)

        let failing = MockBackend()
        failing.set(syncFails: true)
        let failingStore = makeManager(failing)
        await failingStore.restore()
        XCTAssertEqual(failingStore.notice, .failed)
        XCTAssertEqual(failingStore.proStatus, .unknown)
    }

    func testBackgroundEventsApproveRefundAndThank() async {
        let backend = MockBackend()
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
        let backend = MockBackend()
        backend.set(products: [tip, proInfo])
        let store = makeManager(backend)
        await store.loadProducts()
        XCTAssertEqual(store.loadState, .ready)
        XCTAssertEqual(store.tipProduct?.displayPrice, "$0.99")
        XCTAssertEqual(store.proProduct?.displayPrice, "$2.99")

        let failing = MockBackend()
        failing.set(loadFails: true)
        let failingStore = makeManager(failing)
        await failingStore.loadProducts()
        XCTAssertEqual(failingStore.loadState, .unavailable)
        XCTAssertNil(failingStore.tipProduct)

        let empty = MockBackend()
        let emptyStore = makeManager(empty)
        await emptyStore.loadProducts()
        XCTAssertEqual(emptyStore.loadState, .unavailable)
    }
}
