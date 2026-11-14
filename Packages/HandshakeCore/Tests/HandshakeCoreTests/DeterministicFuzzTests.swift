import XCTest
@testable import HandshakeCore

final class DeterministicFuzzTests: XCTestCase {

    // MARK: - Deterministic PRNG

    /// A fast, reproducible 64-bit XorShift pseudo-random number generator.
    /// Free of third-party dependencies, guaranteeing identical mutation sequences on all platforms.
    struct DeterministicPRNG {
        private var state: UInt64

        init(seed: UInt64 = 0x5EED_C0DE_F00D_1234) {
            self.state = seed != 0 ? seed : 0x123456789ABCDEF0
        }

        mutating func nextUInt64() -> UInt64 {
            var x = state
            x ^= x >> 12
            x ^= x << 25
            x ^= x >> 27
            state = x
            return x &* 0x2545F4914F6CDD1D
        }

        mutating func nextInt(in range: Range<Int>) -> Int {
            guard range.upperBound > range.lowerBound else { return range.lowerBound }
            let span = UInt64(range.upperBound - range.lowerBound)
            return range.lowerBound + Int(nextUInt64() % span)
        }

        mutating func nextBytes(count: Int) -> Data {
            var data = Data(count: count)
            for i in 0..<count {
                data[i] = UInt8(truncatingIfNeeded: nextUInt64())
            }
            return data
        }

        mutating func choose<T>(_ array: [T]) -> T {
            let index = nextInt(in: 0..<array.count)
            return array[index]
        }
    }

    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    // MARK: - Fuzzing Engine

    private enum MutationStrategy: String, CaseIterable {
        case bitFlips
        case byteDeletion
        case byteInsertion
        case structuralTokens
        case randomGarbage
    }

    private func mutateData(
        _ original: Data,
        strategy: MutationStrategy,
        prng: inout DeterministicPRNG
    ) -> Data {
        switch strategy {
        case .bitFlips:
            guard !original.isEmpty else { return original }
            var mutated = original
            let flipCount = prng.nextInt(in: 1..<6)
            for _ in 0..<flipCount {
                let byteIdx = prng.nextInt(in: 0..<mutated.count)
                let bitIdx = prng.nextInt(in: 0..<8)
                mutated[byteIdx] ^= (1 << bitIdx)
            }
            return mutated

        case .byteDeletion:
            guard original.count > 4 else { return Data() }
            var mutated = original
            let deleteCount = prng.nextInt(in: 1..<min(32, original.count))
            let startIdx = prng.nextInt(in: 0..<(original.count - deleteCount))
            mutated.removeSubrange(startIdx..<(startIdx + deleteCount))
            return mutated

        case .byteInsertion:
            var mutated = original
            let insertCount = prng.nextInt(in: 1..<32)
            let insertBytes = prng.nextBytes(count: insertCount)
            let insertIdx = original.isEmpty ? 0 : prng.nextInt(in: 0..<original.count)
            mutated.insert(contentsOf: insertBytes, at: insertIdx)
            return mutated

        case .structuralTokens:
            let tokens = [
                "%s%n%@%x%p",
                "\\u0000",
                "\\\"",
                "-9223372036854775809",
                "9223372036854775808",
                "1e309",
                "-1e309",
                "NaN",
                "Infinity",
                "-Infinity",
                "null",
                "{}",
                "[]",
                "true",
                "false",
                "<script>alert(1)</script>",
                "../../../../../../etc/passwd",
                String(repeating: "[", count: 100) + String(repeating: "]", count: 100)
            ]
            let chosenToken = prng.choose(tokens)
            let tokenBytes = Data(chosenToken.utf8)
            var mutated = original
            if original.count > 2 {
                let insertIdx = prng.nextInt(in: 1..<(original.count - 1))
                mutated.insert(contentsOf: tokenBytes, at: insertIdx)
            } else {
                mutated.append(tokenBytes)
            }
            return mutated

        case .randomGarbage:
            let length = prng.nextInt(in: 1..<2048)
            return prng.nextBytes(count: length)
        }
    }

    // MARK: - 1. Deterministic Fuzzing Across All Codable Models

