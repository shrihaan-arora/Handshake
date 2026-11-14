import SwiftUI

/// macOS Apple-Native Design System Theme
public enum MacTheme {
    public enum Spacing {
        public static let xs: CGFloat = 8
        public static let sm: CGFloat = 12
        public static let md: CGFloat = 16
        public static let lg: CGFloat = 24
        public static let xl: CGFloat = 32
    }

    public enum Radius {
        public static let sm: CGFloat = 6
        public static let md: CGFloat = 10
        public static let lg: CGFloat = 14
    }

    public enum Colors {
        public static let connected = Color.green
        public static let idle = Color.secondary
        public static let warning = Color.orange
        public static let destructive = Color.red
        public static let hairline = Color.primary.opacity(0.08)
    }
}

