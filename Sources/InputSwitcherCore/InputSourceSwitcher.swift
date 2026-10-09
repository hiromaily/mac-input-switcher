import CoreGraphics

public protocol InputSourceSwitching {
    func perform(_ action: Action)
}

/// Switches input source by synthesizing the JIS Eisu / Kana keys,
/// which the Japanese IME honors even on a US keyboard.
public struct JISKeyInputSourceSwitcher: InputSourceSwitching {
    public static let eisuKeyCode: CGKeyCode = 102  // kVK_JIS_Eisu
    public static let kanaKeyCode: CGKeyCode = 104  // kVK_JIS_Kana
    /// Stored in `eventSourceUserData` so the event tap can skip events posted by this switcher.
    public static let eventMarker: Int64 = 0x4D49_5357  // "MISW"

    public static func isSynthesized(userData: Int64) -> Bool {
        userData == eventMarker
    }

    public init() {}

    public static func keyCode(for action: Action) -> CGKeyCode {
        switch action {
        case .switchToEnglish: eisuKeyCode
        case .switchToJapanese: kanaKeyCode
        }
    }

    public func perform(_ action: Action) {
        let keyCode = Self.keyCode(for: action)
        let source = CGEventSource(stateID: .privateState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
                continue
            }
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}
