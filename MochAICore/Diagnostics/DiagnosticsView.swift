import SwiftUI

public struct DiagnosticsView: View {
    @Environment(AppModel.self) private var app

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(ProviderID.allCases.filter(\.isUserFacing)) { provider in
                    if let report = app.health[provider] {
                        QuietCard {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(provider.displayName).font(.headline)
                                ForEach(report.checks) { check in
                                    HStack(alignment: .firstTextBaseline) {
                                        Image(systemName: check.passed ? "checkmark.circle" : "exclamationmark.circle")
                                            .foregroundStyle(check.passed ? Color.green : Color.orange)
                                            .accessibilityLabel(check.passed ? "Passed" : "Needs attention")
                                        VStack(alignment: .leading) {
                                            Text(check.title)
                                            Text(check.detail)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .textSelection(.enabled)
                                        }
                                    }
                                }
                                Text(report.summary)
                                    .font(.system(size: 12, weight: .medium))
                                    .padding(.top, 4)
                            }
                        }
                    }
                }
                Button("Refresh") { Task { await app.handleWake() } }
            }
            .padding(8)
        }
        .accessibilityIdentifier("diagnostics")
    }
}
