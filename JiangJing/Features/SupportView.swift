import SwiftUI

extension StoreManager.Notice {
    var text: String {
        switch self {
        case .tipThanks: return L10n.storeNoticeTipThanks
        case .pending: return L10n.storeNoticePending
        case .failed: return L10n.storeNoticeFailed
        case .unverified: return L10n.storeNoticeUnverified
        case .unavailable: return L10n.storeNoticeUnavailable
        case .restoreNone, .restored, .proUnlocked: return ""
        }
    }
}

/// Voluntary tip. A tip never unlocks anything and never touches Pro state.
@MainActor
struct SupportView: View {
    @EnvironmentObject private var store: StoreManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(L10n.supportBody)
                    tipSection
                    if let notice = store.notice, !notice.text.isEmpty {
                        Text(notice.text)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(CraftColor.amber)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                    Text(L10n.supportNotRestorable)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .navigationTitle(L10n.supportTitle)
            .toolbar { Button(L10n.actionClose) { dismiss() } }
        }
        .task {
            if store.loadState == .idle || store.loadState == .unavailable { await store.loadProducts() }
        }
    }

    @ViewBuilder
    private var tipSection: some View {
        switch store.loadState {
        case .idle, .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text(L10n.supportLoading).foregroundStyle(.secondary)
            }
        case .unavailable:
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.storeNoticeUnavailable).foregroundStyle(.secondary)
                Button(L10n.storeRetry) { Task { await store.loadProducts() } }
                    .buttonStyle(CraftButtonStyle(prominent: false))
            }
        case .ready:
            if let tip = store.tipProduct {
                Button {
                    Task { await store.buyTip() }
                } label: {
                    Text(String(format: L10n.supportTipButton, tip.displayPrice))
                }
                .buttonStyle(CraftButtonStyle())
                .disabled(store.busy)
            } else {
                Text(L10n.storeNoticeUnavailable).foregroundStyle(.secondary)
            }
        }
    }
}
