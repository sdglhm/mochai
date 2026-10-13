import Darwin
import Foundation

public struct ProcessInspection: Sendable {
    public var pid: Int32
    public var parentPID: Int32?
    public var executablePath: String
    public var workingDirectory: String?
    public var startedAt: Date?
    public var cpuNanoseconds: UInt64
    public var commandName: String

    public init(
        pid: Int32,
        parentPID: Int32?,
        executablePath: String,
        workingDirectory: String?,
        startedAt: Date?,
        cpuNanoseconds: UInt64,
        commandName: String
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.executablePath = executablePath
        self.workingDirectory = workingDirectory
        self.startedAt = startedAt
        self.cpuNanoseconds = cpuNanoseconds
        self.commandName = commandName
    }
}

public enum ProcessInspector {
    public static func listAgentProcesses() -> [ProcessInspection] {
        let pids = allPIDs()
        var matches: [ProcessInspection] = []
        matches.reserveCapacity(8)
        for pid in pids {
            guard let inspection = inspect(pid: pid) else { continue }
            let name = inspection.commandName.lowercased()
            let path = inspection.executablePath.lowercased()
            if path.contains("mochai.app") || name == "mochai-hook" || name == "mochai" { continue }
            if Self.isClaudeOrCodex(name: name, path: path) {
                matches.append(inspection)
                continue
            }
            if path.contains("/cursor-agent/") {
                matches.append(inspection)
                continue
            }
            if path.contains("cursor helper (plugin)"),
               let title = electronTitle(pid: pid),
               Self.isCursorAgentsWindow(title.lowercased()) {
                matches.append(ProcessInspection(
                    pid: inspection.pid,
                    parentPID: inspection.parentPID,
                    executablePath: inspection.executablePath,
                    workingDirectory: inspection.workingDirectory,
                    startedAt: inspection.startedAt,
                    cpuNanoseconds: inspection.cpuNanoseconds,
                    commandName: title
                ))
            }
        }
        return matches
    }

    public static func provider(for inspection: ProcessInspection) -> ProviderID? {
        provider(commandName: inspection.commandName, executablePath: inspection.executablePath)
    }

    public static func provider(commandName: String, executablePath: String) -> ProviderID? {
        let name = commandName.lowercased()
        let path = executablePath.lowercased()
        if isClaudeOrCodex(name: name, path: path) {
            if name == "codex" || path.hasSuffix("/codex") { return .codex }
            return .claude
        }
        if name == "cursor-agent" || path.contains("/cursor-agent/") { return .cursor }
        if isCursorAgentsWindow(name) { return .cursor }
        return nil
    }

    /// The second argument is Cursor's process title. Later arguments are ignored
    /// because they can carry credentials.
    static func electronTitle(pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size < 65_536 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = buffer.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return sysctl(&mib, 3, base, &size, nil, 0)
        }
        guard read == 0 else { return nil }
        var index = 4
        func nextString() -> String? {
            while index < size, buffer[index] == 0 { index += 1 }
            guard index < size else { return nil }
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            return String(bytes: buffer[start..<index], encoding: .utf8)
        }
        _ = nextString()
        guard let title = nextString(), title.count < 180, title.lowercased().contains("extension-host") else { return nil }
        return title
    }

    private static func isClaudeOrCodex(name: String, path: String) -> Bool {
        name == "claude" || name == "codex" || path.hasSuffix("/claude") || path.hasSuffix("/codex")
    }

    private static func isCursorAgentsWindow(_ name: String) -> Bool {
        name.contains("extension-host") && name.contains("agents")
    }

    public static func inspect(pid: Int32) -> ProcessInspection? {
        guard let path = executablePath(pid: pid), !path.isEmpty else { return nil }
        var bsd = proc_bsdinfo()
        let bsdSize = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size))
        var parent: Int32?
        var started: Date?
        var command = URL(fileURLWithPath: path).lastPathComponent
        if bsdSize > 0 {
            parent = Int32(bsd.pbi_ppid)
            if bsd.pbi_start_tvsec > 0 {
                started = Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec))
            }
            let name = withUnsafePointer(to: bsd.pbi_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: bsd.pbi_name)) {
                    String(cString: $0)
                }
            }
            if !name.isEmpty { command = name }
        }
        var task = proc_taskinfo()
        let taskSize = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size))
        let cpu: UInt64 = taskSize > 0 ? task.pti_total_user &+ task.pti_total_system : 0
        return ProcessInspection(
            pid: pid,
            parentPID: parent,
            executablePath: path,
            workingDirectory: workingDirectory(pid: pid),
            startedAt: started,
            cpuNanoseconds: cpu,
            commandName: command
        )
    }

    public static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    public static func workingDirectory(pid: Int32) -> String? {
        var vnode = proc_vnodepathinfo()
        let size = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, Int32(MemoryLayout<proc_vnodepathinfo>.size))
        guard size > 0 else { return nil }
        let path = withUnsafePointer(to: vnode.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    public static func allPIDs() -> [Int32] {
        let bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        let count = Int(bufferSize) / MemoryLayout<Int32>.size
        var pids = [Int32](repeating: 0, count: max(count, 1))
        let actual = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(bufferSize))
        let used = max(0, Int(actual) / MemoryLayout<Int32>.size)
        return Array(pids.prefix(used)).filter { $0 > 0 }
    }
}

