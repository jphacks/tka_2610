import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// 送り先のアドレスの種類。送ってよいのは `.publicAddress` 以外（同じネットワークの中）だけ。
public enum ReceiverAddressScope: String, Equatable, Sendable {
    /// 127.0.0.0/8・::1
    case loopback
    /// 10/8・172.16/12・192.168/16（インターネット共有の 172.20.10.0/28 もここ）
    case privateNetwork
    /// 169.254/16・fe80::/10（USB ケーブルや、ルーターの無い直接の接続）
    case linkLocal
    /// fc00::/7（IPv6 の ULA）
    case uniqueLocal
    /// それ以外。100.64/10（携帯会社の CGNAT）も、ほかの契約者と共有する範囲で同じ LAN とは限らないので、ここに入れる。
    case publicAddress

    public var isLocal: Bool { self != .publicAddress }
}

/// 名前を IP アドレス（文字）に引く（テストでは差し替える）。
public protocol HostResolving: Sendable {
    func resolve(_ host: String) async throws -> [String]
}

/// getaddrinfo で引く。
public struct SystemHostResolver: HostResolving {
    public init() {}

    public func resolve(_ host: String) async throws -> [String] {
        try await Task.detached(priority: .userInitiated) { try Self.resolveBlocking(host) }.value
    }

    static func resolveBlocking(_ host: String) throws -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_STREAM
        #else
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #endif
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else {
            let reason = String(cString: gai_strerror(status))
            throw TransferError.network(code: URLError.cannotFindHost.rawValue, message: "\(host) が見つかりません（\(reason)）")
        }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let text = String(cString: buffer)
                if !addresses.contains(text) { addresses.append(text) }
            }
            cursor = info.pointee.ai_next
        }
        return addresses
    }
}

/// 送り先が同じネットワークの中かを決める（docs/transfer-protocol.md「同じネットワークの中だけ」）。
/// 受信側（memoria_receiver.py の `is_local_address`）と同じ範囲を使う。アプリから外す方法は無い。
public enum LocalNetworkPolicy {
    /// IP アドレスの文字（`[]` やゾーン `%en0` が付いていてもよい）の種類。IP アドレスでなければ nil。
    public static func scope(ofAddress text: String) -> ReceiverAddressScope? {
        var host = text.trimmingCharacters(in: .whitespaces)
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let percent = host.firstIndex(of: "%") { host = String(host[..<percent]) }
        guard !host.isEmpty else { return nil }

        var v4 = in_addr()
        if host.contains("."), !host.contains(":"), inet_pton(AF_INET, host, &v4) == 1 {
            return scope(ofIPv4: withUnsafeBytes(of: &v4) { Array($0) })
        }
        var v6 = in6_addr()
        if host.contains(":"), inet_pton(AF_INET6, host, &v6) == 1 {
            return scope(ofIPv6: withUnsafeBytes(of: &v6) { Array($0) })
        }
        return nil
    }

    static func scope(ofIPv4 b: [UInt8]) -> ReceiverAddressScope {
        guard b.count == 4 else { return .publicAddress }
        switch (b[0], b[1]) {
        case (127, _): return .loopback
        case (10, _): return .privateNetwork
        case (172, 16...31): return .privateNetwork
        case (192, 168): return .privateNetwork
        case (169, 254): return .linkLocal
        default: return .publicAddress
        }
    }

    static func scope(ofIPv6 b: [UInt8]) -> ReceiverAddressScope {
        guard b.count == 16 else { return .publicAddress }
        // ::ffff:a.b.c.d（IPv4 を IPv6 で書いたもの）は IPv4 として見る。
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
            return scope(ofIPv4: Array(b[12..<16]))
        }
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return .loopback }
        if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return .linkLocal }
        if (b[0] & 0xfe) == 0xfc { return .uniqueLocal }
        return .publicAddress
    }

    /// `.local` の名前（Bonjour・mDNS）。同じリンクの中でしか引けないので、引かずに通す。
    public static func isMulticastDNSName(_ host: String) -> Bool {
        var name = host.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        return name.hasSuffix(".local")
    }

    /// 送り先が公開 IP アドレスの文字なら true（名前は引かないので false）。画面ですぐ知らせるのに使う。
    public static func isPublicAddressLiteral(_ host: String) -> Bool {
        scope(ofAddress: host) == .publicAddress
    }

    /// 送る前に確かめる。IP アドレスの文字ならその種類を、`.local` なら通し、ほかの名前は引いた全部のアドレスを見る。
    /// 1 つでも公開 IP アドレスがあれば `TransferError.notLocalNetwork` を投げる。
    public static func check(host: String, resolver: any HostResolving) async throws {
        if let scope = scope(ofAddress: host) {
            guard scope.isLocal else { throw TransferError.notLocalNetwork(host: host) }
            return
        }
        if isMulticastDNSName(host) { return }
        let addresses = try await resolver.resolve(host)
        guard !addresses.isEmpty else {
            throw TransferError.network(code: URLError.cannotFindHost.rawValue, message: "\(host) が見つかりません")
        }
        // 引いたアドレスが 1 つでも公開 IP アドレス（または読めない）なら送らない。
        for address in addresses {
            guard let scope = scope(ofAddress: address), scope.isLocal else {
                throw TransferError.notLocalNetwork(host: host)
            }
        }
    }
}
