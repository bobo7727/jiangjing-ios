/// One assertion's lifecycle, independent of the controller that requested it.
@MainActor final class BackgroundTaskLifetime<Identifier: Equatable> {
    private enum State {
        case pending
        case armed(Identifier)
        case ended
    }

    private var state = State.pending
    private var hasArmed = false
    private let invalid: Identifier
    private let endAssertion: @MainActor (Identifier) -> Void

    init(invalid: Identifier, end: @escaping @MainActor (Identifier) -> Void) {
        self.invalid = invalid
        endAssertion = end
    }

    var isEnded: Bool {
        if case .ended = state { return true }
        return false
    }

    func arm(_ identifier: Identifier) {
        guard !hasArmed else { return }
        hasArmed = true
        guard identifier != invalid else { state = .ended; return }
        switch state {
        case .pending:
            state = .armed(identifier)
        case .ended:
            // Defensively handle expiration before beginBackgroundTask returns.
            endAssertion(identifier)
        case .armed:
            break
        }
    }

    @discardableResult func end() -> Bool {
        let previous = state
        guard !isEnded else { return false }
        state = .ended // Invalidate before calling out, including reentrant ending.
        if case let .armed(identifier) = previous { endAssertion(identifier) }
        return true
    }

    @discardableResult func expire(markUncertain: @MainActor () -> Void) -> Bool {
        guard end() else { return false }
        markUncertain()
        return true
    }

    func clearIfEnded(from current: inout BackgroundTaskLifetime?) {
        if isEnded, current === self { current = nil }
    }
}
