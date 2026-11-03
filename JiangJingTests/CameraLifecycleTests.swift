import Foundation
import XCTest
#if canImport(CaptureCore)
@testable import CaptureCore
#else
@testable import JiangJing
#endif

final class BackgroundTaskLifetimeTests: XCTestCase {
    @MainActor func testExpirationBeforeArmingEndsReturnedIdentifierOnce() async {
        var ended: [Int] = []
        var marks = 0
        let task = BackgroundTaskLifetime(invalid: -1) { ended.append($0) }
        XCTAssertTrue(task.expire { marks += 1 })
        XCTAssertTrue(task.isEnded)
        XCTAssertTrue(ended.isEmpty)
        task.arm(7)
        task.arm(7)
        XCTAssertFalse(task.end())
        XCTAssertFalse(task.expire { marks += 1 })
        XCTAssertEqual(ended, [7])
        XCTAssertEqual(marks, 1)
    }

    @MainActor func testExpirationEndsThenMarksBeforeReturning() async {
        var events: [String] = []
        let task = BackgroundTaskLifetime(invalid: -1) { events.append("end \($0)") }
        task.arm(7)
        let handler: @MainActor @Sendable () -> Void = {
            task.expire { events.append("mark") }
        }
        handler()
        XCTAssertEqual(events, ["end 7", "mark"])
        XCTAssertFalse(task.end())
        handler()
        XCTAssertEqual(events, ["end 7", "mark"])
    }

    @MainActor func testCompletionMakesLaterExpirationInert() async {
        var ended: [Int] = []
        let task = BackgroundTaskLifetime(invalid: -1) { ended.append($0) }
        task.arm(9)
        XCTAssertTrue(task.end())
        XCTAssertFalse(task.expire { XCTFail("An ended assertion must not mark newer saves uncertain") })
        XCTAssertFalse(task.end())
        XCTAssertEqual(ended, [9])
    }

    @MainActor func testInvalidIdentifiersAndPendingCompletion() async {
        let invalid = BackgroundTaskLifetime(invalid: -1) { _ in XCTFail("Invalid assertion ended") }
        invalid.arm(-1)
        XCTAssertTrue(invalid.isEnded)
        XCTAssertFalse(invalid.expire { XCTFail("Invalid assertion expired") })
        let early = BackgroundTaskLifetime(invalid: -1) { _ in XCTFail("Invalid assertion ended") }
        XCTAssertTrue(early.end())
        early.arm(-1)
        XCTAssertFalse(early.end())

        var ended: [Int] = []
        let completed = BackgroundTaskLifetime(invalid: -1) { ended.append($0) }
        XCTAssertTrue(completed.end())
        completed.arm(3)
        completed.arm(3)
        XCTAssertEqual(ended, [3])
    }

    @MainActor func testOldHandlerAndMonitorCannotClearReplacement() async {
        var ended: [Int] = []
        let old = BackgroundTaskLifetime(invalid: -1) { ended.append($0) }
        let replacement = BackgroundTaskLifetime(invalid: -1) { ended.append($0) }
        var current: BackgroundTaskLifetime<Int>? = old
        old.arm(1)
        replacement.arm(2)
        old.end()
        old.clearIfEnded(from: &current)
        XCTAssertNil(current)
        current = replacement
        XCTAssertFalse(old.expire { XCTFail("Stale expiration marked saves") })
        old.clearIfEnded(from: &current)
        old.end() // An old monitor also cannot end the replacement.
        old.clearIfEnded(from: &current)
        XCTAssertTrue(current === replacement)
        XCTAssertFalse(replacement.isEnded)
        XCTAssertEqual(ended, [1])
        replacement.end()
        replacement.clearIfEnded(from: &current)
        XCTAssertNil(current)
        XCTAssertEqual(ended, [1, 2])
    }

