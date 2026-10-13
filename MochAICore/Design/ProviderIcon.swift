import SwiftUI

/// Claude, OpenAI, Cursor, and OpenCode marks from Simple Icons (CC0).
struct ProviderIcon: View {
    var provider: ProviderID
    var size: CGFloat = 16

    var body: some View {
        image
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var image: some View {
        switch provider {
        case .claude:
            branded("ProviderClaude")
        case .codex:
            monochrome("ProviderCodex")
        case .cursor:
            monochrome("ProviderCursor")
        case .openCodeGo:
            monochrome("ProviderOpenCode")
        case .antigravity:
            AntigravityMark()
        case .mock:
            Color.clear
        }
    }

    private func branded(_ name: String) -> some View {
        Image(name)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(contentMode: .fit)
    }

    private func monochrome(_ name: String) -> some View {
        Image(name)
            .resizable()
            .renderingMode(.template)
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(.primary)
    }
}

private struct AntigravityMark: View {
    var body: some View {
        GeometryReader { geo in
            AntigravityArch()
                .stroke(
                    LinearGradient(
                        colors: [
                            Color(red: 0.93, green: 0.28, blue: 0.36),
                            Color(red: 0.98, green: 0.72, blue: 0.22),
                            Color(red: 0.22, green: 0.78, blue: 0.46),
                            Color(red: 0.22, green: 0.45, blue: 0.95)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: geo.size.width * 0.22, lineCap: .round)
                )
        }
    }
}

private struct AntigravityArch: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.16, y: rect.maxY - rect.height * 0.16))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - rect.width * 0.16, y: rect.maxY - rect.height * 0.16),
            control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.42)
        )
        return path
    }
}
