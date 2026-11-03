import Foundation
import XCTest
@testable import CaptureCore

final class MediaJournalTests: XCTestCase {
    private func withJournal(_ body: (MediaJournal) throws -> Void) throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../.build/journal-tests/\(UUID().uuidString)").standardizedFileURL
        let journal = MediaJournal(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(journal)
    }

    func testRestartRetainsDeniedVideoAndPhotoWithIndependentResults() throws {
        try withJournal { journal in
            var a = MediaRecord(id: UUID(), kind: .photo, createdAt: Date(), isComplete: true, saveState: .saving)
            let b = MediaRecord(id: UUID(), kind: .video, createdAt: Date(), isComplete: true, saveState: .denied)
            try journal.write(a)
            try journal.write(b)
            try Data([1, 2, 3]).write(to: journal.url(for: a))
            try Data([4, 5, 6]).write(to: journal.url(for: b))
            var loaded = try journal.load()
            XCTAssertEqual(loaded.first { $0.id == a.id }?.saveState, .uncertain)
            XCTAssertEqual(loaded.first { $0.id == b.id }?.saveState, .denied)
            a.saveState = .failed
            try journal.write(a)
            loaded = try journal.load()
            XCTAssertEqual(loaded.first { $0.id == a.id }?.saveState, .failed)
            XCTAssertEqual(loaded.first { $0.id == b.id }?.saveState, .denied)
            XCTAssertTrue(FileManager.default.fileExists(atPath: journal.url(for: a).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: journal.url(for: b).path))
        }
    }

    func testCorruptSidecarDoesNotDeleteOnlyCopy() throws {
        try withJournal { journal in
            let clip = MediaRecord(id: UUID(), kind: .video, createdAt: Date(), isComplete: false, saveState: .pending)
            try journal.write(clip)
            try Data([9]).write(to: journal.url(for: clip))
            try Data("broken".utf8).write(to: journal.url(for: clip).deletingLastPathComponent().appendingPathComponent("record.json"))
            let restored = try XCTUnwrap(journal.load().first)
            XCTAssertEqual(restored.id, clip.id)
            XCTAssertFalse(restored.isComplete)
            XCTAssertEqual(restored.saveState, .uncertain)
            XCTAssertTrue(FileManager.default.fileExists(atPath: journal.url(for: clip).path))
        }
    }

    func testStorageFailureIsReported() throws {
        try withJournal { journal in
            try FileManager.default.createDirectory(at: journal.directory, withIntermediateDirectories: true)
            let blocked = journal.directory.appendingPathComponent("not-a-directory")
            try Data([1]).write(to: blocked)
            let record = MediaRecord(id: UUID(), kind: .photo, createdAt: Date(), isComplete: false, saveState: .pending)
            XCTAssertThrowsError(try MediaJournal(directory: blocked).write(record))
        }
    }

    func testOverlappingShareAndSaveRetainLeaseUntilBothFinish() {
        let id = UUID()
        var leases = MediaLeases()
        leases.acquire(id)
        leases.acquire(id)
        leases.release(id)
        XCTAssertTrue(leases.contains(id))
        leases.release(id)
        XCTAssertFalse(leases.contains(id))
        leases.release(id)
        XCTAssertFalse(leases.contains(id))
    }
}
