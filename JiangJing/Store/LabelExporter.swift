import Foundation

enum LabelExportResult: Equatable {
    /// A new labeled copy was written, registered and a Photos save was started.
    case exported(UUID)
    /// Pro is not unlocked: show the paywall. Nothing was written.
    case needsPro
    /// Purchase state could not be confirmed in time: offer retry/restore, never a purchase. Nothing was written.
    case checking
    case failed
}

/// The only place that gates a feature on Pro. It makes a NEW copy; the original photo is never touched.
@MainActor
struct LabelExporter {
    let store: StoreManager
    let media: MediaLibraryModel

    func export(sourceURL: URL, style: LabelStyle, date: Date = Date()) async -> LabelExportResult {
        switch await store.resolvedProStatus() {
        case .unknown: return .checking
        case .locked: return .needsPro
        case .unlocked: break
        }
        let text = style.stampText(date: date)
        guard !text.isEmpty else { return .failed }
        let position = style.position
        let quality = MagnifierConfig.jpegQuality
        let data = await Task.detached(priority: .userInitiated) {
            LabelRenderer.stampedJPEG(from: sourceURL, text: text, position: position, quality: quality)
        }.value
        guard let data else { return .failed }
        let record: MediaRecord
        do { record = try media.reserve(.photo) } catch { return .failed }
        var wrote = true
        do { try data.write(to: media.url(for: record), options: .atomic) } catch { wrote = false }
        media.finish(record.id, complete: wrote)
        guard wrote else { return .failed }
        // Auto-save a copy to Photos (add-only), same path as every capture.
        await media.save(record.id)
        return .exported(record.id)
    }
}
