import Foundation

public enum ShellQuoting {
    /// POSIX single-quote escaping. Safe to embed in a shell command string
    /// that is itself passed as one AppleScript string, not via `sh -c` interpolation
    /// of untrusted hook input.
    public static func singleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
