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
        let trustRecord = TrustRecord(peer: clientId.identity, authorizedCapabilities: [.sleep, .lockScreen, .ping])
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

        // 1. Warm-up iterations to prime Network.framework queues, TLS/TCP caches, and CryptoKit engines
        for _ in 0..<3 {
            let ack = try await client.sendCommand(.sleep, to: endpoint, trustedHostPublicKeyHex: hostId.identity.publicKeyHex)
            XCTAssertEqual(ack.status, .executed)
        }

        // 2. Statistically meaningful sample size: 20 measurement iterations
        let sampleCount = 20
        var latencies: [Double] = []
        for _ in 0..<sampleCount {
            let start = DispatchTime.now()
            let ack = try await client.sendCommand(.sleep, to: endpoint, trustedHostPublicKeyHex: hostId.identity.publicKeyHex)
            let durationMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
            latencies.append(durationMs)
            XCTAssertEqual(ack.status, .executed)
        }

        let sortedLatencies = latencies.sorted()
        let minLatency = sortedLatencies.first ?? 0
        let maxLatency = sortedLatencies.last ?? 0
        let meanLatency = sortedLatencies.reduce(0, +) / Double(sampleCount)
        let medianLatency = sampleCount % 2 == 0
            ? (sortedLatencies[sampleCount / 2 - 1] + sortedLatencies[sampleCount / 2]) / 2.0
            : sortedLatencies[sampleCount / 2]
        let p95Index = Int(ceil(Double(sampleCount) * 0.95)) - 1
        let p95Latency = sortedLatencies[max(0, min(p95Index, sampleCount - 1))]

        print("""
        ============================================================
        END-TO-END COMMAND DISPATCH BENCHMARK (V1 SLEEP DISPATCH):
        - Endpoint: \(endpoint)
        - Protocol: Ephemeral P-256 ECDH + Bilateral ECDSA + AES-256-GCM
        - Warm-up Iterations: 3
        - Sample Size: \(sampleCount)
        - Min Latency:    \(String(format: "%6.2f ms", minLatency))
        - Median (p50):   \(String(format: "%6.2f ms", medianLatency))
        - Mean Latency:   \(String(format: "%6.2f ms", meanLatency))
        - p95 Latency:    \(String(format: "%6.2f ms", p95Latency))
        - Max Latency:    \(String(format: "%6.2f ms", maxLatency))
        ============================================================
        """)

        // Assert production SLA boundaries
        XCTAssertLessThan(medianLatency, 100.0, "Median local TCP command round-trip must be under 100ms")
        XCTAssertLessThan(p95Latency, 150.0, "95th-percentile local TCP command round-trip must be under 150ms")
    }
}
