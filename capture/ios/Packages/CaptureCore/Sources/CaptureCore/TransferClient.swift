import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - HTTP（差し替えられる）

public struct HTTPRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    /// 本文をこのファイルから送る（写真・マスク。メモリに読み込まない）。`body` より優先。
    public var bodyFileURL: URL?

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil, bodyFileURL: URL? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.bodyFileURL = bodyFileURL
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// URLSession で送る。
public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(timeout: TimeInterval = 30) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = 10 * 60
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response): (Data, URLResponse)
        if let file = request.bodyFileURL {
            // ファイルから少しずつ送る（48 枚・150 MB ほどのセッションでも、1 枚分もメモリに載せない）。
            (data, response) = try await session.upload(for: urlRequest, fromFile: file)
        } else if let body = request.body {
            (data, response) = try await session.upload(for: urlRequest, from: body)
        } else {
            (data, response) = try await session.data(for: urlRequest)
        }
        guard let http = response as? HTTPURLResponse else {
            throw TransferError.unexpectedResponse("HTTP の応答ではありません")
        }
        return HTTPResponse(status: http.statusCode, body: data)
    }
}

public protocol Sleeper: Sendable {
    func sleep(seconds: Double) async throws
}

public struct TaskSleeper: Sleeper {
    public init() {}
    public func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

public struct RetryPolicy: Sendable {
    /// 1 回の要求を何回まで試すか。
    public var maxAttempts: Int
    /// 最初の待ち時間（秒）。2 回目以降は倍にする。
    public var baseDelay: Double

    public init(maxAttempts: Int = 3, baseDelay: Double = 0.5) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
    }
}

// MARK: - エラー

public enum TransferError: Error, Equatable, Sendable {
    /// つながらない（URLError のコードと文）。
    case network(code: Int, message: String)
    /// ペアリングコードが違う（401）。
    case unauthorized
    case http(status: Int, message: String)
    case unexpectedResponse(String)
    /// 受信側ではない（service や protocolVersion が違う）。
    case notReceiver(String)
    /// 送っている間にファイルが変わった。
    case fileChanged(String)
    /// commit で足りないと言われた（409）。
    case incomplete([String])
    /// commit で session.json がおかしいと言われた（422）。
    case invalid([String])
    case cancelled

    /// ローカルネットワークの許可が無い・同じ Wi-Fi にいない、のどちらかが考えられる。
    public var mayBeLocalNetworkProblem: Bool {
        guard case let .network(code, message) = self else { return false }
        let localNetworkCodes: Set<Int> = [
            URLError.notConnectedToInternet.rawValue, URLError.cannotConnectToHost.rawValue,
            URLError.cannotFindHost.rawValue, URLError.timedOut.rawValue, URLError.networkConnectionLost.rawValue,
            URLError.dnsLookupFailed.rawValue,
        ]
        return localNetworkCodes.contains(code) || message.contains("-65570") || message.localizedCaseInsensitiveContains("local network")
    }

    public var userMessage: String {
        switch self {
        case .network(_, let message): return "受信側につながりませんでした（\(message)）"
        case .unauthorized: return "ペアリングコードが違います。Mac に表示されている 6 桁のコードを入れてください"
        case .http(let status, let message): return "受信側でエラーになりました（\(status)：\(message)）"
        case .unexpectedResponse(let message): return "受信側の応答が読めませんでした（\(message)）"
        case .notReceiver(let message): return "Memoria の受信側ではありません（\(message)）"
        case .fileChanged(let path): return "送っている間にファイルが変わりました（\(path)）。もう一度送ってください"
        case .incomplete(let missing): return "受信側でファイルが足りませんでした（\(missing.count) 件）。もう一度送ってください"
        case .invalid(let errors): return "受信側が session.json を受け付けませんでした（\(errors.joined(separator: "、"))）"
        case .cancelled: return "送信を中止しました"
        }
    }
}

// MARK: - 応答の形

public struct PingInfo: Codable, Equatable, Sendable {
    public var service: String
    public var protocolVersion: Int
    public var receiverId: String
    public var name: String?

    public init(service: String, protocolVersion: Int, receiverId: String, name: String?) {
        self.service = service
        self.protocolVersion = protocolVersion
        self.receiverId = receiverId
        self.name = name
    }
}

public enum BeginResult: Equatable, Sendable {
    case alreadyComplete(manifestHash: String)
    case uploading(uploadId: String, missing: [String])
}

public enum CommitResult: Equatable, Sendable {
    case complete(manifestHash: String, path: String?)
}

