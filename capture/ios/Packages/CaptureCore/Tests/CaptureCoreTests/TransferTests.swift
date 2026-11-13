@testable import CaptureCore
import simd
import XCTest

final class ManifestTests: XCTestCase {
    func testManifestHashMatchesProtocolDefinition() {
        // 手で計算した値：printf 'masks/B.png\t7\tcc\nphotos/A.jpg\t3\taa\nsession.json\t5\tbb\n' | shasum -a 256
        let entries = [
            ManifestEntry(path: "session.json", size: 5, sha256: "bb"),
            ManifestEntry(path: "photos/A.jpg", size: 3, sha256: "aa"),
            ManifestEntry(path: "masks/B.png", size: 7, sha256: "cc"),
        ]
        let manifest = TransferManifest(entries: entries)
        XCTAssertEqual(manifest.manifestHash, "d9a484c4feac9380a66e74bd71f320d4a75a388bd321c35ed74fa5cb71720537")
        XCTAssertEqual(manifest.entries.map(\.path), ["masks/B.png", "photos/A.jpg", "session.json"])
        XCTAssertEqual(manifest.totalBytes, 15)
    }

    func testSHA256() throws {
        XCTAssertEqual(Hashing.sha256Hex(Data("hello".utf8)), "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        let dir = Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("h.txt")
        try Data("hello".utf8).write(to: url)
        let r = try Hashing.sha256Hex(fileAt: url, chunkSize: 2)
        XCTAssertEqual(r.hash, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        XCTAssertEqual(r.size, 5)
    }

    func testDisplayStatus() {
        let complete = TransferState.complete(manifestHash: "H1", receiverId: "R", at: Date(), receiverPath: nil)
        XCTAssertEqual(TransferDisplayStatus.make(state: complete, currentManifestHash: "H1"), .sent)
        XCTAssertEqual(TransferDisplayStatus.make(state: complete, currentManifestHash: "H2"), .modifiedSinceSent)
        XCTAssertEqual(TransferDisplayStatus.make(state: .notSent, currentManifestHash: "H1"), .notSent)
        XCTAssertEqual(TransferDisplayStatus.make(state: .inProgress(uploadId: "u", receiverId: "R", manifestHash: "H1", startedAt: Date()), currentManifestHash: "H1"), .inProgress)
    }

    func testTransferStateCoding() throws {
        let states: [TransferState] = [
            .notSent,
            .inProgress(uploadId: "u", receiverId: "R", manifestHash: "H", startedAt: Date(timeIntervalSince1970: 1_800_000_000)),
            .complete(manifestHash: "H", receiverId: "R", at: Date(timeIntervalSince1970: 1_800_000_000), receiverPath: "/p"),
            .failed(message: "x", at: Date(timeIntervalSince1970: 1_800_000_000)),
        ]
        for state in states {
            let data = try SessionJSON.makeEncoder().encode(state)
            XCTAssertEqual(try SessionJSON.makeDecoder().decode(TransferState.self, from: data), state)
        }
    }

    func testReceiverURLParsing() {
        XCTAssertEqual(TransferClient.receiverURL(fromUserInput: " 192.168.0.5:8765 ")?.absoluteString, "http://192.168.0.5:8765")
        XCTAssertNil(TransferClient.receiverURL(fromUserInput: ""))
        XCTAssertEqual(TransferClient.apiBase(for: URL(string: "http://mac.local:8765/")!).absoluteString, "http://mac.local:8765/api/v1")
        XCTAssertEqual(TransferClient.apiBase(for: URL(string: "http://mac.local:8765/api/v1")!).absoluteString, "http://mac.local:8765/api/v1")
    }
}

// MARK: - 偽の受信側

/// docs/transfer-protocol.md の受信側を簡単にまねる。
final class FakeReceiver: HTTPTransport, @unchecked Sendable {
    let lock = NSLock()
    let token = "123456"
    var completed: [String: String] = [:]              // sessionId → manifestHash
    var stored: [String: [String: Data]] = [:]          // uploadId → path → data
    var manifests: [String: [ManifestEntry]] = [:]      // uploadId → manifest
    var requests: [String] = []
    /// 要求の「METHOD path の先頭」ごとに、残りの失敗回数。
    var failures: [String: Int] = [:]
    var throwNetworkError = false
    var commitStatusOverride: Int?
    var alwaysFailPUT = false
    /// PUT した写真・マスクの path と、そのうちファイルから送ったもの（メモリの Data ではなく）。
    var fileBodyPaths: [String] = []
    var streamedPaths: [String] = []

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try lock.withLock { try handle(request) }
    }

    private func handle(_ request: HTTPRequest) throws -> HTTPResponse {
        let path = request.url.path.replacingOccurrences(of: "/api/v1", with: "")
        let key = "\(request.method) \(path)"
        requests.append(key)
        if throwNetworkError { throw URLError(.cannotConnectToHost) }
        for (prefix, count) in failures where count > 0 && key.hasPrefix(prefix) {
            failures[prefix] = count - 1
            return HTTPResponse(status: 500, body: Data("{\"error\":\"boom\"}".utf8))
        }
        guard request.headers["X-Memoria-Token"] == token else { return json(401, ["error": "unauthorized"]) }
        let parts = path.split(separator: "/").map(String.init)
        if path == "/ping" {
            return json(200, ["service": "memoria-capture-receiver", "protocolVersion": 1, "receiverId": "RECV-1", "name": "Test Mac"])
        }
        guard parts.count >= 3, parts[0] == "sessions" else { return json(404, ["status": "notFound"]) }
        let sessionId = parts[1]
        if request.method == "POST", parts.count == 3, parts[2] == "uploads" {
            struct Body: Decodable { let files: [ManifestEntry] }
            let body = try JSONDecoder().decode(Body.self, from: request.body ?? Data())
            let hash = TransferManifest.computeHash(body.files)
            if completed[sessionId] == hash { return json(200, ["status": "alreadyComplete", "manifestHash": hash]) }
            manifests[hash] = body.files
            let have = stored[hash] ?? [:]
            let missing = body.files.filter { have[$0.path] == nil }.map(\.path).sorted()
            return json(200, ["status": "uploading", "uploadId": hash, "missing": missing])
        }
        if request.method == "PUT", parts.count >= 6, parts[2] == "uploads", parts[4] == "files" {
            if alwaysFailPUT { return json(503, ["error": "busy"]) }
            let uploadId = parts[3]
            let filePath = parts[5...].joined(separator: "/")
            guard let entry = manifests[uploadId]?.first(where: { $0.path == filePath }) else { return json(409, ["error": "not in manifest"]) }
            let data = request.bodyFileURL.flatMap { try? Data(contentsOf: $0) } ?? request.body ?? Data()
            if filePath != "session.json" { fileBodyPaths.append(filePath) }
            if request.bodyFileURL != nil { streamedPaths.append(filePath) }
            guard Int64(data.count) == entry.size, Hashing.sha256Hex(data) == entry.sha256, request.headers["X-Content-SHA256"] == entry.sha256 else {
                return json(422, ["error": "mismatch"])
            }
            if stored[uploadId]?[filePath] != nil { return json(200, ["status": "alreadyStored"]) }
            stored[uploadId, default: [:]][filePath] = data
            return json(200, ["status": "stored"])
        }
        if request.method == "POST", parts.count == 5, parts[4] == "commit" {
            let uploadId = parts[3]
            if let status = commitStatusOverride { return json(status, ["status": "incomplete", "missing": ["photos/x.jpg"]]) }
            let manifest = manifests[uploadId] ?? []
            let missing = manifest.filter { stored[uploadId]?[$0.path] == nil }.map(\.path)
            if !missing.isEmpty { return json(409, ["status": "incomplete", "missing": missing]) }
            completed[sessionId] = uploadId
            return json(200, ["status": "complete", "manifestHash": uploadId, "path": "/captures/sessions/\(sessionId)"])
        }
        return json(404, ["status": "notFound"])
    }

    private func json(_ status: Int, _ object: [String: Any]) -> HTTPResponse {
        HTTPResponse(status: status, body: try! JSONSerialization.data(withJSONObject: object))
    }

    func count(_ prefix: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.hasPrefix(prefix) }.count
    }
}

