import CoreGraphics
import Testing
@testable import InputSwitcherCore

@Suite struct EventTranslatorTests {
    private let commandFlag = CGEventFlags.maskCommand.rawValue

    @Test func leftCommandDownAndUp() {
        let down = EventTranslator.translate(
            type: .flagsChanged, keyCode: 55,
            flags: CGEventFlags(rawValue: commandFlag | 0x08), timestamp: 1)
        #expect(down == .commandDown(side: .left, timestamp: 1))
        let up = EventTranslator.translate(
            type: .flagsChanged, keyCode: 55, flags: [], timestamp: 2)
        #expect(up == .commandUp(side: .left, timestamp: 2))
    }

    @Test func rightCommandDownAndUp() {
        let down = EventTranslator.translate(
            type: .flagsChanged, keyCode: 54,
            flags: CGEventFlags(rawValue: commandFlag | 0x10), timestamp: 1)
        #expect(down == .commandDown(side: .right, timestamp: 1))
        let up = EventTranslator.translate(
            type: .flagsChanged, keyCode: 54, flags: [], timestamp: 2)
        #expect(up == .commandUp(side: .right, timestamp: 2))
    }

    @Test func rightCommandReleasedWhileLeftHeldIsUp() {
        // Left still held: maskCommand and left device bit remain set.
        let up = EventTranslator.translate(
            type: .flagsChanged, keyCode: 54,
            flags: CGEventFlags(rawValue: commandFlag | 0x08), timestamp: 3)
        #expect(up == .commandUp(side: .right, timestamp: 3))
    }

    @Test(arguments: [Int64(56), 57, 58, 59, 63])  // shift, caps lock, option, control, fn
    func otherModifiersCancel(keyCode: Int64) {
        let event = EventTranslator.translate(
            type: .flagsChanged, keyCode: keyCode, flags: [], timestamp: 0)
        #expect(event == .otherModifierChanged)
    }

    @Test func regularKeyDown() {
        let event = EventTranslator.translate(type: .keyDown, keyCode: 8, flags: .maskCommand, timestamp: 0)
        #expect(event == .keyDown)
    }

    @Test(arguments: [Int64(102), 104])
    func synthesizedEisuKanaKeysAreIgnored(keyCode: Int64) {
        #expect(EventTranslator.translate(type: .keyDown, keyCode: keyCode, flags: [], timestamp: 0) == nil)
    }

    @Test(arguments: [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown])
    func mouseDown(type: CGEventType) {
        #expect(EventTranslator.translate(type: type, keyCode: 0, flags: [], timestamp: 0) == .mouseDown)
    }

    @Test func unrelatedEventsAreIgnored() {
        #expect(EventTranslator.translate(type: .keyUp, keyCode: 8, flags: [], timestamp: 0) == nil)
    }
}
