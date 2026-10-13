import SwiftUI

public struct AboutView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 18) {
            MascotView(pose: .coffee, size: 108)
            VStack(spacing: 6) {
                Text("MochAI")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text(AppIdentity.tagline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 4) {
                Text("Version \(AppIdentity.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(AppIdentity.copyright)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 18) {
                Link("Website", destination: AppIdentity.website)
                Link("GitHub", destination: AppIdentity.github)
                Link("sdglhm.com", destination: AppIdentity.authorWebsite)
            }
            Text("MIT License")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityIdentifier("about")
    }
}
