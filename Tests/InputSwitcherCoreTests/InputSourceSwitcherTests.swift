import Testing

@testable import InputSwitcherCore

@Suite struct InputSourceSwitcherTests {
    @Test func englishUsesEisuKey() {
        #expect(JISKeyInputSourceSwitcher.keyCode(for: .switchToEnglish) == 102)
    }

    @Test func japaneseUsesKanaKey() {
        #expect(JISKeyInputSourceSwitcher.keyCode(for: .switchToJapanese) == 104)
    }

    @Test func recognizesOnlyItsOwnEventMarker() {
        #expect(JISKeyInputSourceSwitcher.isSynthesized(userData: JISKeyInputSourceSwitcher.eventMarker))
        #expect(!JISKeyInputSourceSwitcher.isSynthesized(userData: 0))
    }
}
