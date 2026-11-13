@testable import CaptureCore
import simd
import XCTest

/// 立体の作品を自由に撮る撮影（`guidance: "free"`、撮る方向の一覧 `free`）。
final class FreeCaptureTests: XCTestCase {
    func testFreePlanAndGuidance() {
        let plan = DirectionPlanPreset.free.plan
        XCTAssertEqual(plan.id, "free")
        XCTAssertTrue(plan.targets.isEmpty)
        XCTAssertTrue(plan.isFree)
        XCTAssertFalse(plan.isFlat)
        XCTAssertFalse(plan.needsReference)
        XCTAssertEqual(plan.retakePolicy, .notUsed)
        XCTAssertFalse(DirectionPlanPreset.objectPresets.contains(.free))
        XCTAssertFalse(DirectionPlanPreset.objectPresets.contains(.flat1))
        XCTAssertEqual(DirectionPlanPreset.allCases.first, .ai5)
        // 設定に free が残っていても、立体の一覧は既定（ai5）。
        XCTAssertEqual(DirectionPlanPreset.plan(for: .object, objectPreset: .free).id, "ai5")
        // 今ある一覧はそのまま。
        XCTAssertTrue(DirectionPlanPreset.ai5.plan.needsReference)
        XCTAssertFalse(DirectionPlanPreset.ai5.plan.isFree)

        XCTAssertEqual(CaptureGuidance.default, .free)
        XCTAssertEqual(CaptureGuidance(rawValue: "free"), .free)
        XCTAssertEqual(CaptureGuidance.free.displayName, "自由に撮る（標準）")
        XCTAssertEqual(CaptureGuidance.resolve(preferred: .free, plan: DirectionPlanPreset.photogrammetry.plan, workKind: .object), .free)
        XCTAssertNil(CaptureGuidance.resolve(preferred: .free, plan: DirectionPlanPreset.flat1.plan, workKind: .flat))
        // 今ある案内は変わらない。
        XCTAssertEqual(CaptureGuidance.resolve(preferred: .heading, plan: DirectionPlanPreset.ai5.plan, workKind: .object), .heading)
        XCTAssertEqual(CaptureGuidance.resolve(preferred: .baseCylinder, plan: DirectionPlanPreset.ai5.plan, workKind: .object), .baseCylinder)
    }

    func testNewSessionPlan() {
        let free = CaptureGuidance.newSession(workKind: .object, objectPreset: .ai5, preferred: .free)
        XCTAssertEqual(free.plan.id, "free")
        XCTAssertEqual(free.guidance, .free)
        let heading = CaptureGuidance.newSession(workKind: .object, objectPreset: .ai5, preferred: .heading)
        XCTAssertEqual(heading.plan.id, "ai5")
        XCTAssertEqual(heading.guidance, .heading)
        let old = CaptureGuidance.newSession(workKind: .object, objectPreset: .photogrammetry, preferred: .heading)
        XCTAssertEqual(old.plan.id, "photogrammetry")
        XCTAssertEqual(old.guidance, .baseCylinder)
        let flat = CaptureGuidance.newSession(workKind: .flat, objectPreset: .ai5, preferred: .free)
        XCTAssertEqual(flat.plan.id, "flat1")
        XCTAssertNil(flat.guidance)
    }

    func freeSession() -> CaptureSession {
        CaptureSession(sessionId: SessionStore.newId(), title: "ねんど", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                       device: Fixtures.device, directionPlan: DirectionPlanPreset.free.plan, workKind: .object, guidance: .free)
    }

    func photo(_ s: CaptureSession, seq: Int, lookDown: Double, tracking: TrackingState = .normal) -> Photo {
        let t = (90 - lookDown) * .pi / 180
        let position = SIMD3<Double>(0, 0.4, 0)
        let target = position + SIMD3(0, -cos(t), -sin(t) - 1e-6)
        let frame = Fixtures.frame(cameraToWorld: Fixtures.lookAt(from: position, to: target), tracking: tracking,
                                   reason: tracking == .limited ? .excessiveMotion : nil)
        return PhotoRecorder.makeFreePhoto(session: s, photoId: String(format: "00000000-0000-4000-8000-%012d", seq), sequence: seq,
                                           frame: frame, context: Fixtures.context(ref: nil))
    }

