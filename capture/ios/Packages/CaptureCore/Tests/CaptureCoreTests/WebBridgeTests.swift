@testable import CaptureCore
import simd
import XCTest

/// memoria の Web との橋渡し（取り決め v1。docs/web-bridge.md）。
final class WebBridgeTests: XCTestCase {
    // MARK: 接続先

    func testWebOriginParsing() throws {
        let https = try XCTUnwrap(WebOrigin(string: "https://memoria-try.tka-2610.workers.dev"))
        XCTAssertEqual(https.scheme, "https")
        XCTAssertEqual(https.host, "memoria-try.tka-2610.workers.dev")
        XCTAssertNil(https.port)
        XCTAssertEqual(https.effectivePort, 443)
        XCTAssertEqual(https.serialized, "https://memoria-try.tka-2610.workers.dev")
        XCTAssertEqual(https.rootURL.absoluteString, "https://memoria-try.tka-2610.workers.dev/")

        let local = try XCTUnwrap(WebOrigin(string: " HTTP://My-Mac.local:8080/ "))
        XCTAssertEqual(local.scheme, "http")
        XCTAssertEqual(local.host, "my-mac.local")
        XCTAssertEqual(local.port, 8080)
        XCTAssertEqual(local.serialized, "http://my-mac.local:8080")

        // 既定のポートを書いても同じ。
        XCTAssertEqual(WebOrigin(string: "https://example.com:443"), WebOrigin(string: "https://example.com"))
        XCTAssertNil(WebOrigin(string: "https://example.com:443")?.port)

        // 設定の間違い（xcconfig の値が展開されていない・パスやクエリ付き・ほかの scheme）は受け付けない。
        for bad in ["", "://", "$(MEMORIA_WEB_SCHEME)://$(MEMORIA_WEB_HOST)", "https://", "example.com", "ftp://example.com",
                    "https://example.com/app", "https://example.com/?house=1", "https://user@example.com", "file:///tmp",
                    "https://example.com#top"] {
            XCTAssertNil(WebOrigin(string: bad), bad)
        }
    }

    func testWebOriginMatching() throws {
        let origin = try XCTUnwrap(WebOrigin(string: "https://memoria.example"))
        XCTAssertTrue(origin.contains(URL(string: "https://memoria.example/add?x=1")!))
        XCTAssertTrue(origin.contains(URL(string: "https://MEMORIA.example:443/")!))
        XCTAssertFalse(origin.contains(URL(string: "http://memoria.example/")!))
        XCTAssertFalse(origin.contains(URL(string: "https://memoria.example:8443/")!))
        XCTAssertFalse(origin.contains(URL(string: "https://evil.memoria.example/")!))
        XCTAssertFalse(origin.contains(URL(string: "https://memoria.example.evil.com/")!))
        XCTAssertFalse(origin.contains(URL(string: "about:blank")!))
        // WKSecurityOrigin は既定のポートを 0 で表す。
        XCTAssertTrue(origin.matches(scheme: "https", host: "memoria.example", port: 0))
        XCTAssertTrue(origin.matches(scheme: "https", host: "memoria.example", port: 443))
        XCTAssertFalse(origin.matches(scheme: "http", host: "memoria.example", port: 0))
        XCTAssertFalse(origin.matches(scheme: "https", host: "other.example", port: 0))

        let local = try XCTUnwrap(WebOrigin(string: "http://mac.local:8080"))
        XCTAssertTrue(local.matches(scheme: "http", host: "mac.local", port: 8080))
        XCTAssertFalse(local.matches(scheme: "http", host: "mac.local", port: 0))
        XCTAssertTrue(local.contains(URL(string: "http://mac.local:8080/api/museum")!))
        XCTAssertFalse(local.contains(URL(string: "http://mac.local/")!))
    }

    // MARK: 家のリンク

