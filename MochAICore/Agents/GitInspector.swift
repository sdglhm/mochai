import Foundation

public struct GitInfo: Equatable, Sendable {
    public var root: String
    public var branch: String?
    public var origin: String?
    public var hasChanges: Bool

    public init(root: String, branch: String?, origin: String?, hasChanges: Bool) {
        self.root = root
        self.branch = branch
        self.origin = origin
        self.hasChanges = hasChanges
    }
}

public enum GitInspector {
    public static func inspect(directory: String) -> GitInfo? {
        guard let root = run(["-C", directory, "rev-parse", "--show-toplevel"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !root.isEmpty else { return nil }
        let branch = run(["-C", root, "rev-parse", "--abbrev-ref", "HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = run(["-C", root, "remote", "get-url", "origin"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let status = run(["-C", root, "status", "--porcelain"]) ?? ""
        let cleanBranch = (branch?.isEmpty == false && branch != "HEAD") ? branch : branch
        return GitInfo(
            root: root,
            branch: cleanBranch?.isEmpty == true ? nil : cleanBranch,
            origin: origin?.isEmpty == true ? nil : origin,
            hasChanges: !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    private static func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