    func testFreePhotoRecord() throws {
        let s = freeSession()
        XCTAssertTrue(s.usesFreeCapture)
        XCTAssertFalse(s.usesHeadingGuidance)
        XCTAssertEqual(s.captureGuidance, .free)
        let p = photo(s, seq: 1, lookDown: 20)
        XCTAssertTrue(p.direction.confirmed)
        XCTAssertNil(p.direction.targetId)
        XCTAssertNil(p.direction.azimuthDeg)
        XCTAssertNil(p.direction.distanceM)
        XCTAssertEqual(p.direction.elevationDeg ?? 0, 20, accuracy: 0.01)
        XCTAssertNil(p.referenceFrameId)
        XCTAssertEqual(p.mask.status, .notGenerated)
        XCTAssertNil(p.flat)
        XCTAssertNil(p.heading)
        let lost = photo(s, seq: 2, lookDown: 20, tracking: .notAvailable)
        XCTAssertFalse(lost.direction.confirmed)
        XCTAssertEqual(lost.direction.unconfirmedReason, .trackingNotNormal)

        // JSON：guidance "free"、directionPlan は方向 0 個。読み直しても同じ。
        var withPhoto = s
        withPhoto.photos = [p]
        let data = try SessionJSON.makeEncoder().encode(withPhoto)
        let j = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(j["guidance"] as? String, "free")
        let plan = try XCTUnwrap(j["directionPlan"] as? [String: Any])
        XCTAssertEqual(plan["id"] as? String, "free")
        XCTAssertEqual((plan["targets"] as? [Any])?.count, 0)
        XCTAssertTrue(j["object"] is NSNull)
        XCTAssertEqual((j["referenceFrames"] as? [Any])?.count, 0)
        XCTAssertEqual(try SessionJSON.makeDecoder().decode(CaptureSession.self, from: data), withPhoto)
    }

    func testReadinessCountsPhotos() {
        var s = freeSession()
        var r = Readiness.make(session: s)
        XCTAssertTrue(r.isFree)
        XCTAssertFalse(r.isComplete)
        XCTAssertEqual(r.pendingMaskCount, 0)
        XCTAssertEqual(r.directionSummary, "まだ写真がありません（1 枚以上で送れます）")
        s.photos = (1...7).map { photo(s, seq: $0, lookDown: Double($0 * 10)) }
        r = Readiness.make(session: s, pendingPhotoIds: [s.photos[0].photoId])
        XCTAssertTrue(r.isComplete)
        XCTAssertEqual(r.directionSummary, "写真 7 枚（自由に撮影）")
        XCTAssertEqual(r.pendingMaskCount, 0)  // マスクは作らない
        XCTAssertEqual(r.attentionCount, 0)
        XCTAssertTrue(r.supersededPhotoIds.isEmpty)  // 撮り直しは求めない
        s.photos.append(photo(s, seq: 8, lookDown: 30, tracking: .notAvailable))
        r = Readiness.make(session: s)
        XCTAssertEqual(r.issues(for: s.photos[7].photoId), [.directionUnconfirmed])
    }

    func testStoreKeepsFreeSession() throws {
        let root = Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(rootDirectory: root)
        let s = try store.createSession(title: "ねんど", device: Fixtures.device, plan: DirectionPlanPreset.free.plan, workKind: .object,
                                        guidance: .free, declaredSize: DeclaredSize(heightM: 0.08))
        let photoId = SessionStore.newId()
        let frame = Fixtures.frame(cameraToWorld: Fixtures.lookAt(from: SIMD3(0, 0.3, 0.3), to: SIMD3(0, 0, 0)))
        try store.addPhoto(sessionId: s.sessionId, photoId: photoId, jpegData: Data(repeating: 0xAB, count: 40)) { session, seq in
            PhotoRecorder.makeFreePhoto(session: session, photoId: photoId, sequence: seq, frame: frame, context: Fixtures.context(ref: nil))
        }
        let loaded = try store.loadSession(s.sessionId)
        XCTAssertTrue(loaded.usesFreeCapture)
        XCTAssertEqual(loaded.declaredHeightM, 0.08)
        XCTAssertEqual(loaded.photos.count, 1)
        XCTAssertEqual(SessionStore.transferPaths(for: loaded), ["session.json", "photos/\(photoId).jpg"])
    }
}
