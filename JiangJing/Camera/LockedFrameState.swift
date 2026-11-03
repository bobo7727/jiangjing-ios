import Foundation

/// All mutable state is protected by lock. Frames are treated as read-only after
/// delivery, including snapshots used outside the lock for photo rendering.
final class LockedFrameState<Frame>: @unchecked Sendable {
    private let lock = NSLock()
    private var latestFrame: Frame?
    private var accepting = false
    private var generation = UUID()
    private var didReportFirstFrame = false
    private var pendingArm: UUID?

    func prepareToArm() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let token = UUID()
        accepting = false
        latestFrame = nil
        pendingArm = token
        return token
    }

    @discardableResult func arm(token: UUID, generation: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard pendingArm == token else { return false }
        pendingArm = nil
        self.generation = generation
        didReportFirstFrame = false
        latestFrame = nil
        accepting = true
        return true
    }

    func stopAccepting() {
        lock.lock()
        defer { lock.unlock() }
        accepting = false
        latestFrame = nil
        pendingArm = nil
    }

    /// Returns the generation only for its first accepted frame.
    func receive(_ frame: Frame) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard accepting else { return nil }
        latestFrame = frame
        guard !didReportFirstFrame else { return nil }
        didReportFirstFrame = true
        return generation
    }

    func snapshot(for generation: UUID) -> Frame? {
        lock.lock()
        defer { lock.unlock() }
        guard accepting, self.generation == generation else { return nil }
        return latestFrame
    }
}
