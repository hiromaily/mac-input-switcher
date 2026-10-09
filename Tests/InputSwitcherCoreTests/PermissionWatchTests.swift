import Testing

@testable import InputSwitcherCore

@Suite struct PermissionProbeTests {
    @Test func parsesOneNamePerLine() {
        #expect(PermissionProbe.parse("Input Monitoring\nAccessibility\n") == ["Input Monitoring", "Accessibility"])
    }

    @Test func emptyOutputMeansNothingMissing() {
        #expect(PermissionProbe.parse("") == [])
    }

    @Test func ignoresBlankLinesAndSurroundingWhitespace() {
        #expect(PermissionProbe.parse("\n  Accessibility \n\n") == ["Accessibility"])
    }
}

@Suite struct PermissionWatchTests {
    @Test func firstUpdateLogsWhatIsMissing() {
        var watch = PermissionWatch()
        #expect(
            watch.update(missing: ["Input Monitoring", "Accessibility"])
                == .wait(log: "waiting for permissions: Input Monitoring, Accessibility"))
    }

    @Test func unchangedMissingDoesNotLogAgain() {
        var watch = PermissionWatch()
        _ = watch.update(missing: ["Accessibility"])
        #expect(watch.update(missing: ["Accessibility"]) == .wait(log: nil))
    }

    @Test func changedMissingLogsAgain() {
        var watch = PermissionWatch()
        _ = watch.update(missing: ["Input Monitoring", "Accessibility"])
        #expect(watch.update(missing: ["Accessibility"]) == .wait(log: "waiting for permissions: Accessibility"))
    }

    @Test func allGrantedRestarts() {
        var watch = PermissionWatch()
        _ = watch.update(missing: ["Accessibility"])
        #expect(watch.update(missing: []) == .restart(log: "all permissions granted; restarting"))
    }
}