public struct TransferProgress: Equatable, Sendable {
    public enum Phase: String, Sendable {
        case connecting, uploading, committing, done
    }

    public var phase: Phase
    public var totalFiles: Int
    public var sentFiles: Int
    public var totalBytes: Int64
    public var sentBytes: Int64

    public init(phase: Phase, totalFiles: Int, sentFiles: Int, totalBytes: Int64, sentBytes: Int64) {
        self.phase = phase
        self.totalFiles = totalFiles
        self.sentFiles = sentFiles
        self.totalBytes = totalBytes
        self.sentBytes = sentBytes
    }

    public var fraction: Double {
        guard totalBytes > 0 else { return phase == .done ? 1 : 0 }
        return Double(sentBytes) / Double(totalBytes)
    }
}

public enum TransferOutcome: Equatable, Sendable {
    /// 受信側で完了した（`alreadyComplete` は true）。
    case complete(manifestHash: String, receiverId: String, alreadyComplete: Bool, path: String?)
    case failed(TransferError)
}

// MARK: - クライアント

/// docs/transfer-protocol.md の手順で 1 つのセッションを送る。設定した受信側の URL にだけ送る。
public struct TransferClient: Sendable {
    public static let protocolVersion = 1
    public static let serviceName = "memoria-capture-receiver"

    public let apiBase: URL
    public let token: String
    public let transport: any HTTPTransport
    public let sleeper: any Sleeper
    public let retry: RetryPolicy

    /// - Parameter receiverURL: `http://<host>:<port>`（`/api/v1` は付けても付けなくてもよい）。
    public init(receiverURL: URL, token: String, transport: any HTTPTransport = URLSessionTransport(), sleeper: any Sleeper = TaskSleeper(), retry: RetryPolicy = RetryPolicy()) {
        apiBase = Self.apiBase(for: receiverURL)
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transport = transport
        self.sleeper = sleeper
        self.retry = retry
    }

    public static func apiBase(for receiverURL: URL) -> URL {
        var text = receiverURL.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        if !text.hasSuffix("/api/v1") { text += "/api/v1" }
        return URL(string: text) ?? receiverURL
    }

    /// 手で入れた文字から URL を作る（`192.168.0.2:8765` のように http:// が無くてもよい）。
    public static func receiverURL(fromUserInput input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "http://" + text
        }
        guard let url = URL(string: text), let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    private func url(_ path: String) -> URL {
        URL(string: apiBase.absoluteString + path)!
    }

    // MARK: 1 回ずつの要求

    public func ping() async throws -> PingInfo {
        let response = try await perform(HTTPRequest(method: "GET", url: url("/ping")))
        try checkCommon(response)
        guard response.status == 200 else { throw httpError(response) }
        guard let info = try? JSONDecoder().decode(PingInfo.self, from: response.body) else {
            throw TransferError.unexpectedResponse("ping")
        }
        guard info.service == Self.serviceName else { throw TransferError.notReceiver("service = \(info.service)") }
        guard info.protocolVersion == Self.protocolVersion else {
            throw TransferError.notReceiver("protocolVersion = \(info.protocolVersion)")
        }
        return info
    }

