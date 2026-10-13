import AppKit
import SwiftUI

public enum MochaiTheme {
    public static let cardRadius: CGFloat = 12
    public static let popoverWidth: CGFloat = 384

    public static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark
            ? NSColor(calibratedRed: 0.93, green: 0.74, blue: 0.52, alpha: 1)
            : NSColor(calibratedRed: 0.55, green: 0.36, blue: 0.20, alpha: 1)
    })

    public static let bodyFill = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark
            ? NSColor(calibratedRed: 0.93, green: 0.88, blue: 0.80, alpha: 1)
            : NSColor(calibratedRed: 0.99, green: 0.96, blue: 0.92, alpha: 1)
    })

    public static let cocoa = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark
            ? NSColor(calibratedRed: 0.62, green: 0.45, blue: 0.34, alpha: 1)
            : NSColor(calibratedRed: 0.42, green: 0.28, blue: 0.20, alpha: 1)
    })

    public static let cheek = Color(red: 0.95, green: 0.72, blue: 0.62)

    public static func statusColor(_ state: AgentState) -> Color {
        switch state {
        case .working, .runningTool, .runningCommand, .starting, .resuming:
            Color.green
        case .waitingForUser, .waitingForPermission:
            Color.orange
        case .rateLimited, .waitingForReset:
            Color.purple
        case .failed:
            Color.red
        case .completed:
            Color.green
        case .idle, .unknown, .notRunning:
            Color.secondary
        }
    }
}

public struct MascotView: View {
    public var pose: MascotPose
    public var size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(pose: MascotPose, size: CGFloat = 84) {
        self.pose = pose
        self.size = size
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.6, paused: reduceMotion || (pose != .working && pose != .coffee))) { timeline in
            let bounce = !reduceMotion && (pose == .working || pose == .coffee) && Int(timeline.date.timeIntervalSinceReferenceDate / 1.6).isMultiple(of: 4)
            Image("MochaiMascot")
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .scaledToFit()
                .opacity(pose == .sleeping ? 0.82 : 1)
                .offset(y: bounce ? -2 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: bounce)
                .accessibilityHidden(true)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch pose {
        case .idle: "MochAI resting"
        case .working, .coffee: "MochAI keeping watch"
        case .sleeping: "MochAI napping"
        case .waiting: "MochAI waiting"
        case .celebrate: "MochAI pleased"
        case .error: "MochAI needs attention"
        }
    }
}

public struct StatusPill: View {
    public var state: AgentState

    public init(state: AgentState) {
        self.state = state
    }

    public var body: some View {
        Label(state.label, systemImage: state.symbolName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(MochaiTheme.statusColor(state))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(MochaiTheme.statusColor(state).opacity(0.12), in: Capsule())
            .accessibilityLabel("Status \(state.label)")
    }
}

/// Ring filled by the allowance that is still left. An empty ring means the limit is spent.
public struct AllowanceDonut: View {
    public var remaining: Double
    public var size: CGFloat

    public init(remaining: Double, size: CGFloat = 14) {
        self.remaining = remaining
        self.size = size
    }

    public var body: some View {
        let left = min(1, max(0, remaining))
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: 2.5)
            if left >= 0.995 {
                Circle()
                    .stroke(MochaiTheme.accent, lineWidth: 2.5)
            } else if left > 0.005 {
                Circle()
                    .trim(from: 0, to: left)
                    .stroke(MochaiTheme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

public struct UsageMeter: View {
    public var window: UsageWindow
    public var confidence: UsageConfidence
    public var title: String?
    public var reading: AllowanceReading

    public init(window: UsageWindow, confidence: UsageConfidence, title: String? = nil, reading: AllowanceReading = .remaining) {
        self.window = window
        self.confidence = confidence
        self.title = title
        self.reading = reading
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            meter(at: timeline.date)
        }
    }

    private func meter(at now: Date) -> some View {
        let current = window.isCurrent(at: now)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title ?? window.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if current, let headline = window.headline(reading: reading) {
                    let estimated = confidence == .locallyEstimated && !headline.hasPrefix("Limit")
                    Text(estimated ? "~\(headline)" : headline)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .monospacedDigit()
                } else if !current {
                    Text("Reset")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                if current, let fill = window.meterFill(reading: reading) {
                    AllowanceDonut(remaining: fill, size: 18)
                }
            }
            if current, let fill = window.meterFill(reading: reading), let headline = window.headline(reading: reading) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(MochaiTheme.accent)
                            .frame(width: max(4, proxy.size.width * fill))
                    }
                }
                .frame(height: 6)
                .accessibilityLabel("\(window.name) \(headline)")
            }
            if let reset = window.resetAt {
                Text(resetCaption(reset, now: now))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if !current, let headline = window.headline(reading: reading) {
                Text("Last seen \(headline)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func resetCaption(_ reset: Date, now: Date) -> String {
        if reset > now {
            return "Resets \(MochaiFormat.clock(reset, now: now)) · \(MochaiFormat.countdown(reset.timeIntervalSince(now)))"
        }
        return "Reset \(MochaiFormat.clock(reset, now: now)). Checking for the new window."
    }
}

public struct QuietCard<Content: View>: View {
    @ViewBuilder public var content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: MochaiTheme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MochaiTheme.cardRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
    }
}
