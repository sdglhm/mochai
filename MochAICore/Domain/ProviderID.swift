import Foundation

public enum ProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case cursor
    case openCodeGo
    case antigravity
    case mock

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .openCodeGo: "OpenCode Go"
        case .antigravity: "Antigravity"
        case .mock: "Preview Agent"
        }
    }

    public var executableNames: [String] {
        switch self {
        case .claude: ["claude"]
        case .codex: ["codex"]
        case .cursor: ["cursor"]
        case .openCodeGo: ["opencode"]
        case .antigravity: ["agy"]
        case .mock: []
        }
    }

    public var isUserFacing: Bool {
        switch self {
        case .claude, .codex, .cursor, .openCodeGo, .antigravity: true
        case .mock: false
        }
    }

    /// Claude and Codex are watched through hooks. Cursor is watched from its agent process. The others only contribute allowance.
    public var supervisesSessions: Bool {
        switch self {
        case .claude, .codex: true
        case .cursor, .openCodeGo, .antigravity, .mock: false
        }
    }

    /// Hidden from the menu until the tool is actually on this Mac.
    public var appearsWhenInstalled: Bool {
        switch self {
        case .cursor, .openCodeGo, .antigravity: true
        case .claude, .codex, .mock: false
        }
    }

    /// Every provider is shown as remaining allowance, so 21% used reads as 79% left.
    public var allowanceReading: AllowanceReading { .remaining }
}

public enum AllowanceReading: Equatable, Sendable {
    case used
    case remaining
}
