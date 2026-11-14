import Foundation

/// High-precision, replay-resistant timing utilities.
public enum HandshakeTime {
    /// Maximum allowed clock skew between sender and receiver in seconds.
    public static let maximumAllowedClockSkewSeconds: TimeInterval = 30.0

    /// Returns the current Unix epoch time in milliseconds.
    public static var currentEpochMilliseconds: Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// Verifies if a given timestamp falls within the allowed clock skew window.
    public static func isTimestampValid(
        _ timestampMilliseconds: Int64,
        referenceTime: Date = Date(),
        maxSkew: TimeInterval = maximumAllowedClockSkewSeconds
    ) -> Bool {
        let referenceMs = Int64(referenceTime.timeIntervalSince1970 * 1000)
        let differenceSeconds = Double(abs(referenceMs - timestampMilliseconds)) / 1000.0
        return differenceSeconds <= maxSkew
    }
}
