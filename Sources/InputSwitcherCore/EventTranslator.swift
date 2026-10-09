import CoreGraphics
import Foundation

/// Converts raw CGEvent fields into detector input events.
public enum EventTranslator {
    public static let leftCommandKeyCode: Int64 = 55
    public static let rightCommandKeyCode: Int64 = 54
    static let leftCommandDeviceMask: UInt64 = 0x08   // NX_DEVICELCMDKEYMASK
    static let rightCommandDeviceMask: UInt64 = 0x10  // NX_DEVICERCMDKEYMASK

    public static func translate(
        type: CGEventType,
        keyCode: Int64,
        flags: CGEventFlags,
        timestamp: TimeInterval
    ) -> InputEvent? {
        switch type {
        case .flagsChanged:
            switch keyCode {
            case leftCommandKeyCode:
                let isDown = flags.rawValue & leftCommandDeviceMask != 0
                return isDown ? .commandDown(side: .left, timestamp: timestamp)
                              : .commandUp(side: .left, timestamp: timestamp)
            case rightCommandKeyCode:
                let isDown = flags.rawValue & rightCommandDeviceMask != 0
                return isDown ? .commandDown(side: .right, timestamp: timestamp)
                              : .commandUp(side: .right, timestamp: timestamp)
            default:
                return .otherModifierChanged
            }
        case .keyDown:
            let synthesized = [
                Int64(JISKeyInputSourceSwitcher.eisuKeyCode),
                Int64(JISKeyInputSourceSwitcher.kanaKeyCode),
            ]
            return synthesized.contains(keyCode) ? nil : .keyDown
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return .mouseDown
        default:
            return nil
        }
    }
}
