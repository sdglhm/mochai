import AppKit
import SwiftUI

enum MenuBarSymbol {
    /// Two bitmaps, reused for every menu-bar update. A fresh NSImage on each
    /// render makes AppKit relayout the status item forever during launch.
    static let image = canvas(dot: false)
    static let awake = canvas(dot: true)

    private static func canvas(dot: Bool) -> NSImage {
        let side: CGFloat = 18
        let canvas = NSImage(size: NSSize(width: side, height: side))
        canvas.lockFocus()
        if let mascot = NSImage(named: "MochaiMascot") {
            mascot.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        } else {
            NSColor.labelColor.setStroke()
            let body = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: side - 2, height: side - 2))
            body.lineWidth = 1.4
            body.stroke()
        }
        if dot {
            let diameter: CGFloat = 6
            let rect = NSRect(x: side - diameter - 1, y: 1, width: diameter, height: diameter)
            let mark = NSBezierPath(ovalIn: rect.insetBy(dx: 0.6, dy: 0.6))
            NSColor.white.setFill()
            NSBezierPath(ovalIn: rect).fill()
            NSColor(srgbRed: 0.18, green: 0.78, blue: 0.32, alpha: 1).setFill()
            mark.fill()
        }
        canvas.unlockFocus()
        canvas.isTemplate = false
        return canvas
    }
}

public struct MenuBarLabel: View {
    @Environment(AppModel.self) private var app

    public init() {}

    public var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: app.showsActivityDot ? MenuBarSymbol.awake : MenuBarSymbol.image)
            if let text = app.menuBarText {
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(app.headline)
    }
}

struct AwakeDot: View {
    var diameter: CGFloat

    var body: some View {
        Circle()
            .fill(Color.white)
            .frame(width: diameter, height: diameter)
            .overlay {
                Circle()
                    .fill(Color(red: 0.18, green: 0.78, blue: 0.32))
                    .padding(diameter * 0.6 / 5.5)
            }
            .accessibilityHidden(true)
    }
}

public struct MenuBarView: View {
    @Environment(AppModel.self) private var app
    public var onDashboard: () -> Void
    public var onSettings: () -> Void
    public var onAbout: () -> Void

    public init(onDashboard: @escaping () -> Void, onSettings: @escaping () -> Void, onAbout: @escaping () -> Void) {
        self.onDashboard = onDashboard
        self.onSettings = onSettings
        self.onAbout = onAbout
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let banner = app.banner {
                Text(banner)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MochaiTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            limits
            footer
        }
        .padding(14)
        .frame(width: MochaiTheme.popoverWidth)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            MascotView(pose: app.mascot, size: 42)
                .overlay(alignment: .bottomTrailing) {
                    if app.showsActivityDot {
                        AwakeDot(diameter: 42 * 6 / 18)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text("MochAI")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(app.headline)
                    .font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if app.sleepStatus.holding {
                    Text("Staying awake")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(headerLabel)
    }

    private var headerLabel: String {
        app.sleepStatus.holding ? "\(app.headline) Staying awake." : app.headline
    }

    private var limits: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            VStack(alignment: .leading, spacing: 8) {
                ForEach(ProviderID.allCases.filter { app.showsInMenu($0) }) { provider in
                    providerBlock(provider, at: timeline.date)
                }
            }
        }
    }

    private func providerBlock(_ provider: ProviderID, at now: Date) -> some View {
        let windows = app.usage[provider]?.allowanceWindows() ?? []
        let working = app.isWorking(provider)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProviderIcon(provider: provider, size: 14)
                Text(provider.displayName)
                    .font(.system(size: 13, weight: .semibold))
                if working {
                    AwakeDot(diameter: 8)
                        .help("Working")
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(working ? "\(provider.displayName), working" : provider.displayName)

            if windows.isEmpty {
                Text(app.usage[provider]?.detail ?? "Not available yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(windows) { window in
                    allowanceRow(window, at: now)
                }
            }
            if app.settings.showTokenCost, let cost = app.tokenCosts[provider] {
                Text(cost.line)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func allowanceRow(_ window: UsageWindow, at now: Date) -> some View {
        let exhausted = (window.resolvedUsed ?? 0) >= 0.995
        let figure = window.headline(reading: .remaining)
        return HStack(spacing: 8) {
            Text(window.shortLabel)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if exhausted {
                Text("Limit reached")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
            } else if let figure {
                Text(figure)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            if let reset = window.resetAt {
                Text(reset > now ? MochaiFormat.countdown(reset.timeIntervalSince(now)) : "Reset \(MochaiFormat.clock(reset, now: now))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            AllowanceDonut(remaining: window.meterFill(reading: .remaining) ?? 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Divider()
            HStack(spacing: 4) {
                Menu {
                    Picker("Keep Awake", selection: Binding(
                        get: { app.settings.keepAwakeMode },
                        set: { app.settings.selectKeepAwake($0); app.applySettings() }
                    )) {
                        ForEach(KeepAwakeMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Label(app.settings.keepAwakeMode.label, systemImage: app.sleepStatus.holding ? "cup.and.saucer.fill" : "moon")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Keep awake, \(app.settings.keepAwakeMode.label)")
                Spacer(minLength: 8)
                Button("Dashboard", action: onDashboard)
                    .buttonStyle(.borderless)
                Button("About", action: onAbout)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("menubar.about")
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("menubar.settings")
                .help("Settings")
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("menubar.quit")
            }
        }
        .font(.system(size: 12))
    }
}
