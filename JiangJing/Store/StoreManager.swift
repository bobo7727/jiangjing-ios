import Combine
import Foundation

/// Owns purchase state for the whole app. It is the only place that talks to `StoreBackend`.
/// Free features never read it; only the Support page and the label-stamp export do.
@MainActor
final class StoreManager: ObservableObject {
    enum LoadState: Equatable { case idle, loading, ready, unavailable }

    /// Outcome messages shown on the Support page and the paywall.
    enum Notice: Equatable {
        case tipThanks, pending, failed, unverified, unavailable, restoreNone, restored, proUnlocked
    }

    @Published private(set) var proStatus: ProStatus = .unknown
    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var products: [String: ProductInfo] = [:]
    @Published private(set) var busy = false
    @Published var notice: Notice?

    private var tracker: ProTracker
    private let backend: StoreBackend
    private var eventsTask: Task<Void, Never>?
    private var refreshing = false
    private var started = false

    convenience init() {
        self.init(backend: StoreKitBackend())
    }

    init(backend: StoreBackend, bundleID: String = Bundle.main.bundleIdentifier ?? "") {
        self.backend = backend
        self.tracker = ProTracker(bundleID: bundleID)
    }

    var tipProduct: ProductInfo? { products[StoreCatalog.tipSmallID] }
    var proProduct: ProductInfo? { products[StoreCatalog.proID] }
    /// Informational only (the small PRO badge). Never blocks anything by itself.
    var showsProBadge: Bool { proStatus != .unlocked }

    /// Starts the single transaction listener and loads state. Safe to call repeatedly.
    func begin() {
        guard !started else { return }
        started = true
        eventsTask = Task { [weak self, backend] in
            for await event in backend.events() {
                self?.handle(event)
            }
        }
        Task {
            await refreshEntitlements()
            await loadProducts()
        }
    }

    func refreshEntitlements() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        tracker.apply(await backend.currentEntitlements())
        proStatus = tracker.status
    }

    func loadProducts() async {
        loadState = .loading
        do {
            let list = try await backend.loadProducts(ids: StoreCatalog.allIDs)
            products = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
            loadState = list.isEmpty ? .unavailable : .ready
        } catch {
            loadState = .unavailable
        }
    }

    /// Waits up to `timeout` seconds for an answer. Stays `.unknown` if none comes: the caller then shows
    /// retry/restore, never a purchase button. A late answer still updates `proStatus`.
    func resolvedProStatus(timeout: TimeInterval = 3) async -> ProStatus {
        if proStatus == .unknown { Task { await refreshEntitlements() } }
        let deadline = Date().addingTimeInterval(timeout)
        while proStatus == .unknown && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return proStatus
    }

    func buyTip() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        notice = Self.notice(for: await backend.purchase(id: StoreCatalog.tipSmallID), success: .tipThanks)
    }

    func buyPro() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let outcome = await backend.purchase(id: StoreCatalog.proID)
        tracker.apply(purchase: outcome)
        proStatus = tracker.status
        notice = Self.notice(for: outcome, success: .proUnlocked)
    }

    func restore() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await backend.sync()
        } catch {
            notice = .failed
            return
        }
        refreshing = false
        await refreshEntitlements()
        notice = proStatus == .unlocked ? .restored : .restoreNone
    }

    private func handle(_ event: StoreEvent) {
        switch event {
        case .entitlement(let entitlement):
            tracker.apply(update: entitlement)
            proStatus = tracker.status
        case .tipThanks:
            notice = .tipThanks
        case .tipUnverified:
            notice = .unverified
        }
    }

    private static func notice(for outcome: PurchaseOutcome, success: Notice) -> Notice? {
        switch outcome {
        case .success: return success
        case .cancelled, .busy: return nil
        case .pending: return .pending
        case .unverified: return .unverified
        case .failed: return .failed
        case .unavailable: return .unavailable
        }
    }
}
