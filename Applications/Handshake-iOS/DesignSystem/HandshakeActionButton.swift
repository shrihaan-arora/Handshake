import SwiftUI

public struct HandshakeActionButton: View {
    public enum Style {
        case primary
        case secondary
        case destructive
    }

    public let title: String
    public let subtitle: String?
    public let systemImage: String
    public let style: Style
    public let isEnabled: Bool
    public let action: () -> Void

    public init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        style: Style = .primary,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.style = style
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        Button(action: {
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            #endif
            action()
        }) {
            HStack(spacing: HandshakeTheme.Spacing.md) {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(textColor)

                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, HandshakeTheme.Spacing.md)
            .padding(.vertical, HandshakeTheme.Spacing.sm + 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 64)
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: HandshakeTheme.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HandshakeTheme.Radius.md, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(TouchTargetButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.45)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(subtitle ?? ""))
        .accessibilityAddTraits(.isButton)
    }

    private var iconColor: Color {
        switch style {
        case .primary: return .blue
        case .secondary: return .primary
        case .destructive: return .red
        }
    }

    private var textColor: Color {
        switch style {
        case .primary, .secondary: return .primary
        case .destructive: return .red
        }
    }

    private var backgroundColor: some ShapeStyle {
        switch style {
        case .primary:
            return AnyShapeStyle(.regularMaterial)
        case .secondary:
            return AnyShapeStyle(.thinMaterial)
        case .destructive:
            return AnyShapeStyle(Color.red.opacity(0.08))
        }
    }

    private var borderColor: Color {
        switch style {
        case .destructive:
            return Color.red.opacity(0.2)
        default:
            return HandshakeTheme.Colors.hairline
        }
    }
}

private struct TouchTargetButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1.0)
            .animation(reduceMotion ? nil : HandshakeTheme.Animation.quick, value: configuration.isPressed)
    }
}

