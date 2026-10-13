import Foundation
import Darwin

/// Small helper invoked by Claude Code and Codex hooks.
/// It reads provider JSON on stdin, drops prompt and file contents, and
/// forwards a short event to MochAI's local socket. It never executes input.

struct HookPayload {
    var version = 1
    var provider: String
    var event: String
    var sessionID: String?
    var cwd: String?
    var toolCategory: String?
    var commandName: String?
    var resetAt: String?
    var errorCode: String?
}

if CommandLine.arguments.contains("--statusline") {
    let input = readStandardInput(limit: 256 * 1024)
    if let object = parseJSONObject(input) {
        recordClaudeRateLimits(object)
    }
    if let next = argumentValue("--then") {
        forwardStatusLine(next, input: input)
    }
    exit(0)
}

let providerArgument = argumentValue("--provider") ?? "claude"
let input = readStandardInput(limit: 256 * 1024)
guard let object = parseJSONObject(input) else { exit(0) }

let eventName = stringField(object["hook_event_name"]) ?? ""
let sessionID = stringField(object["session_id"])
let cwd = stringField(object["cwd"])
let toolName = stringField(object["tool_input"] == nil ? object["tool_name"] : object["tool_name"])
let notificationType = stringField(object["notification_type"]) ?? stringField(object["type"])
let errorCode = stringField(object["error"])
let source = stringField(object["source"])
let shellCommand = shellCommandText(from: object["tool_input"])
let storeNames = loadStoreCommandNames()

guard let mapped = mapEvent(
    name: eventName,
    notificationType: notificationType,
    errorCode: errorCode,
    source: source,
    toolName: toolName,
    message: errorCode == "rate_limit" ? stringField(object["last_assistant_message"]) : nil
) else { exit(0) }

let classified = classify(toolName: toolName, command: shellCommand)
var payload = HookPayload(provider: providerArgument, event: mapped.event, sessionID: sessionID, cwd: cwd)
payload.toolCategory = classified.category
payload.commandName = storeNames ? classified.executable : nil
payload.errorCode = mapped.errorCode ?? (errorCode == "rate_limit" ? "rate_limit" : nil)
payload.resetAt = mapped.resetAt

guard let data = encode(payload) else { exit(0) }
if !sendToSocket(data) {
    writeFallback(data)
}
exit(0)

func recordClaudeRateLimits(_ object: [String: Any]) {
    guard let limits = object["rate_limits"] as? [String: Any] else { return }
    var clean: [String: [String: Any]] = [:]
    for (key, value) in limits {
        guard let window = value as? [String: Any] else { continue }
        var item: [String: Any] = [:]
        if let used = window["used_percentage"] ?? window["used_percent"] {
            item["used_percentage"] = used
        }
        if let reset = window["resets_at"] {
            item["resets_at"] = reset
        }
        if !item.isEmpty { clean[key] = item }
    }
    guard !clean.isEmpty else { return }
    let snapshot: [String: Any] = [
        "updatedAt": Date().timeIntervalSince1970,
        "rate_limits": clean
    ]
    guard JSONSerialization.isValidJSONObject(snapshot),
          let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted]) else { return }
    let directory = supportDirectory()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? data.write(to: directory.appendingPathComponent("claude-usage.json"), options: .atomic)
}

func forwardStatusLine(_ command: String, input: Data) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    do {
        try process.run()
    } catch {
        return
    }
    stdin.fileHandleForWriting.write(input)
    try? stdin.fileHandleForWriting.close()
    let deadline = Date().addingTimeInterval(3)
    while process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
    if process.isRunning { process.terminate() }
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    let errors = stderr.fileHandleForReading.readDataToEndOfFile()
    if !output.isEmpty { FileHandle.standardOutput.write(output) }
    if !errors.isEmpty { FileHandle.standardError.write(errors) }
}

