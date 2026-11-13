@testable import CaptureCore
import simd
import XCTest

final class SessionStoreTests: XCTestCase {
    var root: URL!
    var store: SessionStore!

    override func setUp() {
        root = Fixtures.tempDirectory()
        store = SessionStore(rootDirectory: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSession() throws -> CaptureSession {
        let s = try store.createSession(title: "ねこ", device: Fixtures.device, plan: DirectionPlanPreset.ring8.plan)
        return try store.updateSession(s.sessionId) { s in
            s.object = ObjectSize(heightM: 0.15, radiusM: 0.08)
            s.referenceFrames.append(ReferenceFrame(id: "ref-1", createdAt: Date(), basePointWorld: .zero))
        }
    }

    @discardableResult
    private func addPhoto(_ sessionId: String, bytes: Int = 100) throws -> Photo {
        let photoId = SessionStore.newId()
        let frame = Fixtures.frame(cameraToWorld: Fixtures.lookAt(from: SIMD3(0, 0.2, 0.4), to: .zero))
        return try store.addPhoto(sessionId: sessionId, photoId: photoId, jpegData: Data(repeating: 0xAB, count: bytes)) { s, seq in
            PhotoRecorder.makePhoto(in: &s, photoId: photoId, sequence: seq, frame: frame, context: Fixtures.context(ref: "ref-1"))
        }
    }

    func testCreateSaveLoadList() throws {
        let s = try makeSession()
        let dir = store.sessionDirectory(s.sessionId)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("session.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("photos").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("masks").path))
        let loaded = try store.loadSession(s.sessionId)
        XCTAssertEqual(loaded.title, "ねこ")
        XCTAssertEqual(loaded.object?.heightM, 0.15)
        XCTAssertEqual(store.listSessions().map(\.sessionId), [s.sessionId])
        XCTAssertTrue(SessionStore.isValidId(s.sessionId))
    }

    func testAddPhotoWritesJPEGAndRecord() throws {
        let s = try makeSession()
        let p = try addPhoto(s.sessionId)
        XCTAssertEqual(p.sequence, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.photoURL(s.sessionId, photoId: p.photoId).path))
        let loaded = try store.loadSession(s.sessionId)
        XCTAssertEqual(loaded.photos.map(\.photoId), [p.photoId])
        // 1 枚目で正面が決まった。
        XCTAssertEqual(loaded.referenceFrames[0].frontPhotoId, p.photoId)
    }

    func testSequenceIsNotReusedAfterDeletion() throws {
        let s = try makeSession()
        let p1 = try addPhoto(s.sessionId)
        let p2 = try addPhoto(s.sessionId)
        XCTAssertEqual(p2.sequence, 2)
        try store.deletePhoto(sessionId: s.sessionId, photoId: p2.photoId)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.photoURL(s.sessionId, photoId: p2.photoId).path))
        let p3 = try addPhoto(s.sessionId)
        XCTAssertEqual(p3.sequence, 3)
        try store.deletePhoto(sessionId: s.sessionId, photoId: p1.photoId)
        try store.deletePhoto(sessionId: s.sessionId, photoId: p3.photoId)
        XCTAssertEqual(try addPhoto(s.sessionId).sequence, 4)
    }

