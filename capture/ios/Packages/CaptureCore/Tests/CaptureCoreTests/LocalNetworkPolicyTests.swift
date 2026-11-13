@testable import CaptureCore
import XCTest

/// 決まった答えを返す名前引き。呼ばれた名前を覚える。
final class FakeResolver: HostResolving, @unchecked Sendable {
    let answers: [String: [String]]
    private let lock = NSLock()
    private var _asked: [String] = []
    var asked: [String] { lock.withLock { _asked } }

    init(_ answers: [String: [String]]) { self.answers = answers }

    func resolve(_ host: String) async throws -> [String] {
        lock.withLock { _asked.append(host) }
        guard let found = answers[host] else {
            throw TransferError.network(code: URLError.cannotFindHost.rawValue, message: "not found")
        }
        return found
    }
}

/// 呼ばれたら失敗にする送り方（公開 IP アドレスにはつながないことを確かめる）。
struct NeverTransport: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        XCTFail("つないではいけない: \(request.url)")
        return HTTPResponse(status: 500, body: Data())
    }
}

final class LocalNetworkPolicyTests: XCTestCase {
    func testIPv4Scopes() {
        let cases: [(String, ReceiverAddressScope)] = [
            ("127.0.0.1", .loopback), ("127.255.0.9", .loopback),
            ("10.0.0.1", .privateNetwork), ("10.255.255.255", .privateNetwork),
            ("172.16.0.1", .privateNetwork), ("172.31.255.254", .privateNetwork), ("172.20.10.1", .privateNetwork),
            ("192.168.0.10", .privateNetwork), ("192.168.255.1", .privateNetwork),
            ("169.254.12.34", .linkLocal),
            // 公開 IP アドレス（実際のログにあったものを含む）
            ("198.51.100.23", .publicAddress), ("198.51.100.77", .publicAddress),
            ("203.0.113.45", .publicAddress), ("192.0.2.88", .publicAddress), ("8.8.8.8", .publicAddress),
            // 範囲のすぐ外
            ("172.15.255.255", .publicAddress), ("172.32.0.1", .publicAddress),
            ("192.169.0.1", .publicAddress), ("169.255.0.1", .publicAddress), ("11.0.0.1", .publicAddress),
            // CGNAT はほかの契約者と共有する範囲なので送らない
            ("100.64.0.1", .publicAddress), ("100.127.255.254", .publicAddress),
            ("0.0.0.0", .publicAddress), ("255.255.255.255", .publicAddress), ("224.0.0.251", .publicAddress),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(LocalNetworkPolicy.scope(ofAddress: text), expected, text)
        }
    }

    func testIPv6Scopes() {
        let cases: [(String, ReceiverAddressScope)] = [
            ("::1", .loopback), ("[::1]", .loopback),
            ("fe80::1", .linkLocal), ("fe80::1%en0", .linkLocal), ("[fe80::aede:48ff:fe00:1122%25en5]", .linkLocal),
            ("febf::1", .linkLocal),
            ("fc00::1", .uniqueLocal), ("fd12:3456:789a::1", .uniqueLocal),
            ("2001:db8::1", .publicAddress), ("2400:4050::1", .publicAddress), ("fec0::1", .publicAddress),
            ("::", .publicAddress), ("ff02::fb", .publicAddress),
            // IPv4 を IPv6 で書いたもの
            ("::ffff:192.168.1.5", .privateNetwork), ("::ffff:127.0.0.1", .loopback),
            ("::ffff:169.254.1.1", .linkLocal), ("::ffff:8.8.8.8", .publicAddress), ("::ffff:c0a8:0105", .privateNetwork),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(LocalNetworkPolicy.scope(ofAddress: text), expected, text)
        }
    }

    func testNamesAreNotAddresses() {
        for text in ["mac.local", "localhost", "example.com", "", "1.2.3", "300.1.1.1", "192.168.0.1.example.com"] {
            XCTAssertNil(LocalNetworkPolicy.scope(ofAddress: text), text)
        }
        XCTAssertTrue(LocalNetworkPolicy.isMulticastDNSName("Example-MacBook.local"))
        XCTAssertTrue(LocalNetworkPolicy.isMulticastDNSName("mac.LOCAL."))
        XCTAssertFalse(LocalNetworkPolicy.isMulticastDNSName("local.example.com"))
        XCTAssertTrue(LocalNetworkPolicy.isPublicAddressLiteral("198.51.100.23"))
        XCTAssertFalse(LocalNetworkPolicy.isPublicAddressLiteral("192.168.0.2"))
        XCTAssertFalse(LocalNetworkPolicy.isPublicAddressLiteral("example.com"))
    }

