import CaptureCore
import dnssd
import Foundation
import Network

/// 同じ Wi-Fi の受信側（Bonjour `_memoriacap._tcp`）を探す。
@MainActor
final class ReceiverBrowser: ObservableObject {
    struct Receiver: Identifiable, Equatable {
        let id: String
        let name: String
        let host: String?
        let port: Int?
        let protocolVersion: String?

        var url: URL? {
            guard let host, let port else { return nil }
            return URL(string: "http://\(host):\(port)")
        }
    }

    enum State: Equatable {
        case idle, searching
        /// ローカルネットワークの許可が無い。
        case localNetworkDenied
        case failed(String)
    }

    @Published private(set) var receivers: [Receiver] = []
    @Published private(set) var state: State = .idle

    private var browser: NWBrowser?

    func start() {
        stop()
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_memoriacap._tcp", domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in self?.handle(state: newState) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap(Self.receiver(from:)).sorted { $0.name < $1.name }
            Task { @MainActor in self?.receivers = found }
        }
        self.browser = browser
        state = .searching
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        if state == .searching { state = .idle }
    }

    private func handle(state newState: NWBrowser.State) {
        switch newState {
        case .ready, .setup:
            state = .searching
        case .waiting(let error), .failed(let error):
            state = Self.isPolicyDenied(error) ? .localNetworkDenied : .failed(error.localizedDescription)
        case .cancelled:
            break
        @unknown default:
            break
        }
    }

    /// ローカルネットワークを許可していないとき、NWBrowser は PolicyDenied（−65570）で待ちになる。
    nonisolated static func isPolicyDenied(_ error: NWError) -> Bool {
        if case let .dns(code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) { return true }
        return false
    }

    nonisolated private static func receiver(from result: NWBrowser.Result) -> Receiver? {
        guard case let .service(name, _, _, _) = result.endpoint else { return nil }
        var host: String?, port: Int?, version: String?
        if case let .bonjour(txt) = result.metadata {
            host = txt["host"]
            port = txt["port"].flatMap { Int($0) }
            version = txt["pv"]
        }
        return Receiver(id: name, name: name, host: host, port: port, protocolVersion: version)
    }
}
