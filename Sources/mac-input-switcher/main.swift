import ApplicationServices
import CoreGraphics
import Foundation
import InputSwitcherCore

// Only used from the main thread (startup and the main run loop).
nonisolated(unsafe) let timestampFormatter = ISO8601DateFormatter()

func log(_ message: String) {
    let timestamp = timestampFormatter.string(from: Date())
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

/// Asks a fresh child process which permissions are missing; nil if the probe failed.
func probeMissingPermissions() -> [String]? {
    guard let path = Bundle.main.executablePath else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = [PermissionProbe.argument]
    let pipe = Pipe()
    process.standardOutput = pipe
    do {
        try process.run()
    } catch {
        log("permission probe failed to start: \(error)")
        return nil
    }
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        log("permission probe exited with status \(process.terminationStatus)")
        return nil
    }
    return PermissionProbe.parse(String(decoding: output, as: UTF8.self))
}

/// Replaces this process with a fresh copy so that newly granted permissions take effect.
func restartSelf() -> Never {
    if let path = Bundle.main.executablePath {
        execv(path, CommandLine.unsafeArgv)
    }
    log("restart failed (errno \(errno)); exiting so launchd restarts the agent")
    exit(1)
}

/// Prompts once, then polls silently until every permission is granted.
func waitForPermissions(pollInterval: TimeInterval = 2) {
    let missing = missingPermissions(prompt: true)
    guard !missing.isEmpty else { return }
    var watch = PermissionWatch()
    var step = watch.update(missing: missing)
    while true {
        switch step {
        case .wait(let message):
            if let message { log(message) }
            Thread.sleep(forTimeInterval: pollInterval)
            step = probeMissingPermissions().map { watch.update(missing: $0) } ?? .wait(log: nil)
        case .restart(let message):
            log(message)
            restartSelf()
        }
    }
}

if CommandLine.arguments.dropFirst().first == PermissionProbe.argument {
    for name in missingPermissions(prompt: false) { print(name) }
    exit(0)
}

let callback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let context = Unmanaged<TapContext>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        log("event tap disabled (type \(type.rawValue)); re-enabling")
        if let tap = context.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if JISKeyInputSourceSwitcher.isSynthesized(userData: event.getIntegerValueField(.eventSourceUserData)) {
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