    func testCheckLiteralAddresses() async throws {
        let resolver = FakeResolver([:])
        try await LocalNetworkPolicy.check(host: "192.168.0.2", resolver: resolver)
        try await LocalNetworkPolicy.check(host: "172.20.10.2", resolver: resolver)
        try await LocalNetworkPolicy.check(host: "fe80::1%en0", resolver: resolver)
        await assertRefused("198.51.100.23", resolver: resolver)
        await assertRefused("2001:db8::1", resolver: resolver)
        await assertRefused("100.64.1.1", resolver: resolver)
        XCTAssertEqual(resolver.asked, [], "IP アドレスの文字は引かない")
    }

    func testCheckLocalNamesWithoutResolving() async throws {
        let resolver = FakeResolver([:])
        try await LocalNetworkPolicy.check(host: "Example-MacBook.local", resolver: resolver)
        XCTAssertEqual(resolver.asked, [])
    }

    func testCheckResolvesOtherNamesAndRefusesAnyPublicAddress() async throws {
        let resolver = FakeResolver([
            "localhost": ["127.0.0.1", "::1"],
            "nas.home.arpa": ["192.168.1.20", "fd00::20"],
            "mixed.example": ["192.168.1.20", "203.0.113.5"],
            "public.example": ["93.184.216.34"],
            "empty.example": [],
        ])
        try await LocalNetworkPolicy.check(host: "localhost", resolver: resolver)
        try await LocalNetworkPolicy.check(host: "nas.home.arpa", resolver: resolver)
        await assertRefused("mixed.example", resolver: resolver)
        await assertRefused("public.example", resolver: resolver)
        do {
            try await LocalNetworkPolicy.check(host: "empty.example", resolver: resolver)
            XCTFail("引けない名前は送らない")
        } catch let error as TransferError {
            guard case .network = error else { return XCTFail("\(error)") }
        }
        do {
            try await LocalNetworkPolicy.check(host: "unknown.example", resolver: resolver)
            XCTFail("引けない名前は送らない")
        } catch let error as TransferError {
            guard case .network = error else { return XCTFail("\(error)") }
        }
    }

    func testClientRefusesPublicAddressWithoutConnecting() async {
        let client = TransferClient(receiverURL: URL(string: "http://198.51.100.23:8765")!, token: "123456",
                                    transport: NeverTransport(), resolver: FakeResolver([:]))
        do {
            _ = try await client.ping()
            XCTFail("公開 IP アドレスには送らない")
        } catch {
            XCTAssertEqual(error as? TransferError, .notLocalNetwork(host: "198.51.100.23"))
            XCTAssertEqual((error as? TransferError)?.userMessage,
                           "同じネットワーク（自宅の Wi-Fi・USB ケーブル・インターネット共有）の Mac にだけ送れます。公開 IP アドレスには送りません")
            XCTAssertEqual((error as? TransferError)?.mayBeLocalNetworkProblem, false)
        }
    }

    func testClientRefusesNameResolvingToPublicAddressInUpload() async {
        let client = TransferClient(receiverURL: URL(string: "http://receiver.example:8765")!, token: "123456",
                                    transport: NeverTransport(), resolver: FakeResolver(["receiver.example": ["203.0.113.45"]]))
        let snapshot = TransferSnapshot(sessionId: "S", manifest: TransferManifest(entries: [ManifestEntry(path: "session.json", size: 2, sha256: "x")]),
                                        sessionJSON: Data("{}".utf8), fileURLs: [:])
        let outcome = await client.upload(snapshot)
        XCTAssertEqual(outcome, .failed(.notLocalNetwork(host: "receiver.example")))
    }

    func testSystemResolverReturnsNumericAddresses() async throws {
        let addresses = try await SystemHostResolver().resolve("localhost")
        XCTAssertFalse(addresses.isEmpty)
        for address in addresses { XCTAssertEqual(LocalNetworkPolicy.scope(ofAddress: address), .loopback, address) }
        try await LocalNetworkPolicy.check(host: "localhost", resolver: SystemHostResolver())
    }

    private func assertRefused(_ host: String, resolver: any HostResolving, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await LocalNetworkPolicy.check(host: host, resolver: resolver)
            XCTFail("\(host) には送らない", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? TransferError, .notLocalNetwork(host: host), file: file, line: line)
        }
    }
}
