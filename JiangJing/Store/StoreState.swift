import Foundation

/// Foundation-only purchase rules so they can be tested without StoreKit.
enum ProStatus: Equatable, Sendable {
    /// Not yet known. Never shows a purchase button, never blocks a free feature.
    case unknown
    /// A completed, verified entitlement query found no Pro entitlement.
    case locked
    case unlocked
}

enum PurchaseOutcome: Equatable, Sendable {
    case success
    case cancelled
    case pending
    case unverified
    case busy
    case failed
    case unavailable
}

/// Plain summary of one StoreKit transaction (no StoreKit types).
struct Entitlement: Equatable, Sendable {
    let productID: String
    let bundleID: String
    let isVerified: Bool
    let isRevoked: Bool
}

enum EntitlementQuery: Equatable, Sendable {
    /// The query finished. The list holds every current entitlement the store returned.
    case completed([Entitlement])
    /// The query failed or timed out; says nothing about ownership.
    case failed
}

enum StoreRules {
    /// A transaction grants Pro only if it is verified, for this app, not refunded, and is the Pro product.
    /// Tips never grant anything.
    static func grantsPro(_ entitlement: Entitlement, bundleID: String) -> Bool {
        entitlement.productID == StoreCatalog.proID
            && entitlement.bundleID == bundleID
            && entitlement.isVerified
            && !entitlement.isRevoked
    }
}

/// Tracks `ProStatus`. Only a completed query whose entitlements were all verified can move to `locked`.
struct ProTracker: Equatable, Sendable {
    private(set) var status: ProStatus = .unknown
    let bundleID: String

    init(bundleID: String) { self.bundleID = bundleID }

    mutating func apply(_ query: EntitlementQuery) {
        switch query {
        case .failed:
            return // Keep what we knew: unknown stays unknown, unlocked stays unlocked.
        case .completed(let entitlements):
            if entitlements.contains(where: { StoreRules.grantsPro($0, bundleID: bundleID) }) {
                status = .unlocked
            } else if entitlements.contains(where: { $0.productID == StoreCatalog.proID && !$0.isVerified }) {
                // An unverified Pro result is not proof of anything: stay undecided.
                if status != .unlocked { status = .unknown }
            } else {
                status = .locked
            }
        }
    }

    /// A transaction pushed by `Transaction.updates` (Ask to Buy approval, refund, other device).
    mutating func apply(update entitlement: Entitlement) {
        guard entitlement.productID == StoreCatalog.proID, entitlement.bundleID == bundleID else { return }
        if StoreRules.grantsPro(entitlement, bundleID: bundleID) {
            status = .unlocked
        } else if entitlement.isVerified && entitlement.isRevoked {
            status = .locked
        }
        // Unverified: no change.
    }

    /// Result of a purchase the user just made.
    mutating func apply(purchase outcome: PurchaseOutcome) {
        if outcome == .success { status = .unlocked }
    }
}
