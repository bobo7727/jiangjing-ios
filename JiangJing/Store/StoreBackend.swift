import Foundation
import StoreKit

/// Store-localised product data. The price is StoreKit's `displayPrice`; it is never computed or hard-coded.
struct ProductInfo: Equatable, Sendable {
    let id: String
    let displayName: String
    let description: String
    let displayPrice: String
}

/// Something the store pushed outside a purchase the user just made.
enum StoreEvent: Equatable, Sendable {
    case entitlement(Entitlement)
    case tipThanks
    case tipUnverified
}

/// Narrow seam over StoreKit 2 so `StoreManager` can be tested with a mock.
protocol StoreBackend: Sendable {
    func loadProducts(ids: Set<String>) async throws -> [ProductInfo]
    /// Buys, verifies and finishes. Only a verified transaction for this app yields `.success`.
    func purchase(id: String) async -> PurchaseOutcome
    func currentEntitlements() async -> EntitlementQuery
    func sync() async throws
    /// The single `Transaction.updates` listener plus replay of unfinished transactions.
    func events() -> AsyncStream<StoreEvent>
}

/// Native StoreKit 2 backend. Adapted from the stl2stp `StoreCoordinator` (feat/tip-iap):
/// verified -> finish; unverified is never granted and never finished.
actor StoreKitBackend: StoreBackend {
    private var buying = false
    private var handledTips = Set<UInt64>()
    private var announcedUnverified = Set<UInt64>()

    func loadProducts(ids: Set<String>) async throws -> [ProductInfo] {
        let products = try await Product.products(for: ids)
        return products.map {
            ProductInfo(id: $0.id, displayName: $0.displayName, description: $0.description, displayPrice: $0.displayPrice)
        }
    }

    func purchase(id: String) async -> PurchaseOutcome {
        guard StoreCatalog.allIDs.contains(id) else { return .unavailable }
        guard !buying else { return .busy }
        buying = true
        defer { buying = false }
        do {
            guard let product = try await Product.products(for: [id]).first else { return .unavailable }
            switch try await product.purchase() {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    guard transaction.appBundleID == Bundle.main.bundleIdentifier else { return .failed }
                    if StoreCatalog.tipIDs.contains(transaction.productID) { handledTips.insert(transaction.id) }
                    await transaction.finish()
                    return .success
                case .unverified:
                    return .unverified
                }
            case .userCancelled:
                return .cancelled
            case .pending:
                return .pending
            @unknown default:
                return .failed
            }
        } catch {
            if let storeError = error as? StoreKitError, case .userCancelled = storeError { return .cancelled }
            return .failed
        }
    }

    func currentEntitlements() async -> EntitlementQuery {
        var found: [Entitlement] = []
        for await result in Transaction.currentEntitlements {
            found.append(Self.entitlement(from: result))
        }
        return .completed(found)
    }

    func sync() async throws {
        try await AppStore.sync()
    }

    nonisolated func events() -> AsyncStream<StoreEvent> {
        AsyncStream { continuation in
            let updates = Task {
                for await result in Transaction.updates {
                    for event in await self.handle(result) { continuation.yield(event) }
                }
            }
            let replay = Task {
                for await result in Transaction.unfinished {
                    for event in await self.handle(result) { continuation.yield(event) }
                }
            }
            continuation.onTermination = { _ in
                updates.cancel()
                replay.cancel()
            }
        }
    }

    private static func entitlement(from result: VerificationResult<Transaction>) -> Entitlement {
        switch result {
        case .verified(let transaction):
            return Entitlement(productID: transaction.productID, bundleID: transaction.appBundleID,
                               isVerified: true, isRevoked: transaction.revocationDate != nil)
        case .unverified(let transaction, _):
            return Entitlement(productID: transaction.productID, bundleID: transaction.appBundleID,
                               isVerified: false, isRevoked: transaction.revocationDate != nil)
        }
    }

    private func handle(_ result: VerificationResult<Transaction>) async -> [StoreEvent] {
        switch result {
        case .unverified(let transaction, _):
            if StoreCatalog.tipIDs.contains(transaction.productID) {
                return announcedUnverified.insert(transaction.id).inserted ? [.tipUnverified] : []
            }
            if transaction.productID == StoreCatalog.proID {
                return [.entitlement(Self.entitlement(from: result))]
            }
            return []
        case .verified(let transaction):
            guard transaction.appBundleID == Bundle.main.bundleIdentifier else { return [] }
            if StoreCatalog.tipIDs.contains(transaction.productID) {
                guard transaction.productType == .consumable else { return [] }
                let first = handledTips.insert(transaction.id).inserted
                await transaction.finish()
                // A refunded tip is finished silently; it never earned a thank-you.
                return first && transaction.revocationDate == nil ? [.tipThanks] : []
            }
            if transaction.productID == StoreCatalog.proID {
                await transaction.finish()
                return [.entitlement(Self.entitlement(from: result))]
            }
            return []
        }
    }
}
