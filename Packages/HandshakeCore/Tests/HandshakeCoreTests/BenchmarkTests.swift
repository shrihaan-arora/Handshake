import XCTest
import CryptoKit
import Network
@testable import HandshakeCore

final class BenchmarkTests: XCTestCase {

    private var testKeychain: KeychainManager!

    override func setUp() {
        super.setUp()
        testKeychain = KeychainManager(service: "com.handshake.benchmarks.\(UUID().uuidString)")
    }

    override func tearDown() {
        testKeychain = nil
        super.tearDown()
    }

    // MARK: - 1. Cryptographic Latency Benchmarks

    func testCryptographicPrimitivesPerformance() throws {
        let iterations = 100

        // 1. P-256 Key Generation
        let keyGenStart = DispatchTime.now()
        for _ in 0..<iterations {
            _ = P256.Signing.PrivateKey()
        }
        let keyGenElapsed = Double(DispatchTime.now().uptimeNanoseconds - keyGenStart.uptimeNanoseconds) / 1_000_000.0 / Double(iterations)

        // 2. P-256 ECDSA Signing
        let privateKey = P256.Signing.PrivateKey()
        let sampleData = "Handshake-Benchmark-Data-Sample-\(UUID().uuidString)".data(using: .utf8)!
        let signStart = DispatchTime.now()
        for _ in 0..<iterations {
            _ = try privateKey.signature(for: sampleData)
        }
        let signElapsed = Double(DispatchTime.now().uptimeNanoseconds - signStart.uptimeNanoseconds) / 1_000_000.0 / Double(iterations)

        // 3. P-256 ECDSA Verification
        let signature = try privateKey.signature(for: sampleData)
        let publicKey = privateKey.publicKey
        let verifyStart = DispatchTime.now()
        for _ in 0..<iterations {
            _ = publicKey.isValidSignature(signature, for: sampleData)
        }
        let verifyElapsed = Double(DispatchTime.now().uptimeNanoseconds - verifyStart.uptimeNanoseconds) / 1_000_000.0 / Double(iterations)

        // 4. P-256 ECDH Key Agreement
        let aliceKey = P256.KeyAgreement.PrivateKey()
        let bobKey = P256.KeyAgreement.PrivateKey()
        let bobPub = bobKey.publicKey
        let ecdhStart = DispatchTime.now()
        for _ in 0..<iterations {
            _ = try aliceKey.sharedSecretFromKeyAgreement(with: bobPub)
        }
        let ecdhElapsed = Double(DispatchTime.now().uptimeNanoseconds - ecdhStart.uptimeNanoseconds) / 1_000_000.0 / Double(iterations)

        // 5. AES-256-GCM Seal & Open
        let symmetricKey = SymmetricKey(size: .bits256)
        let nonce = AES.GCM.Nonce()
        let gcmStart = DispatchTime.now()
        for _ in 0..<iterations {
            let box = try AES.GCM.seal(sampleData, using: symmetricKey, nonce: nonce)
            _ = try AES.GCM.open(box, using: symmetricKey)
        }
        let gcmElapsed = Double(DispatchTime.now().uptimeNanoseconds - gcmStart.uptimeNanoseconds) / 1_000_000.0 / Double(iterations)

        print("""
        ============================================================
        HANDSHAKE CRYPTOGRAPHIC BENCHMARK REPORT:
        - P-256 KeyGen Latency: \(String(format: "%.3f", keyGenElapsed)) ms / op
        - P-256 ECDSA Signing: \(String(format: "%.3f", signElapsed)) ms / op
        - P-256 ECDSA Verify: \(String(format: "%.3f", verifyElapsed)) ms / op
        - P-256 ECDH Agreement: \(String(format: "%.3f", ecdhElapsed)) ms / op
        - AES-256-GCM Roundtrip: \(String(format: "%.4f", gcmElapsed)) ms / op
        ============================================================
        """)

        XCTAssertLessThan(keyGenElapsed, 15.0, "Key generation must be sub-15ms")
        XCTAssertLessThan(signElapsed, 10.0, "Signing must be sub-10ms")
        XCTAssertLessThan(verifyElapsed, 10.0, "Verification must be sub-10ms")
        XCTAssertLessThan(ecdhElapsed, 10.0, "ECDH agreement must be sub-10ms")
        XCTAssertLessThan(gcmElapsed, 1.0, "AES-256-GCM roundtrip must be sub-1ms")
    }

    // MARK: - 2. Monotonic Replay Window Microbenchmark

    func testSequenceCounterThroughput() async {
        let counter = SequenceCounter()
        let iterations: UInt64 = 5_000

        let start = DispatchTime.now()
        for seq in 1...iterations {
            let accepted = await counter.validateAndAcceptIncoming(seq)
            XCTAssertTrue(accepted)
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
        let perOpMicroseconds = (elapsed * 1000.0) / Double(iterations)

        print("SequenceCounter throughput: \(String(format: "%.2f", perOpMicroseconds)) µs per operation across \(iterations) ops.")
        XCTAssertLessThan(perOpMicroseconds, 50.0, "Actor sequence counter validation must be sub-50µs per op in debug mode")
    }

    // MARK: - 3. End-to-End Loopback Dispatch Latency

    func testEndToEndLoopbackCommandLatency() async throws {
        // Setup Host Identity & TrustStore
        let hostId = try CryptoIdentity.createNew(
            label: "bench.host.id",
            displayName: "Benchmark Mac",
            deviceType: .mac,
            modelIdentifier: "Mac15,3",
            systemVersion: "15.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )
        let clientId = try CryptoIdentity.createNew(
            label: "bench.client.id",
            displayName: "Benchmark iPhone",
            deviceType: .iPhone,
            modelIdentifier: "iPhone16,1",
            systemVersion: "18.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )

        let trustStore = TrustStore(keychain: testKeychain, storageAccount: "bench.truststore")
        let trustRecord = TrustRecord(peer: clientId.identity, authorizedCapabilities: [.lockScreen, .sleep, .ping])
        try await trustStore.addOrUpdate(trustRecord)

        let serverPort: UInt16 = 5898
        let server = HandshakeServer(
            port: serverPort,
            serviceType: "_bench._tcp",
            hostIdentity: hostId,
            trustStore: trustStore,
            executionHandler: { message, peer in
                return .executed
            }
        )

        try await server.start()
        defer {
            Task { await server.stop() }
        }

        // Setup Client
        let client = HandshakeClient(clientIdentity: clientId)
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .init(integerLiteral: serverPort))

        // Measure round-trip dispatch latency across 5 iterations
        var latencies: [Double] = []
        for _ in 0..<5 {
            let start = DispatchTime.now()
            let ack = try await client.sendCommand(.lockScreen, to: endpoint, trustedHostPublicKeyHex: hostId.identity.publicKeyHex)
            let durationMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
            latencies.append(durationMs)
            XCTAssertEqual(ack.status, .executed)
        }

        let avgLatency = latencies.reduce(0, +) / Double(latencies.count)
        print("""
        ============================================================
        END-TO-END COMMAND DISPATCH BENCHMARK:
        - Port: \(serverPort) (TCP Loopback)
        - Iterations: 5
        - Measurements: \(latencies.map { String(format: "%.2f ms", $0) })
        - Average Latency: \(String(format: "%.2f", avgLatency)) ms
        ============================================================
        """)

        XCTAssertLessThan(avgLatency, 50.0, "Average local TCP command round-trip must be under 50ms")
    }
}
