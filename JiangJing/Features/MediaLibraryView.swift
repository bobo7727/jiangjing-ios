import SwiftUI

extension SaveState {
    var message: String {
        switch self {
        case .pending: return L10n.mediaPending
        case .saving: return L10n.captureSaving
        case .saved: return L10n.captureSaved
        case .denied: return L10n.captureSaveDenied
        case .failed: return L10n.captureSaveFailed
        case .uncertain: return L10n.mediaUncertain
        }
    }
}

@MainActor
struct MediaLibraryView: View {
    @ObservedObject var library: MediaLibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var discardID: UUID?
    @State private var retryID: UUID?

    var body: some View {
        NavigationStack {
            List {
                Text(L10n.mediaRetention).font(.subheadline)
                ForEach(library.records) { record in
                    VStack(alignment: .leading, spacing: 12) {
                        Label(record.kind == .photo ? L10n.actionPhoto : L10n.actionRecord,
                              systemImage: record.kind == .photo ? "photo" : "video")
                            .font(.headline)
                        Text(record.createdAt, style: .date)
                        Text(record.createdAt, style: .time)
                        Text(record.isComplete ? record.saveState.message : L10n.mediaIncomplete)
                        if let duration = record.duration { Text(ClockFormat.string(from: duration)) }
                        if record.isComplete {
                            Button(L10n.actionShare) { library.share(record.id) }
                            if record.saveState != .saved && record.saveState != .saving {
                                Button(L10n.mediaRetry) {
                                    if record.saveState == .uncertain { retryID = record.id }
                                    else { Task { await library.save(record.id, explicitlyRetry: true) } }
                                }
                            }
                        } else {
                            Button(L10n.mediaVerify) { Task { await library.verify(record.id) } }
                                .disabled(!library.canDiscard(record.id))
                        }
                        Button(L10n.mediaDiscard, role: .destructive) { discardID = record.id }
                            .disabled(!library.canDiscard(record.id))
                    }
                    .padding(.vertical, 8)
                    .buttonStyle(.borderless)
                }
            }
            .alert(library.shareError ? L10n.shareFailedTitle : L10n.storageTitle, isPresented: Binding(
                get: { library.storageError || library.shareError },
                set: { if !$0 { library.storageError = false; library.shareError = false } }
            )) {
                Button(L10n.actionClose, role: .cancel) {}
            } message: {
                Text(library.shareError ? L10n.shareFailedBody : L10n.storageBody)
            }
            .navigationTitle(L10n.mediaTitle)
            .toolbar { Button(L10n.actionClose) { dismiss() } }
            .confirmationDialog(L10n.mediaDiscardConfirm, isPresented: Binding(
                get: { discardID != nil }, set: { if !$0 { discardID = nil } }
            ), titleVisibility: .visible) {
                Button(L10n.mediaDiscard, role: .destructive) {
                    if let id = discardID { library.discard(id) }
                    discardID = nil
                }
            }
            .confirmationDialog(L10n.mediaDuplicateWarning, isPresented: Binding(
                get: { retryID != nil }, set: { if !$0 { retryID = nil } }
            ), titleVisibility: .visible) {
                Button(L10n.mediaRetry) {
                    if let id = retryID { Task { await library.save(id, explicitlyRetry: true) } }
                    retryID = nil
                }
            }
        }
    }
}
