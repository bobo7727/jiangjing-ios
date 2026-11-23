import SwiftUI
import UIKit

/// Label stamp editor. Preview and typing are free; only the export is Pro.
@MainActor
struct LabelEditorView: View {
    let photo: FrozenPhoto
    @ObservedObject var media: MediaLibraryModel
    var onExported: (UUID) -> Void

    @EnvironmentObject private var store: StoreManager
    @Environment(\.dismiss) private var dismiss
    @State private var style = LabelPreferences.load()
    @State private var base: UIImage?
    @State private var preview: UIImage?
    @State private var exporting = false
    @State private var showPaywall = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let preview {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .accessibilityLabel(L10n.labelPreview)
                    }
                    TextField(L10n.labelPlaceholder, text: $style.name)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.done)
                    Toggle(L10n.labelShowDate, isOn: $style.showDate)
                    Picker(L10n.labelPosition, selection: $style.position) {
                        Text(L10n.labelBottomLeft).tag(LabelPosition.bottomLeft)
                        Text(L10n.labelBottomRight).tag(LabelPosition.bottomRight)
                    }
                    .pickerStyle(.segmented)
                    Text(L10n.labelOriginalKept).font(.footnote).foregroundStyle(.secondary)
                    if let message {
                        Text(message).font(.subheadline.weight(.semibold)).foregroundStyle(CraftColor.amber)
                    }
                    Button {
                        Task { await export() }
                    } label: {
                        if exporting { ProgressView() } else { Text(L10n.labelExport) }
                    }
                    .buttonStyle(CraftButtonStyle())
                    .disabled(exporting || stampText.isEmpty)
                }
                .padding(20)
            }
            .navigationTitle(L10n.labelTitle)
            .toolbar { Button(L10n.actionClose) { dismiss() } }
        }
        .sheet(isPresented: $showPaywall) {
            ProPaywallView {
                showPaywall = false
                Task { await export() }
            }
        }
        .onAppear {
            base = LabelRenderer.previewBase(of: photo.image)
            refreshPreview()
        }
        .onChange(of: style) { _ in refreshPreview() }
    }

    private var stampText: String { style.stampText(date: Date()) }

    private func refreshPreview() {
        guard let base else { return }
        preview = LabelRenderer.render(image: base, text: stampText, position: style.position)
    }

    private func export() async {
        guard !exporting else { return }
        exporting = true
        message = L10n.labelChecking
        LabelPreferences.save(style)
        let result = await LabelExporter(store: store, media: media).export(sourceURL: photo.fileURL, style: style)
        exporting = false
        message = nil
        switch result {
        case .exported(let id): onExported(id)
        case .needsPro: showPaywall = true
        case .checking: message = L10n.labelCheckFailed
        case .failed: message = L10n.labelFailed
        }
    }
}
