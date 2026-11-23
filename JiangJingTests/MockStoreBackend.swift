import XCTest
@testable import JiangJing

/// Scriptable StoreKit stand-in. All state is guarded by a lock so it can be `Sendable`.
final class MockStoreBackend: StoreBackend, @unchecked Sendable {
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
