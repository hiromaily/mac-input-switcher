import Foundation

public enum Side: Sendable, Equatable {
    case left, right
}

public enum InputEvent: Sendable, Equatable {
    case commandDown(side: Side, timestamp: TimeInterval)
    case commandUp(side: Side, timestamp: TimeInterval)
    case otherModifierChanged
    case keyDown
    case mouseDown
}

public enum Action: Sendable, Equatable {
    case switchToEnglish, switchToJapanese
}

/// Detects a lone tap of the left or right Command key.
public struct CommandTapDetector: Sendable {
    public static let defaultThreshold: TimeInterval = 0.5

    private enum State: Equatable {
        case idle
        case pending(side: Side, start: TimeInterval)
        case cancelled
    }

    public let threshold: TimeInterval
    private var state: State = .idle
    private var pressed: Set<Side> = []

    public init(threshold: TimeInterval = CommandTapDetector.defaultThreshold) {
        self.threshold = threshold
    }

    public mutating func handle(_ event: InputEvent) -> Action? {
        switch event {
        case let .commandDown(side, timestamp):
            if pressed.contains(side) {
                // The previous key-up for this side was lost (e.g. swallowed by Secure Input).
                pressed.removeAll()
                state = .idle
            }
            pressed.insert(side)
            switch state {
            case .idle:
                state = .pending(side: side, start: timestamp)
            case .pending:
                state = .cancelled
            case .cancelled:
                break
            }
            return nil

        case let .commandUp(side, timestamp):
            pressed.remove(side)
            guard case let .pending(pendingSide, start) = state, pendingSide == side else {
                if pressed.isEmpty { state = .idle }
                return nil
            }
            state = .idle
            guard timestamp - start <= threshold else { return nil }
            return side == .left ? .switchToEnglish : .switchToJapanese

        case .otherModifierChanged, .keyDown, .mouseDown:
            if case .pending = state { state = .cancelled }
            return nil
        }
    }
}
