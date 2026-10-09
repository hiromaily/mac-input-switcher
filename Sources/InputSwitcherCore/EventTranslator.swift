import CoreGraphics
import Foundation

/// Converts raw CGEvent fields into detector input events.
public enum EventTranslator {
    public static let leftCommandKeyCode: Int64 = 55
    public static let rightCommandKeyCode: Int64 = 54
    static let leftCommandDeviceMask: UInt64 = 0x08  // NX_DEVICELCMDKEYMASK
    static let rightCommandDeviceMask: UInt64 = 0x10  // NX_DEVICERCMDKEYMASK

    /// Device-dependent flag bit for each Command key, keyed by key code.
    private static let commandKeys: [Int64: (side: Side, deviceMask: UInt64)] = [
        leftCommandKeyCode: (.left, leftCommandDeviceMask),
        rightCommandKeyCode: (.right, rightCommandDeviceMask),
    ]

    public static func translate(
        type: CGEventType,
        keyCode: Int64,
        flags: CGEventFlags,
        timestamp: TimeInterval
    ) -> InputEvent? {
        switch type {
        case .flagsChanged:
            guard let key = commandKeys[keyCode] else { return .otherModifierChanged }
            let isDown = flags.rawValue & key.deviceMask != 0
            return isDown
                ? .commandDown(side: key.side, timestamp: timestamp)
                : .commandUp(side: key.side, timestamp: timestamp)
        case .keyDown:
            return .keyDown
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return .mouseDown
        default:
            return nil
        }
    }
}