final class RecordingSleeper: Sleeper, @unchecked Sendable {
    let lock = NSLock()
    var delays: [Double] = []
    func sleep(seconds: Double) async throws {
        lock.withLock { delays.append(seconds) }
    }
}

final class TransferClientTests: XCTestCase {
    var root: URL!
    var store: SessionStore!
    var receiver: FakeReceiver!
    var sleeper: RecordingSleeper!
    var sessionId: String!

    override func setUp() async throws {
        root = Fixtures.tempDirectory()
        store = SessionStore(rootDirectory: root)
        receiver = FakeReceiver()
        sleeper = RecordingSleeper()
        let s = try store.createSession(title: "送信", device: Fixtures.device, plan: DirectionPlanPreset.ring8.plan)
        sessionId = s.sessionId
        try store.updateSession(sessionId) { s in
            s.object = ObjectSize(heightM: 0.15, radiusM: 0.08)
            s.referenceFrames.append(ReferenceFrame(id: "ref-1", createdAt: Date(), basePointWorld: .zero))
        }
        for i in 0..<3 {
            let photoId = SessionStore.newId()
            let frame = Fixtures.frame(cameraToWorld: Fixtures.lookAt(from: SIMD3(0.4 * sin(Double(i)), 0.2, 0.4 * cos(Double(i))), to: .zero))
            try store.addPhoto(sessionId: sessionId, photoId: photoId, jpegData: Data(repeating: UInt8(i), count: 1000 + i)) { s, seq in
                PhotoRecorder.makePhoto(in: &s, photoId: photoId, sequence: seq, frame: frame, context: Fixtures.context(ref: "ref-1"))
            }
            if i == 0 {
                try store.saveMask(sessionId: sessionId, photoId: photoId, pngData: Data(repeating: 7, count: 50), mask: MaskInfo(status: .candidate, width: 1, height: 1, method: MaskInfo.visionMethod, instanceCount: 1, selectedInstances: [1], selection: .auto))
            }
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func uploader(token: String = "123456") -> SessionUploader {
        let client = TransferClient(receiverURL: URL(string: "http://127.0.0.1:8765")!, token: token, transport: receiver, sleeper: sleeper)
        return SessionUploader(store: store, client: client)
    }

    func testHappyPathThenAlreadyComplete() async throws {
        let snapshot = try store.makeTransferSnapshot(sessionId)
        XCTAssertEqual(snapshot.manifest.entries.count, 5)  // session.json + 写真 3 + マスク 1
        let outcome = await uploader().send(sessionId: sessionId)
        guard case let .complete(hash, receiverId, already, path) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(hash, snapshot.manifest.manifestHash)
        XCTAssertEqual(receiverId, "RECV-1")
        XCTAssertFalse(already)
        XCTAssertNotNil(path)
        XCTAssertEqual(receiver.count("PUT"), 5)
        XCTAssertEqual(store.transferDisplayStatus(sessionId), .sent)
        XCTAssertFalse(store.isBusy(sessionId))
        // 写真・マスクはファイルから送る（メモリの Data にしない）。session.json だけが控えの Data。
        XCTAssertEqual(receiver.fileBodyPaths.count, 4)
        XCTAssertEqual(receiver.streamedPaths.sorted(), receiver.fileBodyPaths.sorted())

        let again = await uploader().send(sessionId: sessionId)
        guard case let .complete(_, _, already2, _) = again else { return XCTFail("\(again)") }
        XCTAssertTrue(already2)
        XCTAssertEqual(receiver.count("PUT"), 5)  // 送り直していない
        XCTAssertEqual(store.transferDisplayStatus(sessionId), .sent)
    }

    func testResumeSendsOnlyMissingFiles() async throws {
        // 1 回目：commit の前に止まった（commit が 409 → 完了にしない）。
        receiver.commitStatusOverride = 409
        let first = await uploader().send(sessionId: sessionId)
        guard case .failed(.incomplete) = first else { return XCTFail("\(first)") }
        XCTAssertNotEqual(store.transferDisplayStatus(sessionId), .sent)
        XCTAssertEqual(receiver.count("PUT"), 5)
        // 2 回目：全部届いているので PUT はしない。
        receiver.commitStatusOverride = nil
        let second = await uploader().send(sessionId: sessionId)
        guard case .complete = second else { return XCTFail("\(second)") }
        XCTAssertEqual(receiver.count("PUT"), 5)
        XCTAssertEqual(store.transferDisplayStatus(sessionId), .sent)
    }

    func testResumeAfterPartialUpload() async throws {
        // 先に 2 つだけ届いている状態を作る。
        let snapshot = try store.makeTransferSnapshot(sessionId)
        let client = TransferClient(receiverURL: URL(string: "http://127.0.0.1:8765")!, token: "123456", transport: receiver, sleeper: sleeper)
        guard case let .uploading(uploadId, missing) = try await client.begin(sessionId: sessionId, manifest: snapshot.manifest) else { return XCTFail() }
        XCTAssertEqual(missing.count, 5)
        for entry in snapshot.manifest.entries.prefix(2) {
            try await client.putFile(sessionId: sessionId, uploadId: uploadId, entry: entry, data: try snapshot.data(for: entry.path))
        }
        let outcome = await uploader().send(sessionId: sessionId)
        guard case .complete = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(receiver.count("PUT"), 5)  // 2 + 残りの 3
    }

    func testTransient500IsRetried() async throws {
        receiver.failures = ["PUT": 2, "POST /sessions": 1]
        let outcome = await uploader().send(sessionId: sessionId)
        guard case .complete = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(sleeper.delays.count, 3)
        XCTAssertEqual(sleeper.delays.first, 0.5)
        XCTAssertEqual(store.transferDisplayStatus(sessionId), .sent)
    }

    func testPersistentFailureIsFailedNotComplete() async throws {
        receiver.alwaysFailPUT = true
        let outcome = await uploader().send(sessionId: sessionId)
        guard case .failed(.http(status: 503, _)) = outcome else { return XCTFail("\(outcome)") }
        if case .failed = store.loadTransferState(sessionId) {} else { XCTFail("\(store.loadTransferState(sessionId))") }
        XCTAssertNotEqual(store.transferDisplayStatus(sessionId), .sent)
        XCTAssertEqual(receiver.count("POST /sessions/\(sessionId!)/uploads/"), 0)  // commit していない
        XCTAssertEqual(sleeper.delays, [0.5, 1.0])  // 1 つ目の PUT を 3 回試してやめた
    }

    func testNetworkErrorIsRetriedThenFails() async throws {
        receiver.throwNetworkError = true
        let outcome = await uploader().send(sessionId: sessionId)
        guard case let .failed(error) = outcome, case .network = error else { return XCTFail("\(outcome)") }
        XCTAssertTrue(error.mayBeLocalNetworkProblem)
        XCTAssertEqual(receiver.count("GET /ping"), 3)
    }

    func testWrongTokenIsUnauthorized() async throws {
        let outcome = await uploader(token: "000000").send(sessionId: sessionId)
        XCTAssertEqual(outcome, .failed(.unauthorized))
        XCTAssertEqual(receiver.count("GET /ping"), 1)  // 401 は送り直さない
    }

    func testSessionModifiedAfterSendIsNotSent() async throws {
        let outcome = await uploader().send(sessionId: sessionId)
        guard case .complete = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(store.transferDisplayStatus(sessionId), .sent)
        try store.updateSession(sessionId) { $0.title = "変えた" }
        XCTAssertEqual(store.transferDisplayStatus(sessionId), .modifiedSinceSent)
        // 送り直すと新しい版として完了。
        let again = await uploader().send(sessionId: sessionId)
        guard case let .complete(_, _, already, _) = again else { return XCTFail("\(again)") }
        XCTAssertFalse(already)
        XCTAssertEqual(store.transferDisplayStatus(sessionId), .sent)
    }

    func testFileChangedDuringTransferFails() async throws {
        let snapshot = try store.makeTransferSnapshot(sessionId)
        let photoPath = try XCTUnwrap(snapshot.manifest.entries.first { $0.path.hasPrefix("photos/") }?.path)
        try Data([0, 1, 2]).write(to: store.fileURL(sessionId, path: photoPath))
        let client = TransferClient(receiverURL: URL(string: "http://127.0.0.1:8765")!, token: "123456", transport: receiver, sleeper: sleeper)
        let outcome = await client.upload(snapshot)
        XCTAssertEqual(outcome, .failed(.fileChanged(photoPath)))
    }

    func testBusyWhileSending() async throws {
        XCTAssertTrue(store.tryMarkBusy(sessionId))
        let outcome = await uploader().send(sessionId: sessionId)
        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(receiver.count("GET"), 0)
        store.setBusy(sessionId, false)
    }
}
