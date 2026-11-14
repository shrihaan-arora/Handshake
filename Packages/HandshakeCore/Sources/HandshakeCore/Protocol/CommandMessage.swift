import Foundation

/// High-level, strongly-typed command packet before payload encryption.
public struct CommandMessage: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let command: CommandType
    public let timestamp: Date
    public let validityWindowSeconds: TimeInterval
    public let parameters: [String: String]

    public init(
        id: UUID = UUID(),
        command: CommandType,
        timestamp: Date = Date(),
        validityWindowSeconds: TimeInterval = 30.0,
        parameters: [String: String] = [:]
    ) {
        self.id = id
        self.command = command
        self.timestamp = timestamp
        self.validityWindowSeconds = validityWindowSeconds
        self.parameters = parameters
    }

    /// Evaluates whether this command has surpassed its validity horizon.
    public func isExpired(at date: Date = Date()) -> Bool {
        let age = date.timeIntervalSince(timestamp)
        // Check both if command is too old, or if it was issued too far in the future (>5s clock skew)
        return age > validityWindowSeconds || age < -5.0
    }
}

