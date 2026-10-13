import AppKit
import Foundation

public enum TerminalLauncher {
    public static func openCommand(
        executable: URL,
        arguments: [String],
        directory: String,
        preferredTerminal: String?
    ) throws -> String {
        let command = ([ShellQuoting.singleQuote(executable.path)] + arguments.map(ShellQuoting.singleQuote)).joined(separator: " ")
        let shell = "cd \(ShellQuoting.singleQuote(directory)) && \(command)"
        let terminal = preferredTerminal?.lowercased()
        if terminal?.contains("iterm") == true, FileManager.default.fileExists(atPath: "/Applications/iTerm.app") {
            let source = """
            tell application "iTerm"
              activate
              create window with default profile
              tell current session of current window
                write text \(ShellQuoting.appleScriptString(shell))
              end tell
            end tell
            """
            try runAppleScript(source)
            return "Opened in iTerm2"
        }
        let source = """
        tell application "Terminal"
          activate
          do script \(ShellQuoting.appleScriptString(shell))
        end tell
        """
        try runAppleScript(source)
        if let preferredTerminal, preferredTerminal != "Terminal" {
            return "Opened in Terminal. \(preferredTerminal) can't reliably receive a resume command."
        }
        return "Opened in Terminal"
    }

    public static func reveal(_ path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    public static func openFolder(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    public static func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    public static func openInEditor(_ path: String) -> String? {
        let editors: [(name: String, bundle: String)] = [
            ("Visual Studio Code", "com.microsoft.VSCode"),
            ("Cursor", "com.todesktop.230313mzl4w4u92"),
            ("Xcode", "com.apple.dt.Xcode")
        ]
        for editor in editors {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundle) else { continue }
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: url, configuration: configuration)
            return editor.name
        }
        return nil
    }

    private static func runAppleScript(_ source: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data(source.utf8))
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw ResumeError.terminalLaunchFailed
        }
    }
}

public enum ResumeError: Error, LocalizedError {
    case missingDirectory
    case missingExecutable
    case terminalLaunchFailed
    case blocked(String)

    public var errorDescription: String? {
        switch self {
        case .missingDirectory: "The project folder is no longer there."
        case .missingExecutable: "MochAI can't find the agent executable."
        case .terminalLaunchFailed: "MochAI couldn't open Terminal to resume the session."
        case .blocked(let reason): reason
        }
    }
}