func argumentValue(_ flag: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

func readStandardInput(limit: Int) -> Data {
    let handle = FileHandle.standardInput
    var data = Data()
    while data.count < limit {
        let chunk = handle.readData(ofLength: min(16_384, limit - data.count))
        if chunk.isEmpty { break }
        data.append(chunk)
    }
    return data
}

func parseJSONObject(_ data: Data) -> [String: Any]? {
    guard !data.isEmpty, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return object
}

func stringField(_ value: Any?) -> String? {
    guard let text = value as? String else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 4_000, !trimmed.contains("\0") else { return nil }
    return trimmed
}

func shellCommandText(from toolInput: Any?) -> String? {
    guard let dictionary = toolInput as? [String: Any] else { return nil }
    return stringField(dictionary["command"])
}

func loadStoreCommandNames() -> Bool {
    let url = supportDirectory().appendingPathComponent("hook-preferences.json")
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
    return object["storeCommandNames"] as? Bool ?? false
}

func supportDirectory() -> URL {
    if let override = ProcessInfo.processInfo.environment["MOCHAI_SUPPORT_DIR"], !override.isEmpty {
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    return base.appendingPathComponent("MochAI", isDirectory: true)
}

struct MappedEvent {
    var event: String
    var errorCode: String?
    var resetAt: String?
}

func mapEvent(name: String, notificationType: String?, errorCode: String?, source: String?, toolName: String?, message: String?) -> MappedEvent? {
    switch name {
    case "SessionStart":
        return MappedEvent(event: source == "resume" ? "resume_finished" : "session_started", errorCode: nil, resetAt: nil)
    case "SessionEnd":
        return MappedEvent(event: "session_ended", errorCode: nil, resetAt: nil)
    case "UserPromptSubmit":
        return MappedEvent(event: "prompt_submitted", errorCode: nil, resetAt: nil)
    case "PreToolUse":
        return MappedEvent(event: isShell(toolName) ? "command_started" : "tool_started", errorCode: nil, resetAt: nil)
    case "PostToolUse":
        return MappedEvent(event: isShell(toolName) ? "command_finished" : "tool_finished", errorCode: nil, resetAt: nil)
    case "Stop":
        return MappedEvent(event: "generation_stopped", errorCode: nil, resetAt: nil)
    case "StopFailure":
        if errorCode == "rate_limit" {
            return MappedEvent(event: "rate_limit_reached", errorCode: "rate_limit", resetAt: parseReset(message))
        }
        return MappedEvent(event: "error", errorCode: errorCode, resetAt: nil)
    case "PermissionRequest":
        return MappedEvent(event: "permission_requested", errorCode: nil, resetAt: nil)
    case "Notification":
        switch notificationType {
        case "permission_prompt":
            return MappedEvent(event: "permission_requested", errorCode: nil, resetAt: nil)
        case "idle_prompt":
            return MappedEvent(event: "waiting_for_user", errorCode: nil, resetAt: nil)
        default:
            return nil
        }
    default:
        return nil
    }
}

func isShell(_ tool: String?) -> Bool {
    guard let tool else { return false }
    return ["bash", "shell", "powershell"].contains(tool.lowercased())
}

func classify(toolName: String?, command: String?) -> (category: String?, executable: String?) {
    guard let toolName else { return (nil, nil) }
    let tool = toolName.lowercased()
    if isShell(tool) {
        let executable = firstExecutable(command)
        let lower = executable?.lowercased()
        let blob = command?.lowercased() ?? ""
        let category: String
        if blob.contains("test") || lower == "pytest" {
            category = "test"
        } else if ["xcodebuild", "cargo", "make", "cmake", "go", "swift", "npm", "pnpm", "yarn", "bun"].contains(lower ?? "") {
            category = "build"
        } else {
            category = "shell"
        }
        return (category, executable)
    }
    if ["edit", "write", "notebookedit", "apply_patch"].contains(tool) { return ("edit", nil) }
    if tool == "read" { return ("read", nil) }
    if ["grep", "glob"].contains(tool) { return ("search", nil) }
    return ("tool", nil)
}

func firstExecutable(_ command: String?) -> String? {
    guard let command else { return nil }
    let parts = command.split(whereSeparator: \.isWhitespace).map(String.init)
    for part in parts {
        if part.contains("="), !part.hasPrefix("/") { continue }
        let name = URL(fileURLWithPath: part).lastPathComponent
        if name.isEmpty || name == "sudo" || name == "env" { continue }
        return String(name.prefix(64))
    }
    return nil
}

func parseReset(_ text: String?) -> String? {
    guard let text else { return nil }
    if let range = text.range(of: #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})"#, options: .regularExpression) {
        return String(text[range])
    }
    if let range = text.range(of: #"(?i)\b\d{1,2}(?::\d{2})?\s*(am|pm)\b"#, options: .regularExpression) {
        return String(text[range])
    }
    if let range = text.range(of: #"(?i)\bin\s+\d+\s*h(?:ours?)?(?:\s+\d+\s*m(?:inutes?)?)?"#, options: .regularExpression) {
        return String(text[range])
    }
    return nil
}

func encode(_ payload: HookPayload) -> Data? {
    var object: [String: Any] = [
        "version": payload.version,
        "provider": payload.provider,
        "event": payload.event,
        "timestamp": ISO8601DateFormatter().string(from: Date())
    ]
    if let sessionID = payload.sessionID { object["session_id"] = sessionID }
    if let cwd = payload.cwd, cwd.hasPrefix("/") { object["cwd"] = cwd }
    if let tool = payload.toolCategory { object["tool_category"] = tool }
    if let command = payload.commandName { object["command_name"] = command }
    if let reset = payload.resetAt { object["reset_at"] = reset }
    if let error = payload.errorCode { object["error_code"] = error }
    return try? JSONSerialization.data(withJSONObject: object)
}

func sendToSocket(_ data: Data) -> Bool {
    let path = supportDirectory().appendingPathComponent("mochai.sock").path
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: UInt8.self, capacity: bytes.count + 1) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
            raw[bytes.count] = 0
        }
    }
    var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let length = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
    }
    guard connected == 0 else { return false }
    let written = data.withUnsafeBytes { buffer in
        write(fd, buffer.baseAddress, buffer.count)
    }
    return written == data.count
}

func writeFallback(_ data: Data) {
    let directory = supportDirectory().appendingPathComponent("events", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let existing = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    if existing.count >= 100 { return }
    let url = directory.appendingPathComponent(UUID().uuidString + ".json")
    try? data.write(to: url, options: .atomic)
}
