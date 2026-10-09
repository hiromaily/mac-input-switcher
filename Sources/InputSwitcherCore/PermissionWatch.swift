import Foundation

/// Reads the output of `mac-input-switcher --check-permissions`.
///
/// Permission checks never turn true inside a process that started without
/// them, so the waiting process asks a fresh child process instead.
public enum PermissionProbe {
    public static let argument = "--check-permissions"

    /// One missing permission name per line; empty output means all granted.
    public static func parse(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Decides what the waiting process does after each permission probe.
public struct PermissionWatch {
    public enum Step: Equatable {
        case wait(log: String?)
        case restart(log: String)
    }

    private var reported: [String] = []

    public init() {}

    public mutating func update(missing: [String]) -> Step {
        if missing.isEmpty {
            return .restart(log: "all permissions granted; restarting")
        }
        guard missing != reported else { return .wait(log: nil) }
        reported = missing
        return .wait(log: "waiting for permissions: \(missing.joined(separator: ", "))")
    }
}
