import AVFoundation
import Combine
import Photos
import UIKit

@MainActor
final class MediaLibraryModel: ObservableObject {
    @Published private(set) var records: [MediaRecord] = []
    @Published var storageError = false
    @Published var shareError = false
    /// Display-only sizes in bytes by record, and the device's free-space estimate.
    @Published private(set) var usage: [UUID: Int64] = [:]
    @Published private(set) var availableBytes: Int64?
    private let journal: MediaJournal
    private let isActive: @MainActor () -> Bool
    private let saveFile: @MainActor (URL, MediaRecord.Kind) async throws -> Void
    private let availableCapacity: @Sendable () -> Int64?
    private var leases = MediaLeases()
    private var saving: Set<UUID> = []
    private var verifying: Set<UUID> = []
    private var storageRefreshGeneration = 0

    convenience init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingMedia", isDirectory: true)
        self.init(journal: MediaJournal(directory: root),
                  isActive: { UIApplication.shared.applicationState == .active },
                  availableCapacity: { MediaLibraryModel.deviceAvailableCapacity() },
                  saveFile: { try await PhotoLibrarySaver.saveFile(at: $0, kind: $1) })
        do {
            var resource = root
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try resource.setResourceValues(values)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path
            )
        } catch { storageError = true }
    }

    /// Test seam for delayed Photos completions, denied access and inactivity.
    init(journal: MediaJournal, isActive: @escaping @MainActor () -> Bool,
         availableCapacity: @escaping @Sendable () -> Int64? = { nil },
         saveFile: @escaping @MainActor (URL, MediaRecord.Kind) async throws -> Void) {
        self.journal = journal
        self.isActive = isActive
        self.availableCapacity = availableCapacity
        self.saveFile = saveFile
        do { records = try journal.load() }
        catch { storageError = true }
    }

    /// Free space the system reports for important (user-initiated) data. It is an
    /// estimate; the system may purge caches to make more room.
    nonisolated static func deviceAvailableCapacity() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    var totalUsage: Int64 { StorageSpace.total(usage) }
    var isLowSpace: Bool { StorageSpace.isLow(available: availableBytes) }

    /// Measures files off the main actor; never blocks the UI and never deletes.
    func refreshStorage() async {
        storageRefreshGeneration += 1
        let generation = storageRefreshGeneration
        let journal = journal
        let snapshot = records
        let capacity = availableCapacity
        let (sizes, available) = await Task.detached(priority: .utility) {
            var sizes: [UUID: Int64] = [:]
            for record in snapshot { sizes[record.id] = journal.diskUsage(of: record) }
            return (sizes, capacity())
        }.value
        // A newer refresh started meanwhile; never let this older measurement win.
        guard generation == storageRefreshGeneration else { return }
        let live = Set(records.map(\.id))
        usage = sizes.filter { live.contains($0.key) }
        availableBytes = available
    }

    func url(for record: MediaRecord) -> URL { journal.url(for: record) }
    func record(_ id: UUID) -> MediaRecord? { records.first { $0.id == id } }

    func reserve(_ kind: MediaRecord.Kind) throws -> MediaRecord {
        let record = MediaRecord(id: UUID(), kind: kind, createdAt: Date(),
                                 isComplete: false, saveState: .pending)
        try journal.write(record) // Reserve persistently before writing/capturing.
        records.insert(record, at: 0)
        leases.acquire(record.id)
        return record
    }

    func finish(_ id: UUID, complete: Bool, duration: TimeInterval? = nil) {
        leases.release(id)
        guard var record = record(id) else { return }
        record.isComplete = complete
        record.duration = duration
        if record.saveState != .uncertain {
            record.saveState = complete ? .pending : .failed
        }
        update(record)
    }

    func acquire(_ id: UUID) {
        objectWillChange.send()
        leases.acquire(id)
    }
    func release(_ id: UUID) {
        objectWillChange.send()
        leases.release(id)
    }
    func canDiscard(_ id: UUID) -> Bool { !leases.contains(id) }

    func share(_ id: UUID) {
        guard let record = record(id), record.isComplete else { return }
        guard FileManager.default.fileExists(atPath: url(for: record).path) else {
            shareError = true
            return
        }
        acquire(id)
        let presented = ShareCenter.present(items: [url(for: record)]) { [weak self] in
            Task { @MainActor in self?.release(id) }
        }
        if !presented {
            release(id)
            shareError = true
        }
    }

    func discard(_ id: UUID) {
        guard !leases.contains(id), let record = record(id) else { return }
        do {
            try journal.remove(record)
            records.removeAll { $0.id == id }
        } catch { storageError = true }
    }

    func save(_ id: UUID, explicitlyRetry: Bool = false) async {
        guard var record = record(id), record.isComplete, !saving.contains(id),
              record.saveState != .saved,
              record.saveState != .uncertain || explicitlyRetry else { return }
        // Never initiate an authorization alert while inactive or in background.
        guard isActive() else { return }
        let url = url(for: record)
        record.saveState = .saving
        guard update(record) else {
            record.saveState = .pending
            if let index = records.firstIndex(where: { $0.id == id }) { records[index] = record }
            return
        }
        saving.insert(id)
        leases.acquire(id)
        defer {
            saving.remove(id)
            leases.release(id)
        }
        let state: SaveState
        do {
            try await saveFile(url, record.kind)
            state = .saved
        } catch SaveError.denied { state = .denied
        } catch SaveError.deferredAuthorization { state = .pending
        } catch { state = .failed }
        // Expiration may have marked the operation uncertain. A definite Photos
        // completion can still resolve it, always against this media ID.
        guard var current = self.record(id) else { return }
        current.saveState = state
        update(current)
    }

    func markInFlightUncertain() {
        for id in saving {
            guard var record = record(id) else { continue }
            record.saveState = .uncertain
            update(record)
        }
    }

    func resumePending() async {
        // Verify incomplete output after restart. An unfinalized .mov may fail;
        // keep it and expose explicit discard instead of promising recovery.
        for record in records where !record.isComplete && !leases.contains(record.id) {
            await verify(record.id)
        }
        for record in records where record.saveState == .pending && record.isComplete {
            guard isActive() else { return }
            await save(record.id)
        }
    }

    func verify(_ id: UUID) async {
        guard let record = record(id), !record.isComplete,
              !leases.contains(id), !verifying.contains(id) else { return }
        verifying.insert(id)
        leases.acquire(id)
        let url = url(for: record)
        var complete = false
        var duration: TimeInterval?
        if record.kind == .photo {
            complete = UIImage(contentsOfFile: url.path) != nil
        } else {
            let asset = AVURLAsset(url: url)
            if let playable = try? await asset.load(.isPlayable), playable,
               let time = try? await asset.load(.duration), time.seconds.isFinite, time.seconds > 0 {
                complete = true
                duration = time.seconds
            }
        }
        verifying.remove(id)
        finish(id, complete: complete, duration: duration)
    }

    @discardableResult private func update(_ record: MediaRecord) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return false }
        do {
            try journal.write(record)
            records[index] = record
            return true
        } catch {
            // Reflect the real result even if its durable update failed. Files
            // remain retained; a restart treats a stale saving record as uncertain.
            records[index] = record
            storageError = true
            return false
        }
    }
}