    @MainActor func testHandlerRetainsCleanupAfterOwnerDisappearsAndEndingIsReentrant() async {
        var events: [String] = []
        var task: BackgroundTaskLifetime<Int>!
        task = BackgroundTaskLifetime(invalid: -1) { _ in
            XCTAssertTrue(task.isEnded)
            XCTAssertFalse(task.end())
            events.append("end")
        }
        var owner: LifetimeOwner? = LifetimeOwner(task)
        weak var weakOwner = owner
        let handler: @MainActor @Sendable () -> Void = { [weak owner, task = task!] in
            guard task.expire(markUncertain: { events.append("mark") }) else { return }
            owner?.clear(task)
        }
        task.arm(4)
        owner = nil
        XCTAssertNil(weakOwner)
        handler()
        XCTAssertEqual(events, ["end", "mark"])
        handler()
        XCTAssertEqual(events, ["end", "mark"])
        task = nil // Release the test's reentrant callback capture.
    }
}

@MainActor private final class LifetimeOwner {
    var current: BackgroundTaskLifetime<Int>?
    init(_ task: BackgroundTaskLifetime<Int>) { current = task }
    func clear(_ task: BackgroundTaskLifetime<Int>) { task.clearIfEnded(from: &current) }
}

final class LockedFrameStateTests: XCTestCase {
    func testBlockedFrameQueueCannotRearmAfterStop() {
        let frames = LockedFrameState<Int>()
        let queue = DispatchQueue(label: "test.frames.blocked")
        let done = expectation(description: "invalidated arm drained")
        let generation = UUID()
        queue.suspend()
        let token = frames.prepareToArm()
        queue.async {
            XCTAssertFalse(frames.arm(token: token, generation: generation))
            XCTAssertNil(frames.receive(1))
            XCTAssertNil(frames.snapshot(for: generation))
            done.fulfill()
        }
        frames.stopAccepting()
        queue.resume()
        wait(for: [done], timeout: 2)
    }

    func testNewArmSupersedesOldArmAndRejectsOldSnapshots() {
        let frames = LockedFrameState<Int>()
        let old = UUID()
        let current = UUID()
        let oldArm = frames.prepareToArm()
        let newArm = frames.prepareToArm()
        XCTAssertFalse(frames.arm(token: oldArm, generation: old))
        XCTAssertNil(frames.receive(1))
        XCTAssertTrue(frames.arm(token: newArm, generation: current))
        XCTAssertEqual(frames.receive(2), current)
        XCTAssertNil(frames.receive(3))
        XCTAssertNil(frames.snapshot(for: old))
        XCTAssertEqual(frames.snapshot(for: current), 3)
        XCTAssertFalse(frames.arm(token: newArm, generation: current))
        XCTAssertEqual(frames.snapshot(for: current), 3)
        frames.stopAccepting()
        XCTAssertNil(frames.snapshot(for: current))
    }

    func testQueuedCallbacksPreserveGenerationBoundary() {
        let frames = LockedFrameState<Int>()
        let queue = DispatchQueue(label: "test.frames.generations")
        let done = expectation(description: "callbacks drained")
        var capture = CaptureState()
        let old = capture.resume()
        XCTAssertTrue(frames.arm(token: frames.prepareToArm(), generation: old))
        let delayedReadiness = frames.receive(1)
        capture.suspend()
        let current = capture.resume()
        XCTAssertFalse(capture.firstFrame(for: delayedReadiness!))
        queue.suspend()
        queue.async { XCTAssertNil(frames.receive(2)) }
        let arm = frames.prepareToArm()
        XCTAssertNil(frames.snapshot(for: old))
        queue.async {
            XCTAssertTrue(frames.arm(token: arm, generation: current))
            XCTAssertNil(frames.snapshot(for: current))
            XCTAssertEqual(frames.receive(3), current)
            XCTAssertNil(frames.snapshot(for: old))
            XCTAssertEqual(frames.snapshot(for: current), 3)
            done.fulfill()
        }
        queue.resume()
        wait(for: [done], timeout: 2)
    }
}
