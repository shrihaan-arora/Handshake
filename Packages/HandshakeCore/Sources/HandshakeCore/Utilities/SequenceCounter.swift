import Foundation

/// Thread-safe monotonic sequence counter and replay verification engine.
public actor SequenceCounter {
    private var outgoingCounter: UInt64 = 0
    private var highestIncomingSequence: UInt64 = 0
    private var seenRecentSequences: Set<UInt64> = []
    private let replayWindowSize: UInt64 = 1000

    public init(initialCounter: UInt64 = 0) {
        self.outgoingCounter = initialCounter
    }

    /// Increments and returns the next monotonic sequence number for an outgoing packet.
    public func nextOutgoing() -> UInt64 {
        outgoingCounter += 1
        return outgoingCounter
    }

    /// Validates an incoming sequence number against replayed or dropped frames.
    /// Returns true if valid and updates the tracking state; returns false on replay.
    public func validateAndAcceptIncoming(_ sequenceNumber: UInt64) -> Bool {
        // Sequence numbers must be strictly positive
        guard sequenceNumber > 0 else { return false }

        // If the number is greater than highest seen, accept and slide window
        if sequenceNumber > highestIncomingSequence {
            highestIncomingSequence = sequenceNumber
            seenRecentSequences.insert(sequenceNumber)

            // Evict sequences older than the replay window
            if sequenceNumber > replayWindowSize {
                let threshold = sequenceNumber - replayWindowSize
                seenRecentSequences = seenRecentSequences.filter { $0 > threshold }
            }
            return true
        }

        // If it's within the window, check if it's already been seen
        if sequenceNumber + replayWindowSize > highestIncomingSequence {
            if seenRecentSequences.contains(sequenceNumber) {
                // Replay detected!
                return false
            } else {
                // Out-of-order frame within acceptable sliding window
                seenRecentSequences.insert(sequenceNumber)
                return true
            }
        }

        // Sequence number is too old (outside window)
        return false
    }

    /// Reset sequence state (e.g., when a new authenticated session key is negotiated).
    public func reset(initialCounter: UInt64 = 0) {
        self.outgoingCounter = initialCounter
        self.highestIncomingSequence = 0
        self.seenRecentSequences.removeAll()
    }
}

