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
    /// Resilient against integer overflow (saturates at UInt64.max).
    public func nextOutgoing() -> UInt64 {
        guard outgoingCounter < UInt64.max else {
            return UInt64.max
        }
        outgoingCounter += 1
        return outgoingCounter
    }

    /// Checks whether an incoming sequence number would be accepted without mutating the counter state.
    public func checkIncoming(_ sequenceNumber: UInt64) -> Bool {
        guard sequenceNumber > 0 else { return false }
        if sequenceNumber > highestIncomingSequence {
            return true
        }
        if highestIncomingSequence - sequenceNumber < replayWindowSize {
            return !seenRecentSequences.contains(sequenceNumber)
        }
        return false
    }

    /// Validates an incoming sequence number against replayed or dropped frames.
    /// Returns true if valid and updates the tracking state; returns false on replay.
    /// Resilient against overflow attacks with high sequence numbers.
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

        // If it's within the window, check if it's already been seen.
        // Use subtraction because sequenceNumber <= highestIncomingSequence at this branch,
        // preventing integer overflow when sequenceNumber is near UInt64.max.
        if highestIncomingSequence - sequenceNumber < replayWindowSize {
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

