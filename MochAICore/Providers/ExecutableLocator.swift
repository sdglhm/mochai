import Foundation

public enum CommandRunner {
    public static func run(executable: URL, arguments: [String], timeout: TimeInterval = 4) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let group = DispatchGroup()
        group.enter()
        process.terminationHandler = { _ in group.leave() }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum ExecutableLocator {
    private static let lock = NSLock()
    private static var cachedPATH: String?
    private static var cachedAt: Date?

    public static func locate(_ name: String) -> URL? {
        let directories = searchDirectories()
        for directory in directories {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    public static func version(of executable: URL) -> String? {
        let output = CommandRunner.run(executable: executable, arguments: ["--version"])
        guard let output, !output.isEmpty else { return nil }
        return output.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    public static func isValidExecutable(_ path: String, names: [String]) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard names.contains(url.lastPathComponent) else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    private static func searchDirectories() -> [String] {
        var directories = pathDirectories()
        let extras = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            NSHomeDirectory() + "/.local/bin",
            "/usr/bin",
            "/bin"
        ]
        for extra in extras where !directories.contains(extra) {
            directories.append(extra)
        }
        return directories
    }

    private static func pathDirectories() -> [String] {
        lock.lock()
        if let cachedPATH, let cachedAt, Date().timeIntervalSince(cachedAt) < 300 {
            lock.unlock()
            return cachedPATH.split(separator: ":").map(String.init)
        }
        lock.unlock()
        let resolved = loginPATH() ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        lock.lock()
        cachedPATH = resolved
        cachedAt = Date()
        lock.unlock()
        return resolved.split(separator: ":").map(String.init)
    }

    private static func loginPATH() -> String? {
        CommandRunner.run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-lc", "print -r -- \"$PATH\""],
            timeout: 3
        )
    }
}
