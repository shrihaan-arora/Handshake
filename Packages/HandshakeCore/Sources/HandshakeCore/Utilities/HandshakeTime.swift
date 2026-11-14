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
    /// Resilient against integer overflow, negative timestamps, and extreme adversarial inputs.
    public static func isTimestampValid(
        _ timestampMilliseconds: Int64,
        referenceTime: Date = Date(),
        maxSkew: TimeInterval = maximumAllowedClockSkewSeconds
    ) -> Bool {
        // Timestamps before epoch or non-positive are invalid in this protocol
        guard timestampMilliseconds > 0 else { return false }

        let referenceMs = Int64(referenceTime.timeIntervalSince1970 * 1000)
        guard referenceMs > 0 else { return false }

        // Prevent integer underflow/overflow on subtraction
        let (diff, overflow) = referenceMs.subtractingReportingOverflow(timestampMilliseconds)
        if overflow {
            return false
        }

        // Guard against abs(Int64.min) overflow
        guard diff != Int64.min else { return false }

        let differenceSeconds = Double(abs(diff)) / 1000.0
        return differenceSeconds <= maxSkew
    }
}