    func testHouseLink() throws {
        let id = "0123456789abcdef0123456789abcdef"
        XCTAssertEqual(HouseLink.houseId(fromUserInput: id), id)
        XCTAssertEqual(HouseLink.houseId(fromUserInput: "  \(id.uppercased())\n"), id)
        XCTAssertEqual(HouseLink.houseId(fromUserInput: "https://memoria-try.tka-2610.workers.dev/?house=\(id)"), id)
        XCTAssertEqual(HouseLink.houseId(fromUserInput: "http://mac.local:8080/house?x=1&house=\(id)"), id)
        XCTAssertNil(HouseLink.houseId(fromUserInput: ""))
        XCTAssertNil(HouseLink.houseId(fromUserInput: "https://memoria.example/?house=new"))
        XCTAssertNil(HouseLink.houseId(fromUserInput: "https://memoria.example/house"))
        XCTAssertNil(HouseLink.houseId(fromUserInput: String(id.dropLast())))
        XCTAssertNil(HouseLink.houseId(fromUserInput: id + "0"))
        XCTAssertNil(HouseLink.houseId(fromUserInput: "0123456789abcdef0123456789abcdeg"))

        let origin = try XCTUnwrap(WebOrigin(string: "http://mac.local:8080"))
        XCTAssertEqual(HouseLink.switchURL(origin: origin, houseId: id).absoluteString, "http://mac.local:8080/?house=\(id)")
    }

    // MARK: 知らせ

    private func parse(_ body: Any?) -> Result<BridgeRequest, BridgeFailure> { BridgeRequest.parse(body) }

    func testParseStartCapture() {
        XCTAssertEqual(parse(["type": "startCapture", "kind": "object"]), .success(.startCapture(BridgeCaptureRequest(kind: .object))))
        XCTAssertEqual(parse(["type": "startCapture", "kind": "flat"]), .success(.startCapture(BridgeCaptureRequest(kind: .flat))))
        // 「わからない」は省く・null・空。
        XCTAssertEqual(parse(["type": "startCapture", "kind": "flat", "sheetId": NSNull()]), .success(.startCapture(BridgeCaptureRequest(kind: .flat))))
        XCTAssertEqual(parse(["type": "startCapture", "kind": "flat", "sheetId": ""]), .success(.startCapture(BridgeCaptureRequest(kind: .flat))))

        // 紙は SheetPreset の一覧から。
        guard case let .success(.startCapture(flat)) = parse(["type": "startCapture", "kind": "flat", "sheetId": "yatsugiri", "heightCm": 12]) else {
            return XCTFail("flat")
        }
        XCTAssertEqual(flat.kind, .flat)
        XCTAssertEqual(flat.declaredSize?.sheet, DeclaredSheet(.yatsugiri))
        XCTAssertNil(flat.declaredSize?.heightM)  // 平面の高さは使わない
        XCTAssertEqual(parse(["type": "startCapture", "kind": "flat", "sheetId": "custom"]), .failure(.invalidSheet))
        XCTAssertEqual(parse(["type": "startCapture", "kind": "flat", "sheetId": "A4"]), .failure(.invalidSheet))
        XCTAssertEqual(parse(["type": "startCapture", "kind": "flat", "sheetId": 4]), .failure(.invalidSheet))

        // 高さは 0.5〜300 cm（0.1 mm に丸める）。
        guard case let .success(.startCapture(object)) = parse(["type": "startCapture", "kind": "object", "heightCm": 12.34567, "sheetId": "a4"]) else {
            return XCTFail("object")
        }
        XCTAssertEqual(object.declaredSize?.heightM ?? 0, 0.1235, accuracy: 1e-12)
        XCTAssertNil(object.declaredSize?.sheet)  // 立体の紙は使わない
        XCTAssertEqual(parse(["type": "startCapture", "kind": "object", "heightCm": NSNull()]), .success(.startCapture(BridgeCaptureRequest(kind: .object))))
        guard case let .success(.startCapture(edge)) = parse(["type": "startCapture", "kind": "object", "heightCm": 300]) else { return XCTFail("300") }
        XCTAssertEqual(edge.declaredSize?.heightM, 3.0)
        guard case let .success(.startCapture(low)) = parse(["type": "startCapture", "kind": "object", "heightCm": 0.5]) else { return XCTFail("0.5") }
        XCTAssertEqual(low.declaredSize?.heightM, 0.005)
        for bad in [0.4, 300.1, -1, Double.nan, Double.infinity, "12", true] as [Any] {
            XCTAssertEqual(parse(["type": "startCapture", "kind": "object", "heightCm": bad]), .failure(.invalidHeight), "\(bad)")
        }

        XCTAssertEqual(parse(["type": "startCapture"]), .failure(.invalidKind))
        XCTAssertEqual(parse(["type": "startCapture", "kind": "drawing"]), .failure(.invalidKind))
    }

