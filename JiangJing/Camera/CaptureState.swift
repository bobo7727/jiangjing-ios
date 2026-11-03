import Foundation

/// Main-thread capture admission. A pending stop survives the recorder's
/// asynchronous start callback. Session operations still use sessionQueue.
struct CaptureState: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case idle, photo, starting, recording, stopping }
    private(set) var phase: Phase = .idle
    private(set) var generation = UUID()
    private(set) var ready = false
    private(set) var active = false

    var isRecording: Bool { [.starting, .recording, .stopping].contains(phase) }

    mutating func resume() -> UUID {
        active = true
        return invalidate()
    }

    @discardableResult mutating func invalidate() -> UUID {
        generation = UUID()
        ready = false
        return generation
    }

    mutating func suspend() {
        active = false
        invalidate()
        requestStop()
    }

    mutating func firstFrame(for token: UUID) -> Bool {
        guard active, generation == token, !ready else { return false }
        ready = true
        return true
    }

    mutating func beginPhoto() -> Bool {
        guard active, ready, phase == .idle else { return false }
        phase = .photo
        return true
    }

    mutating func beginRecording() -> Bool {
        guard active, ready, phase == .idle else { return false }
        phase = .starting
        return true
    }

    mutating func requestStop() {
        if isRecording { phase = .stopping }
    }

    /// Returns whether an earlier stop must be fulfilled immediately.
    mutating func recordingDidStart() -> Bool {
        guard isRecording else { return false }
        if phase == .stopping { return true }
        phase = .recording
        return false
    }

    mutating func finish() { phase = .idle }
}

/// Session-queue preference survives hardware teardown, including failed reattach.
struct AudioPreference: Sendable {
    private(set) var requested = false
    mutating func select(_ enabled: Bool) { requested = enabled }
    func restore(attach: () -> Bool) -> Bool { requested && attach() }
}