    public func begin(sessionId: String, manifest: TransferManifest) async throws -> BeginResult {
        struct Body: Encodable { let files: [ManifestEntry] }
        struct Reply: Decodable { let status: String; let manifestHash: String?; let uploadId: String?; let missing: [String]? }
        let body = try JSONEncoder().encode(Body(files: manifest.entries))
        let response = try await perform(HTTPRequest(
            method: "POST", url: url("/sessions/\(sessionId)/uploads"),
            headers: ["Content-Type": "application/json"], body: body
        ))
        try checkCommon(response)
        guard response.status == 200 || response.status == 201 else { throw httpError(response) }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: response.body) else {
            throw TransferError.unexpectedResponse("uploads")
        }
        switch reply.status {
        case "alreadyComplete":
            return .alreadyComplete(manifestHash: reply.manifestHash ?? manifest.manifestHash)
        case "uploading":
            guard let uploadId = reply.uploadId else { throw TransferError.unexpectedResponse("uploadId がありません") }
            return .uploading(uploadId: uploadId, missing: reply.missing ?? manifest.entries.map(\.path))
        default:
            throw TransferError.unexpectedResponse("status = \(reply.status)")
        }
    }

    public func putFile(sessionId: String, uploadId: String, entry: ManifestEntry, data: Data) async throws {
        try await putFile(sessionId: sessionId, uploadId: uploadId, entry: entry, body: data, fileURL: nil)
    }

    /// ファイルから送る（中身はメモリに読み込まない）。
    public func putFile(sessionId: String, uploadId: String, entry: ManifestEntry, fileURL: URL) async throws {
        try await putFile(sessionId: sessionId, uploadId: uploadId, entry: entry, body: nil, fileURL: fileURL)
    }

    private func putFile(sessionId: String, uploadId: String, entry: ManifestEntry, body: Data?, fileURL: URL?) async throws {
        let response = try await perform(HTTPRequest(
            method: "PUT", url: url("/sessions/\(sessionId)/uploads/\(uploadId)/files/\(entry.path)"),
            headers: ["Content-Type": "application/octet-stream", "X-Content-SHA256": entry.sha256], body: body, bodyFileURL: fileURL
        ))
        try checkCommon(response)
        guard response.status == 200 || response.status == 201 else { throw httpError(response) }
        struct Reply: Decodable { let status: String }
        let status = (try? JSONDecoder().decode(Reply.self, from: response.body))?.status
        guard status == "stored" || status == "alreadyStored" else {
            throw TransferError.unexpectedResponse("PUT \(entry.path): \(status ?? "?")")
        }
    }

    public func commit(sessionId: String, uploadId: String) async throws -> CommitResult {
        struct Reply: Decodable { let status: String; let manifestHash: String?; let path: String?; let missing: [String]?; let errors: [String]? }
        let response = try await perform(HTTPRequest(
            method: "POST", url: url("/sessions/\(sessionId)/uploads/\(uploadId)/commit"),
            headers: ["Content-Type": "application/json"], body: Data("{}".utf8)
        ))
        try checkCommon(response)
        let reply = try? JSONDecoder().decode(Reply.self, from: response.body)
        switch response.status {
        case 200:
            guard let reply, reply.status == "complete" || reply.status == "alreadyComplete", let hash = reply.manifestHash else {
                throw TransferError.unexpectedResponse("commit")
            }
            return .complete(manifestHash: hash, path: reply.path)
        case 409:
            throw TransferError.incomplete(reply?.missing ?? [])
        case 422:
            throw TransferError.invalid(reply?.errors ?? [])
        default:
            throw httpError(response)
        }
    }

    // MARK: 全体

    /// セッションを送る。途中で止まっても、もう一度呼べば受信側が足りないファイルだけを返すので続きから送れる。
    /// - Parameters:
    ///   - onState: transfer.json に保存する状態（送り始め・完了・失敗）。
    ///   - onProgress: 進み具合。
    public func upload(
        _ snapshot: TransferSnapshot,
        now: @Sendable () -> Date = { Date() },
        onState: @Sendable (TransferState) -> Void = { _ in },
        onProgress: @Sendable (TransferProgress) -> Void = { _ in }
    ) async -> TransferOutcome {
        let manifest = snapshot.manifest
        let sessionId = snapshot.sessionId
        var progress = TransferProgress(phase: .connecting, totalFiles: manifest.entries.count, sentFiles: 0, totalBytes: manifest.totalBytes, sentBytes: 0)
        onProgress(progress)
        do {
            let info = try await ping()
            onState(.inProgress(uploadId: nil, receiverId: info.receiverId, manifestHash: manifest.manifestHash, startedAt: now()))
            switch try await begin(sessionId: sessionId, manifest: manifest) {
            case .alreadyComplete(let hash):
                guard hash == manifest.manifestHash else {
                    throw TransferError.unexpectedResponse("manifestHash が違います")
                }
                progress.phase = .done
                progress.sentFiles = progress.totalFiles
                progress.sentBytes = progress.totalBytes
                onProgress(progress)
                onState(.complete(manifestHash: hash, receiverId: info.receiverId, at: now(), receiverPath: nil))
                return .complete(manifestHash: hash, receiverId: info.receiverId, alreadyComplete: true, path: nil)

            case let .uploading(uploadId, missing):
                onState(.inProgress(uploadId: uploadId, receiverId: info.receiverId, manifestHash: manifest.manifestHash, startedAt: now()))
                let missingSet = Set(missing)
                // 届いているファイルは送ったものとして数える。
                for entry in manifest.entries where !missingSet.contains(entry.path) {
                    progress.sentFiles += 1
                    progress.sentBytes += entry.size
                }
                progress.phase = .uploading
                onProgress(progress)
                for entry in manifest.entries where missingSet.contains(entry.path) {
                    try Task.checkCancellation()
                    // session.json は控え（メモリ）から、写真・マスクはファイルから少しずつ送る。
                    if entry.path == "session.json" {
                        try await putFile(sessionId: sessionId, uploadId: uploadId, entry: entry, data: snapshot.sessionJSON)
                    } else {
                        let file = try snapshot.verifiedFileURL(for: entry.path)
                        try await putFile(sessionId: sessionId, uploadId: uploadId, entry: entry, fileURL: file)
                    }
                    progress.sentFiles += 1
                    progress.sentBytes += entry.size
                    onProgress(progress)
                }
                progress.phase = .committing
                onProgress(progress)
                let result = try await commit(sessionId: sessionId, uploadId: uploadId)
                guard case let .complete(hash, path) = result, hash == manifest.manifestHash else {
                    throw TransferError.unexpectedResponse("manifestHash が違います")
                }
                progress.phase = .done
                onProgress(progress)
                onState(.complete(manifestHash: hash, receiverId: info.receiverId, at: now(), receiverPath: path))
                return .complete(manifestHash: hash, receiverId: info.receiverId, alreadyComplete: false, path: path)
            }
        } catch {
            let transferError = Self.classify(error)
            onState(.failed(message: transferError.userMessage, at: now()))
            return .failed(transferError)
        }
    }

    // MARK: 送り直し

    /// 1 回の要求を、つながらない・5xx・408・429 のときだけ待ってから送り直す。
    private func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
        var request = request
        request.headers["X-Memoria-Token"] = token
        var lastError: Error?
        var lastResponse: HTTPResponse?
        let attempts = max(1, retry.maxAttempts)
        for attempt in 0..<attempts {
            if attempt > 0 {
                try await sleeper.sleep(seconds: retry.baseDelay * pow(2, Double(attempt - 1)))
            }
            try Task.checkCancellation()
            do {
                let response = try await transport.send(request)
                if response.status >= 500 || response.status == 408 || response.status == 429 {
                    lastResponse = response
                    lastError = nil
                    continue
                }
                return response
            } catch let error as TransferError {
                throw error
            } catch {
                if error is CancellationError { throw TransferError.cancelled }
                if let urlError = error as? URLError, urlError.code == .cancelled { throw TransferError.cancelled }
                lastError = error
                lastResponse = nil
            }
        }
        if let lastResponse { return lastResponse }
        throw Self.classify(lastError ?? TransferError.unexpectedResponse("応答がありません"))
    }

    private func checkCommon(_ response: HTTPResponse) throws {
        if response.status == 401 { throw TransferError.unauthorized }
    }

    private func httpError(_ response: HTTPResponse) -> TransferError {
        struct Reply: Decodable { let status: String?; let error: String?; let message: String? }
        let reply = try? JSONDecoder().decode(Reply.self, from: response.body)
        let message = reply?.error ?? reply?.message ?? reply?.status ?? String(data: response.body.prefix(200), encoding: .utf8) ?? ""
        return .http(status: response.status, message: message)
    }

    public static func classify(_ error: Error) -> TransferError {
        if let transferError = error as? TransferError { return transferError }
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return .cancelled }
            var message = urlError.localizedDescription
            let nsError = urlError as NSError
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                message += " [\(underlying.domain) \(underlying.code)]"
            }
            if let streamCode = nsError.userInfo["_kCFStreamErrorCodeKey"] {
                message += " [\(streamCode)]"
            }
            return .network(code: urlError.code.rawValue, message: message)
        }
        let nsError = error as NSError
        return .network(code: nsError.code, message: nsError.localizedDescription)
    }
}

/// セッションを保存場所から送る（転送中は変更できなくする）。
public struct SessionUploader: Sendable {
    public let store: SessionStore
    public let client: TransferClient

    public init(store: SessionStore, client: TransferClient) {
        self.store = store
        self.client = client
    }

    /// 送る。結果は transfer.json にも保存する。すでに送っている途中なら `.failed(.http(409))` 相当を返さず何もしない。
    public func send(sessionId: String, onProgress: @Sendable (TransferProgress) -> Void = { _ in }) async -> TransferOutcome {
        guard store.tryMarkBusy(sessionId) else {
            return .failed(.unexpectedResponse("このセッションはすでに送信中です"))
        }
        defer { store.setBusy(sessionId, false) }
        let snapshot: TransferSnapshot
        do {
            snapshot = try store.makeTransferSnapshot(sessionId)
        } catch {
            let message = "送るファイルを準備できませんでした（\(error.localizedDescription)）"
            try? store.saveTransferState(sessionId, .failed(message: message, at: Date()))
            return .failed(.unexpectedResponse(message))
        }
        let store = self.store
        return await client.upload(snapshot, onState: { state in
            try? store.saveTransferState(sessionId, state)
        }, onProgress: onProgress)
    }
}