    func testParseOtherMessages() {
        XCTAssertEqual(parse(["type": "pendingCapture"]), .success(.pendingCapture))
        XCTAssertEqual(parse(["type": "openSessions", "extra": 1]), .success(.openSessions))
        XCTAssertEqual(parse(nil), .failure(.invalidMessage))
        XCTAssertEqual(parse("startCapture"), .failure(.invalidMessage))
        XCTAssertEqual(parse(["kind": "flat"]), .failure(.invalidMessage))
        XCTAssertEqual(parse(["type": 1]), .failure(.invalidMessage))
        XCTAssertEqual(parse(["type": "deleteEverything"]), .failure(.unknownType("deleteEverything")))

        let sessionId = SessionStore.newId()
        XCTAssertEqual(parse(["type": "artworkCreated", "sessionId": sessionId, "artworkId": " 42 ", "title": "  ねこ  "]),
                       .success(.artworkCreated(BridgeArtworkCreated(sessionId: sessionId, artworkId: "42", title: "ねこ"))))
        // 数の id も受け付ける。題名は無くてもよい。
        XCTAssertEqual(parse(["type": "artworkCreated", "sessionId": sessionId, "artworkId": 7]),
                       .success(.artworkCreated(BridgeArtworkCreated(sessionId: sessionId, artworkId: "7", title: ""))))
        XCTAssertEqual(parse(["type": "artworkCreated", "sessionId": sessionId, "artworkId": ""]), .failure(.invalidArtwork))
        XCTAssertEqual(parse(["type": "artworkCreated", "sessionId": sessionId, "artworkId": 1.5]), .failure(.invalidArtwork))
        XCTAssertEqual(parse(["type": "artworkCreated", "sessionId": sessionId]), .failure(.invalidArtwork))
        XCTAssertEqual(parse(["type": "artworkCreated", "sessionId": sessionId, "artworkId": String(repeating: "a", count: 201)]), .failure(.invalidArtwork))
        XCTAssertEqual(parse(["type": "artworkCreated", "sessionId": "../x", "artworkId": "1"]), .failure(.unknownSession))
        XCTAssertEqual(parse(["type": "artworkCreated", "artworkId": "1"]), .failure(.unknownSession))
        guard case let .success(.artworkCreated(long)) = parse(["type": "artworkCreated", "sessionId": sessionId, "artworkId": "1",
                                                                "title": String(repeating: "あ", count: 300)]) else { return XCTFail("long") }
        XCTAssertEqual(long.title.count, BridgeRequest.maxTextLength)
    }

