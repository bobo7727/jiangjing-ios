import Foundation

enum SaveState: String, Codable, Equatable, Sendable {
    case pending, saving, saved, denied, failed, uncertain
}

struct MediaRecord: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case photo, video }
    let id: UUID
    let kind: Kind
    let createdAt: Date
    var isComplete: Bool
    var saveState: SaveState
    var duration: TimeInterval?

    var filename: String { kind == .photo ? "media.jpg" : "media.mov" }
}

/// All journal mutations are confined to the main actor by MediaLibraryModel.
/// Each file has its own atomic sidecar, so a corrupt record cannot erase others.
/// Unknown and incomplete files are retained, never evicted to make space.
struct MediaJournal: Sendable {
    let directory: URL

    func url(for record: MediaRecord) -> URL {
        directory.appendingPathComponent(record.id.uuidString, isDirectory: true)
            .appendingPathComponent(record.filename)
    }

    func write(_ record: MediaRecord) throws {
        let folder = url(for: record).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        try data.write(to: folder.appendingPathComponent("record.json"), options: .atomic)
    }

    func load() throws -> [MediaRecord] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let folders = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        return folders.compactMap { (folder: URL) -> MediaRecord? in
            guard let id = UUID(uuidString: folder.lastPathComponent) else { return nil }
            let sidecar = folder.appendingPathComponent("record.json")
            if let data = try? Data(contentsOf: sidecar),
               var record = try? JSONDecoder().decode(MediaRecord.self, from: data),
               record.id == id {
                // Photos may have committed just before termination. Never
                // automatically retry a save whose result is unknown.
                if record.saveState == .saving { record.saveState = .uncertain }
                return record
            }
            let kind: MediaRecord.Kind
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("media.jpg").path) {
                kind = .photo
            } else if FileManager.default.fileExists(atPath: folder.appendingPathComponent("media.mov").path) {
                kind = .video
            } else {
                return nil
            }
            let recovered = MediaRecord(id: id, kind: kind, createdAt: .distantPast,
                                        isComplete: false, saveState: .uncertain)
            return recovered
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func remove(_ record: MediaRecord) throws {
        try FileManager.default.removeItem(at: url(for: record).deletingLastPathComponent())
    }
}

/// Saving/sharing/recording holds a lease, including while the UI is dismissed.
struct MediaLeases: Sendable {
    private var counts: [UUID: Int] = [:]
    mutating func acquire(_ id: UUID) { counts[id, default: 0] += 1 }
    mutating func release(_ id: UUID) {
        guard let count = counts[id] else { return }
        if count <= 1 { counts.removeValue(forKey: id) } else { counts[id] = count - 1 }
    }
    func contains(_ id: UUID) -> Bool { counts[id, default: 0] > 0 }
}
