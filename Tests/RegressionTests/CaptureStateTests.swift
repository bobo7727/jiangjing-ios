import XCTest
@testable import CaptureCore

final class CaptureStateTests: XCTestCase {
    func testEarlyStopSurvivesDelayedStart() {
        var state = CaptureState()
        let generation = state.resume()
        XCTAssertTrue(state.firstFrame(for: generation))
        XCTAssertTrue(state.beginRecording())
        XCTAssertFalse(state.beginPhoto())
        state.requestStop()
        XCTAssertTrue(state.isRecording)
        XCTAssertTrue(state.recordingDidStart())
        XCTAssertEqual(state.phase, .stopping)
        state.finish()
        XCTAssertTrue(state.beginPhoto())
        XCTAssertFalse(state.beginRecording())
    }

    func testOldFramesCannotRestoreReadiness() {
        var state = CaptureState()
        let old = state.resume()
        XCTAssertTrue(state.firstFrame(for: old))
        state.suspend()
        XCTAssertFalse(state.ready)
        XCTAssertFalse(state.firstFrame(for: old))
        let current = state.resume()
        XCTAssertFalse(state.firstFrame(for: old))
        XCTAssertFalse(state.beginRecording())
        XCTAssertTrue(state.firstFrame(for: current))
        XCTAssertFalse(state.firstFrame(for: current)) // Only one UI notification.
    }

    func testReadinessLossDoesNotPreventStop() {
        var state = CaptureState()
        let token = state.resume()
        XCTAssertTrue(state.firstFrame(for: token))
        XCTAssertTrue(state.beginRecording())
        XCTAssertFalse(state.recordingDidStart())
        state.invalidate()
        state.requestStop()
        XCTAssertEqual(state.phase, .stopping)
        state.suspend()
        XCTAssertEqual(state.phase, .stopping)
        state.finish()
        XCTAssertFalse(state.beginPhoto())
    }
    func testAudioPreferenceSurvivesFailedSessionRebuild() {
        var preference = AudioPreference()
        var attempts = 0
        XCTAssertFalse(preference.restore { attempts += 1; return true })
        XCTAssertEqual(attempts, 0)
        preference.select(true)
        XCTAssertTrue(preference.restore { true })
        XCTAssertFalse(preference.restore { false })
        XCTAssertTrue(preference.requested)
        XCTAssertTrue(preference.restore { true })
        preference.select(false)
        XCTAssertFalse(preference.restore { attempts += 1; return true })
        XCTAssertEqual(attempts, 0)
    }
}
