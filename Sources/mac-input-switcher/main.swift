import ApplicationServices
import CoreGraphics
import Foundation
import InputSwitcherCore

func log(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("\(timestamp) \(message)\n".utf8))
}

final class TapContext {
    var detector = CommandTapDetector()
    let switcher: InputSourceSwitching = JISKeyInputSourceSwitcher()
    var tap: CFMachPort?
}

/// Returns the names of missing permissions. System prompts are shown only when `prompt` is true.
func missingPermissions(prompt: Bool) -> [String] {
    var missing: [String] = []
    if !CGPreflightListenEventAccess() {
        if prompt { _ = CGRequestListenEventAccess() }
        missing.append("Input Monitoring")
    }
    let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
    if !AXIsProcessTrustedWithOptions(options) {
        missing.append("Accessibility")
    }
    return missing
}

/// Prompts once, then polls silently until every permission is granted.
func waitForPermissions(pollInterval: TimeInterval = 2) {
    var missing = missingPermissions(prompt: true)
    var reported: [String] = []
    while !missing.isEmpty {
        if missing != reported {
            log("waiting for permissions: \(missing.joined(separator: ", "))")
            reported = missing
        }
        Thread.sleep(forTimeInterval: pollInterval)
        missing = missingPermissions(prompt: false)
    }
    if !reported.isEmpty { log("all permissions granted") }
}

let callback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let context = Unmanaged<TapContext>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        log("event tap disabled (type \(type.rawValue)); re-enabling")
        if let tap = context.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    let input = EventTranslator.translate(
        type: type,
        keyCode: event.getIntegerValueField(.keyboardEventKeycode),
        flags: event.flags,
        timestamp: TimeInterval(event.timestamp) / 1_000_000_000
    )
    if let input, let action = context.detector.handle(input) {
        context.switcher.perform(action)
    }
    return Unmanaged.passUnretained(event)
}

waitForPermissions()

let context = TapContext()
let eventTypes: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
let mask = eventTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .listenOnly,
    eventsOfInterest: mask,
    callback: callback,
    userInfo: Unmanaged.passUnretained(context).toOpaque()
) else {
    log("failed to create event tap")
    exit(1)
}
context.tap = tap

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
log("mac-input-switcher started")
CFRunLoopRun()
