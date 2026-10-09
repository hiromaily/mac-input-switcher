import Testing
@testable import InputSwitcherCore

@Suite struct InputSourceSwitcherTests {
    @Test func englishUsesEisuKey() {
        #expect(JISKeyInputSourceSwitcher.keyCode(for: .switchToEnglish) == 102)
    }

    @Test func japaneseUsesKanaKey() {
        #expect(JISKeyInputSourceSwitcher.keyCode(for: .switchToJapanese) == 104)
    }
}
