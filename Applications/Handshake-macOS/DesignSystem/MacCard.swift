import SwiftUI

public struct MacCard<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MacTheme.Spacing.sm) {
            content
        }
        .padding(MacTheme.Spacing.md)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: MacTheme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MacTheme.Radius.md, style: .continuous)
                .stroke(MacTheme.Colors.hairline, lineWidth: 1)
        )
    }
}
