import SwiftUI

/// A clean, minimalist Apple-native container with subtle borders and system materials.
public struct HandshakeCard<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HandshakeTheme.Spacing.sm) {
            content
        }
        .padding(HandshakeTheme.Spacing.md)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: HandshakeTheme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HandshakeTheme.Radius.lg, style: .continuous)
                .stroke(HandshakeTheme.Colors.hairline, lineWidth: 1)
        )
    }
}

