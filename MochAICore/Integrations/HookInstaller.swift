import Foundation

public struct IntegrationReceipt: Codable, Equatable, Sendable {
    public var provider: String
    public var configPath: String
    public var createdFile: Bool
    public var installedAt: Date
    public var command: String

    public init(provider: String, configPath: String, createdFile: Bool, installedAt: Date, command: String) {
        self.provider = provider
        self.configPath = configPath
        self.createdFile = createdFile
        self.installedAt = installedAt
        self.command = command
    }
}

public enum HookInstallerError: Error, LocalizedError {
    case unreadableConfiguration(String)
    case validationFailed
    case restoreFailed
    case binaryMissing

    public var errorDescription: String? {
        switch self {
        case .unreadableConfiguration(let path):
            "MochAI couldn't read the configuration at \(path)."
        case .validationFailed:
            "The updated configuration didn't look valid, so MochAI restored the backup."
        case .restoreFailed:
            "MochAI couldn't restore the configuration backup. A copy is in Application Support."
        case .binaryMissing:
            "The MochAI hook helper isn't available in this build."
        }
    }
}

public struct HookInstallResult: Equatable, Sendable {
    public var configPath: String
    public var backupPath: String?
    public var createdFile: Bool
}

public enum HookInstaller {
    public static func install(
        configURL: URL,
        plan: HookInstallPlan,
        backupDirectory: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> HookInstallResult {
        try fileManager.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let existed = fileManager.fileExists(atPath: configURL.path)
        let original = existed ? (try? Data(contentsOf: configURL)) ?? Data() : Data()
        if existed, original.isEmpty == false {
            let object = try? JSONSerialization.jsonObject(with: original)
            if object == nil { throw HookInstallerError.unreadableConfiguration(configURL.path) }
        }
        let backup = try writeBackup(original, existed: existed, directory: backupDirectory, now: now, fileManager: fileManager)
        let merged = try ConfigMerger.mergeHooks(into: original, plan: plan)
        guard ConfigMerger.containsMarker(merged, marker: plan.marker) else {
            throw HookInstallerError.validationFailed
        }
        do {
            try writeAtomic(merged, to: configURL, fileManager: fileManager)
            let readBack = try Data(contentsOf: configURL)
            guard ConfigMerger.containsMarker(readBack, marker: plan.marker),
                  (try? JSONSerialization.jsonObject(with: readBack)) != nil else {
                throw HookInstallerError.validationFailed
            }
        } catch {
            try restore(original, existed: existed, to: configURL, fileManager: fileManager)
            throw HookInstallerError.validationFailed
        }
        return HookInstallResult(configPath: configURL.path, backupPath: backup?.path, createdFile: !existed)
    }

    public static func uninstall(
        configURL: URL,
        marker: String,
        createdFile: Bool,
        backupDirectory: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: configURL.path) else { return }
        let original = try Data(contentsOf: configURL)
        _ = try writeBackup(original, existed: true, directory: backupDirectory, now: now, fileManager: fileManager)
        let stripped = try ConfigMerger.removeHooks(from: original, marker: marker)
        if createdFile, !ConfigMerger.containsMarker(stripped, marker: marker) {
            let object = try JSONSerialization.jsonObject(with: stripped) as? [String: Any]
            if object?.isEmpty == true || stripped.isEmpty {
                try fileManager.removeItem(at: configURL)
                return
            }
        }
        try writeAtomic(stripped, to: configURL, fileManager: fileManager)
        let readBack = try Data(contentsOf: configURL)
        if ConfigMerger.containsMarker(readBack, marker: marker) {
            try restore(original, existed: true, to: configURL, fileManager: fileManager)
            throw HookInstallerError.validationFailed
        }
    }

    private static func writeBackup(
        _ data: Data,
        existed: Bool,
        directory: URL,
        now: Date,
        fileManager: FileManager
    ) throws -> URL? {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("config-\(stamp).json")
        if existed {
            try data.write(to: url, options: .atomic)
        } else {
            try Data("null".utf8).write(to: url, options: .atomic)
        }
        return url
    }

    private static func writeAtomic(_ data: Data, to url: URL, fileManager: FileManager) throws {
        let temporary = url.appendingPathExtension("mochai-tmp")
        try data.write(to: temporary, options: .atomic)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
    }

    private static func restore(_ original: Data, existed: Bool, to url: URL, fileManager: FileManager) throws {
        if existed {
            try original.write(to: url, options: .atomic)
        } else if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}
