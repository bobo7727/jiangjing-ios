import XCTest
@testable import JiangJing

final class MediaLibraryModelTests: XCTestCase {
    @MainActor func testDelayedAFailureDoesNotChangeBOrLoseEitherFile() async throws {
        let journal = makeJournal()
        defer { try? FileManager.default.removeItem(at: journal.directory) }
        var finishA: CheckedContinuation<Void, Error>?
        let library = MediaLibraryModel(journal: journal, isActive: { true }) { _, _ in
            try await withCheckedThrowingContinuation { finishA = $0 }
        }
        let a = try library.reserve(.photo)
        try Data([1]).write(to: library.url(for: a))
        library.finish(a.id, complete: true)
        let save = Task { await library.save(a.id) }
        for _ in 0..<1_000 where finishA == nil { await Task.yield() }
        guard let finishA else { XCTFail("Save did not enter the injected operation"); save.cancel(); return }
        let b = try library.reserve(.video)
        try Data([2]).write(to: library.url(for: b))
        library.finish(b.id, complete: true)
        library.discard(a.id) // Saving holds a lease even if the UI closed.
        XCTAssertNotNil(library.record(a.id))
        finishA.resume(throwing: SaveError.denied)
        await save.value
        XCTAssertEqual(library.record(a.id)?.saveState, .denied)
        XCTAssertEqual(library.record(b.id)?.saveState, .pending)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.url(for: a).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.url(for: b).path))
        let restored = try journal.load()
        XCTAssertEqual(restored.first { $0.id == a.id }?.saveState, .denied)
    }

    @MainActor func testInactiveDefersPhotosAndShareLeaseBlocksDiscard() async throws {
        let journal = makeJournal()
        defer { try? FileManager.default.removeItem(at: journal.directory) }
        var calls = 0
        let library = MediaLibraryModel(journal: journal, isActive: { false }) { _, _ in calls += 1 }
        let record = try library.reserve(.video)
        try Data([1]).write(to: library.url(for: record))
        library.finish(record.id, complete: true)
        await library.save(record.id)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(library.record(record.id)?.saveState, .pending)
        library.acquire(record.id)
        library.discard(record.id)
        XCTAssertNotNil(library.record(record.id))
        library.release(record.id)
        library.discard(record.id)
        XCTAssertNil(library.record(record.id))
    }

    @MainActor func testExpirationRequiresExplicitRetryUntilDefiniteCompletion() async throws {
        let journal = makeJournal()
        defer { try? FileManager.default.removeItem(at: journal.directory) }
        var completion: CheckedContinuation<Void, Error>?
        let library = MediaLibraryModel(journal: journal, isActive: { true }) { _, _ in
            try await withCheckedThrowingContinuation { completion = $0 }
        }
        let record = try library.reserve(.video)
        library.finish(record.id, complete: true)
        let task = Task { await library.save(record.id) }
        for _ in 0..<1_000 where completion == nil { await Task.yield() }
        guard let completion else { XCTFail("Save did not start"); task.cancel(); return }
        library.markInFlightUncertain()
        XCTAssertEqual(library.record(record.id)?.saveState, .uncertain)
        XCTAssertFalse(library.canDiscard(record.id))
        completion.resume()
        await task.value
        XCTAssertEqual(library.record(record.id)?.saveState, .saved)
        XCTAssertTrue(library.canDiscard(record.id))
    }

    @MainActor func testUnknownResultIsNotAutomaticallySavedAgainAfterRestart() async throws {
        let journal = makeJournal()
        defer { try? FileManager.default.removeItem(at: journal.directory) }
        let record = MediaRecord(id: UUID(), kind: .photo, createdAt: Date(), isComplete: true, saveState: .saving)
        try journal.write(record)
        var calls = 0
        let library = MediaLibraryModel(journal: journal, isActive: { true }) { _, _ in calls += 1 }
        // A later file verification must not erase an unknown save result.
        library.finish(record.id, complete: true)
        await library.resumePending()
        XCTAssertEqual(library.record(record.id)?.saveState, .uncertain)
        XCTAssertEqual(calls, 0)
        await library.save(record.id, explicitlyRetry: true)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(library.record(record.id)?.saveState, .saved)
    }

    private func makeJournal() -> MediaJournal {
        // Test sandbox only; never touches the app's actual media directory.
        MediaJournal(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }
}