    func testDeterministicFuzzingOfProtocolModels() throws {
        var prng = DeterministicPRNG(seed: 0xDEAD_BEEF_CAFE_1234)
        let iterationsPerModel = 50

        // Base valid instances
        let baseDate = Date(timeIntervalSince1970: 1700000000)
        let identity = DeviceIdentity(
            publicKeyHex: "0123456789abcdef",
            displayName: "Test Host Mac",
            deviceType: .mac,
            modelIdentifier: "Mac15,3",
            systemVersion: "macOS 14.5",
            createdAt: baseDate
        )
        let envelope = CommandEnvelope(
            version: 1,
            senderPublicKeyHex: "0123",
            recipientPublicKeyHex: "4567",
            sequenceNumber: 1,
            timestampMilliseconds: 1700000000000,
            nonceHex: "0011",
            ciphertextHex: "aabb",
            authTagHex: "ccdd",
            signatureHex: "eeff"
        )
        let message = CommandMessage(command: .lockScreen, timestamp: baseDate)
        let invitation = PairingInvitation(hostIdentity: identity, ephemeralPublicKeyHex: "beef", createdAt: baseDate)
        let request = PairingRequest(invitationId: invitation.id, clientIdentity: identity, clientEphemeralPublicKeyHex: "aa", nonceProofHex: "bb")
        let response = PairingResponse(invitationId: invitation.id, hostIdentity: identity, hostEphemeralPublicKeyHex: "cc", sasFingerprintCode: "123456")
        let confirmation = PairingConfirmation(invitationId: invitation.id, isApproved: true, confirmedSASCode: "123456")
        let trustRecord = TrustRecord(peer: identity, pairedAt: baseDate)
        let completion = PairingCompletion(invitationId: invitation.id, isSuccessful: true, establishedTrustRecord: trustRecord)
        let version = ProtocolVersion(major: 1, minor: 0)

        let testCases: [(name: String, baseData: Data, decode: (Data) -> Void)] = [
            ("CommandEnvelope", try jsonEncoder.encode(envelope), { [self] in _ = try? jsonDecoder.decode(CommandEnvelope.self, from: $0) }),
            ("CommandMessage", try jsonEncoder.encode(message), { [self] in _ = try? jsonDecoder.decode(CommandMessage.self, from: $0) }),
            ("PairingInvitation", try jsonEncoder.encode(invitation), { [self] in _ = try? jsonDecoder.decode(PairingInvitation.self, from: $0) }),
            ("PairingRequest", try jsonEncoder.encode(request), { [self] in _ = try? jsonDecoder.decode(PairingRequest.self, from: $0) }),
            ("PairingResponse", try jsonEncoder.encode(response), { [self] in _ = try? jsonDecoder.decode(PairingResponse.self, from: $0) }),
            ("PairingConfirmation", try jsonEncoder.encode(confirmation), { [self] in _ = try? jsonDecoder.decode(PairingConfirmation.self, from: $0) }),
            ("PairingCompletion", try jsonEncoder.encode(completion), { [self] in _ = try? jsonDecoder.decode(PairingCompletion.self, from: $0) }),
            ("TrustRecord", try jsonEncoder.encode(trustRecord), { [self] in _ = try? jsonDecoder.decode(TrustRecord.self, from: $0) }),
            ("DeviceIdentity", try jsonEncoder.encode(identity), { [self] in _ = try? jsonDecoder.decode(DeviceIdentity.self, from: $0) }),
            ("ProtocolVersion", try jsonEncoder.encode(version), { [self] in _ = try? jsonDecoder.decode(ProtocolVersion.self, from: $0) })
        ]

        var totalFuzzRuns = 0

        for (_, baseData, decodeBlock) in testCases {
            for strategy in MutationStrategy.allCases {
                for _ in 0..<iterationsPerModel {
                    let fuzzed = mutateData(baseData, strategy: strategy, prng: &prng)
                    // The decodeBlock must execute cleanly: either parse or fail gracefully without fatal trap
                    decodeBlock(fuzzed)
                    totalFuzzRuns += 1
                }
            }
        }

        // Verify that 2,500 deterministic fuzz mutations were executed safely
        XCTAssertEqual(totalFuzzRuns, 10 * MutationStrategy.allCases.count * iterationsPerModel)
    }

    // MARK: - 2. Deterministic High-Volume Stress Testing for SequenceCounter

    func testSequenceCounterFuzzingStress() async {
        var prng = DeterministicPRNG(seed: 0xCAFE_BABE_9876_5432)
        let counter = SequenceCounter()

        // Generate 1,000 pseudo-random operations (increments, random incoming, replayed incoming)
        var acceptedSequences: [UInt64] = []

        for _ in 0..<1000 {
            let op = prng.nextInt(in: 0..<4)
            switch op {
            case 0:
                // Next outgoing
                let out = await counter.nextOutgoing()
                XCTAssertGreaterThan(out, 0)

            case 1:
                // Random incoming sequence number
                let randSeq = prng.nextUInt64()
                // Must evaluate safely without trap
                _ = await counter.validateAndAcceptIncoming(randSeq)

            case 2:
                // Replay of previously accepted sequence if available
                if let previous = acceptedSequences.randomElement() {
                    let accepted = await counter.validateAndAcceptIncoming(previous)
                    XCTAssertFalse(accepted, "Replay of previously accepted sequence \(previous) must fail")
                }

            case 3:
                // Controlled sequence near recent numbers
                let delta = UInt64(prng.nextInt(in: 1..<50))
                let seq = (acceptedSequences.last ?? 0) &+ delta
                if seq > 0 {
                    let accepted = await counter.validateAndAcceptIncoming(seq)
                    if accepted {
                        acceptedSequences.append(seq)
                    }
                }

            default:
                break
            }
        }
    }

    // MARK: - 3. Deterministic Timestamp Fuzzing for HandshakeTime

    func testHandshakeTimeFuzzingStress() {
        var prng = DeterministicPRNG(seed: 0xFACE_FEED_1122_3344)
        let referenceDate = Date()

        for _ in 0..<1000 {
            // Generate arbitrary Int64 timestamps across full signed 64-bit integer range
            let rawWord = prng.nextUInt64()
            let signedTimestamp = Int64(bitPattern: rawWord)

            // Must evaluate safely without integer overflow trap
            let isValid = HandshakeTime.isTimestampValid(signedTimestamp, referenceTime: referenceDate)

            // Any negative timestamp must be rejected
            if signedTimestamp <= 0 {
                XCTAssertFalse(isValid, "Negative or zero timestamp \(signedTimestamp) must never be valid")
            }
        }
    }
}
