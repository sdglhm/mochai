import AppKit
import MochAICore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = Bootstrap.model
        let launch = LaunchOptions()
        NSApp.setActivationPolicy((model.settings.showDockIcon || launch.uiTesting) ? .regular : .accessory)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await Bootstrap.model.handleWake() }
        }
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Bootstrap.model.flush() }
        }

        Task { @MainActor in
            let suppressOnboarding = launch.uiTesting && !launch.showOnboarding && (launch.showDashboard || launch.showSettings)
            if launch.showOnboarding || (!model.settings.hasCompletedOnboarding && !suppressOnboarding) {
                WindowPresenter.shared.showOnboarding()
            }
            if launch.showDashboard {
                WindowPresenter.shared.showDashboard()
            }
            if launch.showSettings {
                WindowPresenter.shared.showSettings()
            }
            await model.start()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Bootstrap.model.shutdown()
        return .terminateNow
    }
}

@MainActor
final class WindowPresenter {
    static let shared = WindowPresenter()
    private var windows: [String: NSWindow] = [:]

    func showDashboard() {
        show("dashboard", title: "MochAI", size: NSSize(width: 980, height: 680)) {
            DashboardView().environment(Bootstrap.model)
        }
    }

    func showOnboarding() {
        show("onboarding", title: "Welcome to MochAI", size: NSSize(width: 640, height: 520), resizable: false) {
            OnboardingView {
                self.windows["onboarding"]?.close()
            }
            .environment(Bootstrap.model)
        }
    }

    func showDiagnostics() {
        show("diagnostics", title: "Diagnostics", size: NSSize(width: 640, height: 520)) {
            DiagnosticsView().environment(Bootstrap.model)
        }
    }

    func showSettings() {
        show("settings", title: "Settings", size: NSSize(width: 820, height: 560)) {
            SettingsView().environment(Bootstrap.model)
        }
    }

    func showAbout() {
        show("about", title: "About MochAI", size: NSSize(width: 420, height: 460), resizable: false) {
            AboutView()
        }
    }

    private func show<V: View>(_ id: String, title: String, size: NSSize, resizable: Bool = true, @ViewBuilder content: () -> V) {
        if let existing = windows[id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = NSHostingController(rootView: content())
        let window = NSWindow(contentViewController: controller)
        window.title = title
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        window.styleMask = style
        window.setContentSize(size)
        window.center()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        windows[id] = window
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum Bootstrap {
    @MainActor static let model = AppModel()
}

@main
struct MochAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                onDashboard: { WindowPresenter.shared.showDashboard() },
                onSettings: { WindowPresenter.shared.showSettings() },
                onAbout: { WindowPresenter.shared.showAbout() }
            )
            .environment(Bootstrap.model)
        } label: {
            MenuBarLabel()
                .environment(Bootstrap.model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(Bootstrap.model)
        }
    }
}