    func testParseFromJSONObjects() throws {
        // WKScriptMessage.body と同じ Foundation の型（NSDictionary・NSNumber・NSNull）でも読める。
        let json = #"{"type":"startCapture","kind":"object","heightCm":8}"#
        let body = try JSONSerialization.jsonObject(with: Data(json.utf8))
        guard case let .success(.startCapture(request)) = parse(body) else { return XCTFail("json") }
        XCTAssertEqual(request.declaredSize?.heightM, 0.08)
        let boolean = try JSONSerialization.jsonObject(with: Data(#"{"type":"startCapture","kind":"object","heightCm":true}"#.utf8))
        XCTAssertEqual(parse(boolean), .failure(.invalidHeight))
    }

    func testFailureMessagesAreJapanese() {
        XCTAssertEqual(BridgeFailure.invalidHeight.message, "高さは 0.5〜300 cm で入れてください")
        XCTAssertEqual(BridgeFailure.busy.message, "撮影の画面がすでに開いています")
        XCTAssertEqual(BridgeFailure.unknownType("x").message, "アプリが知らない知らせです（x）")
    }

    // MARK: 返事と window.MemoriaNative

    func testReplyShapes() throws {
        let result = BridgeCaptureResult(kind: .flat, sessionId: "S", photoCount: 2, imageBase64: "AAAA")
        let reply = result.replyObject
        XCTAssertEqual(Set(reply.keys), ["kind", "sessionId", "photoCount", "mime", "image"])
        XCTAssertEqual(reply["kind"] as? String, "flat")
        XCTAssertEqual(reply["mime"] as? String, "image/jpeg")
        XCTAssertEqual(reply["photoCount"] as? Int, 2)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(reply))
        XCTAssertEqual(BridgeReply.cancelled["cancelled"] as? Bool, true)
        XCTAssertEqual(BridgeReply.ok["ok"] as? Bool, true)
    }

    func testNativeInfoScript() throws {
        let info = NativeCaptureInfo.current
        XCTAssertTrue(info.capture)
        XCTAssertEqual(info.version, 1)
        XCTAssertEqual(info.sheets.map(\.id), SheetPreset.allCases.map(\.rawValue))
        XCTAssertEqual(info.sheets.first?.label, "八つ切（27.1 × 39.2 cm）")
        XCTAssertEqual(info.heightCm, NativeCaptureInfo.HeightRange(min: 0.5, max: 300))

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(info.json().utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["capture", "version", "sheets", "heightCm"])
        XCTAssertEqual(object["capture"] as? Bool, true)
        XCTAssertEqual((object["heightCm"] as? [String: Double])?["min"], 0.5)
        let sheets = try XCTUnwrap(object["sheets"] as? [[String: String]])
        XCTAssertEqual(sheets.count, SheetPreset.allCases.count)
        XCTAssertEqual(Set(sheets[0].keys), ["id", "label"])

        let script = info.userScriptSource()
        XCTAssertTrue(script.hasPrefix("window.MemoriaNative = Object.freeze({"))
        XCTAssertTrue(script.hasSuffix("});"))
    }

    // MARK: Web に渡す写真

    private func freePhoto(_ s: CaptureSession, seq: Int, rotation: Int = 90) -> Photo {
        let frame = Fixtures.frame(cameraToWorld: Fixtures.lookAt(from: SIMD3(0, 0.3, 0.3), to: .zero))
        let context = CaptureContext(trigger: .manual, referenceFrameId: nil, liveQuality: .unknown, deviceOrientation: "portrait",
                                     displayRotationDegClockwise: rotation, capturedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(seq)))
        return PhotoRecorder.makeFreePhoto(session: s, photoId: String(format: "00000000-0000-4000-8000-%012d", seq), sequence: seq,
                                           frame: frame, context: context)
    }

    func testRepresentativePhotoObject() {
        var s = CaptureSession(sessionId: SessionStore.newId(), title: "", createdAt: Date(), device: Fixtures.device,
                               directionPlan: DirectionPlanPreset.free.plan, workKind: .object, guidance: .free)
        XCTAssertNil(RepresentativePhoto.pick(session: s))
        // 並び順ではなく撮影順で最初の写真。
        s.photos = [freePhoto(s, seq: 3, rotation: 0), freePhoto(s, seq: 2, rotation: 90), freePhoto(s, seq: 5, rotation: 180)]
        let pick = RepresentativePhoto.pick(session: s)
        XCTAssertEqual(pick, RepresentativePhoto(photoId: s.photos[1].photoId, file: "photos/\(s.photos[1].photoId).jpg",
                                                 rotationDegClockwise: 90, isRectified: false))
    }

    func testRepresentativePhotoFlat() {
        var s = CaptureSession(sessionId: SessionStore.newId(), title: "", createdAt: Date(), device: Fixtures.device,
                               directionPlan: DirectionPlanPreset.flat1.plan, workKind: .flat)
        XCTAssertNil(RepresentativePhoto.pick(session: s))
        var first = freePhoto(s, seq: 1)
        first.flat = FlatPhotoInfo(rectified: FlatRectifiedImage(file: "rectified/\(first.photoId).jpg", width: 800, height: 600))
        var latest = freePhoto(s, seq: 2, rotation: 270)
        latest.flat = FlatPhotoInfo()
        s.photos = [first]
        // 補正した画像はすでにまっすぐなので回さない。
        XCTAssertEqual(RepresentativePhoto.pick(session: s),
                       RepresentativePhoto(photoId: first.photoId, file: "rectified/\(first.photoId).jpg", rotationDegClockwise: 0, isRectified: true))
        // 撮り直すと一番新しい写真。補正した画像が無ければ元の写真を回す。
        s.photos = [latest, first]
        XCTAssertEqual(RepresentativePhoto.pick(session: s),
                       RepresentativePhoto(photoId: latest.photoId, file: "photos/\(latest.photoId).jpg", rotationDegClockwise: 270, isRectified: false))
    }

