import Foundation

/// Central product identity. Change the bundle identifier here and in the
/// Xcode project together; runtime code should not hard-code it elsewhere.
public enum AppIdentity {
    public static let name = "MochAI"
    public static let pronunciation = "Moch-eye"
    public static let tagline = "Your tiny supervisor for AI coding agents."
    public static let bundleIdentifier = "app.mochai.MochAI"
    public static let hookBundleIdentifier = "app.mochai.MochAI.hook"
    public static let logSubsystem = "app.mochai"
    public static let version = "1.0.0"
    public static let build = "1"
    public static let copyright = "Copyright © 2026 Lahiru Himesh Madusanka"
    public static let website = URL(string: "https://mochai.sdglhm.com")!
    public static let authorWebsite = URL(string: "https://sdglhm.com")!
    public static let github = URL(string: "https://github.com/sdglhm/mochai")!

    /// Marker embedded in hook commands so uninstall can find only MochAI entries.
    public static let hookCommandMarker = "mochai-hook"

    public static let defaultContinuationPrompt =
        "Continue the previous task from where you stopped. First review the previous conversation and repository state so that you do not repeat completed work."

    public static let sleepReason = "MochAI is supervising an active AI agent"
}