    func testFailedSessionWriteLeavesNoPhoto() throws {
        let s = try makeSession()
        let sessionFile = store.sessionFileURL(s.sessionId).lastPathComponent
        store.writeData = { data, url in
            if url.lastPathComponent == sessionFile { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        }
        let photoId = SessionStore.newId()
        XCTAssertThrowsError(try store.addPhoto(sessionId: s.sessionId, photoId: photoId, jpegData: Data([1, 2, 3])) { s, seq in
            PhotoRecorder.makePhoto(in: &s, photoId: photoId, sequence: seq, frame: Fixtures.frame(cameraToWorld: matrix_identity_double4x4), context: Fixtures.context(ref: nil))
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.photoURL(s.sessionId, photoId: photoId).path))
        store.writeData = { data, url in try data.write(to: url, options: .atomic) }
        XCTAssertEqual(try store.loadSession(s.sessionId).photos.count, 0)
    }

    func testFailedJPEGWriteLeavesNoPhoto() throws {
        let s = try makeSession()
        store.writeData = { data, url in
            if url.pathExtension == "jpg" { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        }
        XCTAssertThrowsError(try addPhoto(s.sessionId))
        store.writeData = { data, url in try data.write(to: url, options: .atomic) }
        XCTAssertEqual(try store.loadSession(s.sessionId).photos.count, 0)
    }

    func testSaveMaskAndMissingMaskBecomesFailed() throws {
        let s = try makeSession()
        let p = try addPhoto(s.sessionId)
        try store.saveMask(sessionId: s.sessionId, photoId: p.photoId, pngData: Data([9, 9]), mask: MaskInfo(status: .candidate, width: 10, height: 10, method: MaskInfo.visionMethod, instanceCount: 1, selectedInstances: [1], selection: .auto))
        var loaded = try store.loadSession(s.sessionId)
        XCTAssertEqual(loaded.photos[0].mask.status, .candidate)
        XCTAssertEqual(loaded.photos[0].mask.file, "masks/\(p.photoId).png")

        try FileManager.default.removeItem(at: store.maskURL(s.sessionId, photoId: p.photoId))
        loaded = try store.loadSession(s.sessionId)
        XCTAssertEqual(loaded.photos[0].mask.status, .failed)
        XCTAssertNil(loaded.photos[0].mask.file)
        XCTAssertEqual(loaded.photos[0].mask.error, "maskFileMissing")
        // 直したものが保存されている。
        let raw = try SessionJSON.makeDecoder().decode(CaptureSession.self, from: Data(contentsOf: store.sessionFileURL(s.sessionId)))
        XCTAssertEqual(raw.photos[0].mask.status, .failed)
    }

    func testOrphanFilesAreIgnoredAndMissingPhotoIsDropped() throws {
        let s = try makeSession()
        let p1 = try addPhoto(s.sessionId)
        let p2 = try addPhoto(s.sessionId)
        let dir = store.sessionDirectory(s.sessionId)
        try Data([1]).write(to: dir.appendingPathComponent("photos/\(SessionStore.newId()).jpg"))
        try Data([1]).write(to: dir.appendingPathComponent("masks/junk.png"))
        try Data([1]).write(to: dir.appendingPathComponent("stray.txt"))
        try FileManager.default.removeItem(at: store.photoURL(s.sessionId, photoId: p1.photoId))
        let loaded = try store.loadSession(s.sessionId)
        XCTAssertEqual(loaded.photos.map(\.photoId), [p2.photoId])
        // 転送するファイルは session.json と、記録にある写真だけ。
        let snapshot = try store.makeTransferSnapshot(s.sessionId)
        XCTAssertEqual(snapshot.manifest.entries.map(\.path), ["photos/\(p2.photoId).jpg", "session.json"])
        // 余分なフォルダがあっても一覧は壊れない。
        try FileManager.default.createDirectory(at: store.sessionsDirectory.appendingPathComponent("not-a-session"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store.sessionsDirectory.appendingPathComponent(SessionStore.newId()), withIntermediateDirectories: true)
        XCTAssertEqual(store.listSessions().count, 1)
    }

    func testBusySessionCannotBeModified() throws {
        let s = try makeSession()
        store.setBusy(s.sessionId, true)
        XCTAssertThrowsError(try addPhoto(s.sessionId)) { XCTAssertEqual($0 as? SessionStoreError, .sessionBusy(s.sessionId)) }
        XCTAssertThrowsError(try store.updateSession(s.sessionId) { $0.title = "x" })
        XCTAssertFalse(store.tryMarkBusy(s.sessionId))
        store.setBusy(s.sessionId, false)
        XCTAssertNoThrow(try addPhoto(s.sessionId))
    }

    func testUpdateWithoutChangeDoesNotTouch() throws {
        let s = try makeSession()
        let before = try Data(contentsOf: store.sessionFileURL(s.sessionId))
        try store.updateSession(s.sessionId, now: Date().addingTimeInterval(100)) { _ in }
        XCTAssertEqual(try Data(contentsOf: store.sessionFileURL(s.sessionId)), before)
    }

    func testRecoverInterruptedMasks() throws {
        let s = try makeSession()
        let p = try addPhoto(s.sessionId)
        try store.updateSession(s.sessionId) { $0.photos[0].mask.status = .processing }
        let recovered = store.recoverInterruptedMasks()
        XCTAssertEqual(recovered.map(\.photoId), [p.photoId])
        XCTAssertEqual(try store.loadSession(s.sessionId).photos[0].mask.status, .notGenerated)
    }

    func testTransferStatePersistsAndIsNotInManifest() throws {
        let s = try makeSession()
        try addPhoto(s.sessionId)
        let state = TransferState.complete(manifestHash: "abc", receiverId: "R", at: Date(timeIntervalSince1970: 1_800_000_000), receiverPath: "/x")
        try store.saveTransferState(s.sessionId, state)
        XCTAssertEqual(store.loadTransferState(s.sessionId), state)
        let paths = try store.makeTransferSnapshot(s.sessionId).manifest.entries.map(\.path)
        XCTAssertFalse(paths.contains("transfer.json"))
        XCTAssertFalse(paths.contains("local.json"))
    }
}
