import Testing
@testable import InputSwitcherCore

@Suite struct CommandTapDetectorTests {
    @Test func leftTapSwitchesToEnglish() {
        var detector = CommandTapDetector()
        #expect(detector.handle(.commandDown(side: .left, timestamp: 0)) == nil)
        #expect(detector.handle(.commandUp(side: .left, timestamp: 0.1)) == .switchToEnglish)
    }

    @Test func rightTapSwitchesToJapanese() {
        var detector = CommandTapDetector()
        #expect(detector.handle(.commandDown(side: .right, timestamp: 0)) == nil)
        #expect(detector.handle(.commandUp(side: .right, timestamp: 0.1)) == .switchToJapanese)
    }

    @Test(arguments: [InputEvent.keyDown, .mouseDown, .otherModifierChanged])
    func interveningEventCancels(event: InputEvent) {
        var detector = CommandTapDetector()
        _ = detector.handle(.commandDown(side: .left, timestamp: 0))
        #expect(detector.handle(event) == nil)
        #expect(detector.handle(.commandUp(side: .left, timestamp: 0.1)) == nil)
    }

    @Test func longPressDoesNotSwitch() {
        var detector = CommandTapDetector()
        _ = detector.handle(.commandDown(side: .left, timestamp: 0))
        #expect(detector.handle(.commandUp(side: .left, timestamp: 0.51)) == nil)
    }

    @Test func releaseExactlyAtThresholdSwitches() {
        var detector = CommandTapDetector()
        _ = detector.handle(.commandDown(side: .left, timestamp: 1.0))
        #expect(detector.handle(.commandUp(side: .left, timestamp: 1.5)) == .switchToEnglish)
    }

    @Test func bothCommandsPressedDoesNotSwitch() {
        var detector = CommandTapDetector()
        _ = detector.handle(.commandDown(side: .left, timestamp: 0))
        _ = detector.handle(.commandDown(side: .right, timestamp: 0.05))
        #expect(detector.handle(.commandUp(side: .right, timestamp: 0.1)) == nil)
        #expect(detector.handle(.commandUp(side: .left, timestamp: 0.15)) == nil)
        _ = detector.handle(.commandDown(side: .right, timestamp: 1))
        #expect(detector.handle(.commandUp(side: .right, timestamp: 1.1)) == .switchToJapanese)
    }

    @Test func recoversAfterCancellation() {
        var detector = CommandTapDetector()
        _ = detector.handle(.commandDown(side: .left, timestamp: 0))
        _ = detector.handle(.keyDown)
        _ = detector.handle(.commandUp(side: .left, timestamp: 0.1))
        _ = detector.handle(.commandDown(side: .left, timestamp: 1))
        #expect(detector.handle(.commandUp(side: .left, timestamp: 1.1)) == .switchToEnglish)
    }

    @Test func customThresholdIsHonored() {
        var detector = CommandTapDetector(threshold: 0.2)
        _ = detector.handle(.commandDown(side: .right, timestamp: 0))
        #expect(detector.handle(.commandUp(side: .right, timestamp: 0.3)) == nil)
    }

    @Test func recoversWhenKeyUpWasLost() {
        var detector = CommandTapDetector()
        _ = detector.handle(.commandDown(side: .left, timestamp: 0))
        // key-up never arrives
        _ = detector.handle(.commandDown(side: .left, timestamp: 5))
        #expect(detector.handle(.commandUp(side: .left, timestamp: 5.1)) == .switchToEnglish)
    }

    @Test func strayKeyUpIsIgnored() {
        var detector = CommandTapDetector()
        #expect(detector.handle(.commandUp(side: .right, timestamp: 0)) == nil)
        _ = detector.handle(.commandDown(side: .right, timestamp: 1))
        #expect(detector.handle(.commandUp(side: .right, timestamp: 1.1)) == .switchToJapanese)
    }
}
