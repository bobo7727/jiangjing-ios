import SwiftUI

/// Pro purchase controls shared by the paywall and the Support page.
/// While the purchase status is unknown it offers retry/restore only, never a purchase button.
@MainActor
struct ProPurchaseSection: View {
    @EnvironmentObject private var store: StoreManager
    var showsNotice = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch store.proStatus {
            case .unlocked:
                Text(L10n.proUnlocked).font(.headline).foregroundStyle(CraftColor.amber)
            case .unknown:
                Text(L10n.labelCheckFailed).foregroundStyle(.secondary)
                Button(L10n.storeRetry) { Task { await store.refreshEntitlements() } }
                    .buttonStyle(CraftButtonStyle())
                restoreButton
            case .locked:
                purchaseButton
                restoreButton
            }
            if showsNotice, let notice = store.notice, !notice.text.isEmpty {
                Text(notice.text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CraftColor.amber)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .task {
            if store.loadState == .idle || store.loadState == .unavailable { await store.loadProducts() }
        }
    }

    @ViewBuilder
    private var purchaseButton: some View {
        switch store.loadState {
        case .idle, .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text(L10n.supportLoading).foregroundStyle(.secondary)
            }
        case .unavailable:
            Text(L10n.storeNoticeUnavailable).foregroundStyle(.secondary)
            Button(L10n.storeRetry) { Task { await store.loadProducts() } }
                .buttonStyle(CraftButtonStyle(prominent: false))
        case .ready:
            if let pro = store.proProduct {
                Button {
                    Task { await store.buyPro() }
                } label: {
                    Text(String(format: L10n.proUnlock, pro.displayPrice))
                }
                .buttonStyle(CraftButtonStyle())
                .disabled(store.busy)
            } else {
                Text(L10n.storeNoticeUnavailable).foregroundStyle(.secondary)
                Button(L10n.storeRetry) { Task { await store.loadProducts() } }
                    .buttonStyle(CraftButtonStyle(prominent: false))
            }
        }
    }

    private var restoreButton: some View {
        Button(L10n.proRestore) { Task { await store.restore() } }
            .buttonStyle(CraftButtonStyle(prominent: false))
            .disabled(store.busy)
    }
}

/// Shown only when the user taps "export" on a label and Pro is confirmed locked. Never at launch,
/// never in the capture chain.
@MainActor
struct ProPaywallView: View {
    @EnvironmentObject private var store: StoreManager
    @Environment(\.dismiss) private var dismiss
    var onUnlocked: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(L10n.proTitle).font(.system(.title, design: .rounded).weight(.bold))
                    Text(L10n.proBody)
                    Text(L10n.proStillFree).font(.footnote).foregroundStyle(.secondary)
                    ProPurchaseSection()
                    Button(L10n.proNotNow) { dismiss() }
                        .buttonStyle(CraftButtonStyle(prominent: false))
                }
                .padding(24)
            }
            .toolbar { Button(L10n.actionClose) { dismiss() } }
        }
        .onAppear { store.notice = nil }
        .onChange(of: store.proStatus) { status in
            if status == .unlocked { onUnlocked() }
        }
    }
}