    // MARK: local.json の memoria

    func testLocalStateDecodesOldFilesAndKeepsLink() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // memoria の無い前の local.json。
        let old = try decoder.decode(LocalSessionState.self, from: Data(#"{"fileHashes":{},"lastSequence":3}"#.utf8))
        XCTAssertEqual(old, LocalSessionState(lastSequence: 3))
        XCTAssertNil(old.memoria)
        // 形の合わない memoria は捨て、ほかは残す。
        let broken = try decoder.decode(LocalSessionState.self, from: Data(#"{"fileHashes":{},"lastSequence":4,"memoria":{"artworkId":1}}"#.utf8))
        XCTAssertEqual(broken.lastSequence, 4)
        XCTAssertNil(broken.memoria)
        // memoria が無ければキーを書かない（前の形のまま）。
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        XCTAssertEqual(String(decoding: try encoder.encode(old), as: UTF8.self), #"{"fileHashes":{},"lastSequence":3}"#)
    }

    func testUpdateLocalStateKeepsLinkOutOfTransfer() throws {
        let root = Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(rootDirectory: root)
        let s = try store.createSession(title: "", device: Fixtures.device, plan: DirectionPlanPreset.free.plan, workKind: .object, guidance: .free)
        let photoId = SessionStore.newId()
        let frame = Fixtures.frame(cameraToWorld: Fixtures.lookAt(from: SIMD3(0, 0.3, 0.3), to: .zero))
        try store.addPhoto(sessionId: s.sessionId, photoId: photoId, jpegData: Data(repeating: 0xAB, count: 40)) { session, seq in
            PhotoRecorder.makeFreePhoto(session: session, photoId: photoId, sequence: seq, frame: frame, context: Fixtures.context(ref: nil))
        }
        let sessionBefore = try store.sessionData(s.sessionId)
        let hashBefore = try store.makeTransferSnapshot(s.sessionId).manifest.manifestHash

        let link = MemoriaLink(artworkId: "42", origin: "https://memoria.example", linkedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let updated = try store.updateLocalState(s.sessionId) { $0.memoria = link }
        XCTAssertEqual(updated.memoria, link)
        XCTAssertEqual(updated.lastSequence, 1)  // 撮影順の控えはそのまま
        XCTAssertEqual(store.loadLocalState(s.sessionId).memoria, link)

        let raw = try String(contentsOf: store.sessionDirectory(s.sessionId).appendingPathComponent("local.json"), encoding: .utf8)
        XCTAssertTrue(raw.contains(#""linkedAt":"2027-01-15T08:00:00Z""#), raw)

        // session.json と送るもの（manifest）は変わらない。local.json は送らない。
        XCTAssertEqual(try store.sessionData(s.sessionId), sessionBefore)
        let snapshot = try store.makeTransferSnapshot(s.sessionId)
        XCTAssertEqual(snapshot.manifest.manifestHash, hashBefore)
        XCTAssertFalse(snapshot.manifest.entries.contains { $0.path.contains("local") })
        // ハッシュの控えを書き直しても、つながりは残る。
        XCTAssertEqual(store.loadLocalState(s.sessionId).memoria, link)

        XCTAssertThrowsError(try store.updateLocalState(SessionStore.newId()) { _ in }) { error in
            guard case SessionStoreError.notFound = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try store.updateLocalState("../etc") { _ in }) { error in
            guard case SessionStoreError.invalidId = error else { return XCTFail("\(error)") }
        }
    }

    func testDeclaredHeightFromNumber() {
        XCTAssertEqual(DeclaredSize.heightM(centimetres: 12), 0.12)
        XCTAssertEqual(DeclaredSize.heightM(centimetres: 12), DeclaredSize.heightM(fromCentimetres: "12"))
        XCTAssertNil(DeclaredSize.heightM(centimetres: 0.49))
        XCTAssertNil(DeclaredSize.heightM(centimetres: .nan))
        // 文字の入力の読み方は変わらない。
        XCTAssertEqual(DeclaredSize.heightM(fromCentimetres: "１２，５"), 0.125)
        XCTAssertNil(DeclaredSize.heightM(fromCentimetres: "abc"))
    }
}
