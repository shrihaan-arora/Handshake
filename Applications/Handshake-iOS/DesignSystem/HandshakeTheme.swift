import SwiftUI

/// Handshake Apple-Native Design System Theme
/// Follows Apple Human Interface Guidelines with system semantic colors and dynamic materials.
public enum HandshakeTheme {
    // MARK: - Spacing Grid
    public enum Spacing {
        /// 4pt
        public static let xxs: CGFloat = 4
        /// 8pt
        public static let xs: CGFloat = 8
        /// 12pt
        public static let sm: CGFloat = 12
        /// 16pt
        public static let md: CGFloat = 16
        /// 24pt
        public static let lg: CGFloat = 24
        /// 32pt
        public static let xl: CGFloat = 32
        /// 44pt (Apple minimum touch target)
        public static let touchTarget: CGFloat = 44
    }

    // MARK: - Corner Radii
    public enum Radius {
        /// 8pt
        public static let sm: CGFloat = 8
        /// 12pt
        public static let md: CGFloat = 12
        /// 16pt
        public static let lg: CGFloat = 16
        /// 22pt (Pill buttons & large cards)
        public static let pill: CGFloat = 22
    }

    // MARK: - Semantic Colors
    public enum Colors {
        public static let brandAccent = Color.blue
        public static let connected = Color.green
        public static let connecting = Color.orange
        public static let disconnected = Color.secondary
        public static let destructive = Color.red
        public static let hairline = Color.primary.opacity(0.08)
    }

    // MARK: - Animations
    public enum Animation {
        public static let quick = SwiftUI.Animation.spring(response: 0.25, dampingFraction: 0.8)
        public static let smooth = SwiftUI.Animation.spring(response: 0.35, dampingFraction: 0.85)
    }
}