public final class ProcessWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var previousCPU: [Int32: UInt64] = [:]
    private var previousAt: Date?

    public init() {}

    public func snapshot(now: Date = Date()) -> [TrackedProcess] {
        let inspections = ProcessInspector.listAgentProcesses()
        var tracked: [TrackedProcess] = []
        var next: [Int32: UInt64] = [:]
        lock.lock()
        let previous = previousCPU
        let elapsed = previousAt.map { now.timeIntervalSince($0) } ?? 0
        lock.unlock()
        for item in inspections {
            guard let provider = ProcessInspector.provider(for: item) else { continue }
            let active = Self.cpuActive(
                provider: provider,
                previous: previous[item.pid],
                current: item.cpuNanoseconds,
                elapsed: elapsed
            )
            next[item.pid] = item.cpuNanoseconds
            tracked.append(
                TrackedProcess(
                    pid: item.pid,
                    parentPID: item.parentPID,
                    provider: provider,
                    executablePath: item.executablePath,
                    workingDirectory: item.workingDirectory,
                    startedAt: item.startedAt,
                    terminalApp: TerminalDetector.detect(startingAt: item.parentPID),
                    cpuActive: active
                )
            )
        }
        lock.lock()
        previousCPU = next
        previousAt = now
        lock.unlock()
        return tracked
    }

    /// Cursor's agent window stays near idle while it is merely open, then ticks up in
    /// short bursts while a turn is streaming. Those bursts are often only a couple
    /// percent of one core, so the bar sits just above the idle window.
    static func cpuActive(provider: ProviderID, previous: UInt64?, current: UInt64, elapsed: TimeInterval) -> Bool {
        guard let previous, elapsed > 0.4, current > previous else { return false }
        let delta = current - previous
        if provider == .cursor {
            return Double(delta) / (elapsed * 1_000_000_000) >= 0.015
        }
        return delta > 50_000_000
    }
}

public enum TerminalDetector {
    private static let names: [(needle: String, label: String)] = [
        ("ghostty", "Ghostty"),
        ("warp", "Warp"),
        ("iterm", "iTerm2"),
        ("terminal", "Terminal"),
        ("code", "VS Code"),
        ("cursor", "Cursor"),
        ("idea", "JetBrains"),
        ("webstorm", "JetBrains"),
        ("pycharm", "JetBrains"),
        ("clion", "JetBrains"),
        ("goland", "JetBrains"),
        ("rubymine", "JetBrains"),
        ("phpstorm", "JetBrains"),
        ("rider", "JetBrains")
    ]

    public static func detect(startingAt pid: Int32?) -> String? {
        var current = pid
        var guardCount = 0
        while let pid = current, guardCount < 8 {
            guardCount += 1
            guard let inspection = ProcessInspector.inspect(pid: pid) else { break }
            let blob = (inspection.commandName + " " + inspection.executablePath).lowercased()
            if let match = names.first(where: { blob.contains($0.needle) }) {
                return match.label
            }
            current = inspection.parentPID
            if current == pid || current == 0 || current == 1 { break }
        }
        return nil
    }
}
