@testable import CaptureCore
import simd
import XCTest

/// 平面の作品（workKind が flat、撮影方向 flat1）の型と計算。
final class FlatPlanAndCodingTests: XCTestCase {
    func testFlatPlanIsOneTopTarget() {
        let plan = DirectionPlanPreset.flat1.plan
        XCTAssertEqual(plan.id, "flat1")
        XCTAssertEqual(plan.targets.count, 1)
        let top = plan.targets[0]
        XCTAssertEqual(top.id, "top-e90")
        XCTAssertTrue(top.anyAzimuth)
        XCTAssertEqual(top.elevationDeg, 90)
        XCTAssertEqual(top.elevationToleranceDeg, 20)
        XCTAssertEqual(top.azimuthToleranceDeg, 180)
        XCTAssertTrue(plan.isFlat)
        XCTAssertFalse(plan.needsReference)
        XCTAssertFalse(plan.usesStepNames)
        XCTAssertEqual(plan.displayName(of: top), "真上")
        // 立体の一覧はそのまま。
        XCTAssertTrue(DirectionPlanPreset.ai5.plan.needsReference)
        XCTAssertFalse(DirectionPlanPreset.ai5.plan.isFlat)
    }

    func testObjectPresetsAndPlanForKind() {
        XCTAssertFalse(DirectionPlanPreset.objectPresets.contains(.flat1))
        XCTAssertEqual(DirectionPlanPreset.objectPresets.first, .ai5)
        XCTAssertEqual(DirectionPlanPreset.plan(for: .flat, objectPreset: .photogrammetry).id, "flat1")
        XCTAssertEqual(DirectionPlanPreset.plan(for: .object, objectPreset: .photogrammetry).id, "photogrammetry")
        XCTAssertEqual(DirectionPlanPreset.plan(for: .object, objectPreset: .flat1).id, "ai5")
    }

    private func decode(_ workKindJSON: String) throws -> CaptureSession {
        let text = """
        {"schema":"memoria.capture.session","schemaVersion":1,"sessionId":"8B0F0000-0000-4000-8000-000000000001","title":""\(workKindJSON),
         "createdAt":"2026-11-09T10:00:00+09:00","updatedAt":"2026-11-09T10:00:00+09:00","conventions":{},
         "device":{"model":"iPhone15,4","systemName":"iOS","systemVersion":"26.6","appVersion":"0.1.0","appBuild":"1"},
         "referenceFrames":[],"directionPlan":{"id":"flat1","targets":[]},"photos":[]}
        """
        return try SessionJSON.makeDecoder().decode(CaptureSession.self, from: Data(text.utf8))
    }

    func testWorkKindMissingOrNullReadsAsObject() throws {
        XCTAssertEqual(try decode("").workKind, .object)
        XCTAssertEqual(try decode(#","workKind":null"#).workKind, .object)
        XCTAssertEqual(try decode(#","workKind":"flat""#).workKind, .flat)
        XCTAssertTrue(try decode(#","workKind":"flat""#).isFlat)
        XCTAssertThrowsError(try decode(#","workKind":"sculpture""#))
    }

    func testFlatPhotoJSONShape() throws {
        let quad = FlatQuad(topLeft: PixelPoint(x: 100, y: 200), topRight: PixelPoint(x: 900, y: 210),
                            bottomRight: PixelPoint(x: 890, y: 700), bottomLeft: PixelPoint(x: 110, y: 690))
        var s = CaptureSession(sessionId: "8B0F0000-0000-4000-8000-000000000001", title: "えのぐの絵", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                               device: Fixtures.device, directionPlan: DirectionPlanPreset.flat1.plan, workKind: .flat)
        let frame = Fixtures.frame(cameraToWorld: Fixtures.lookAt(from: SIMD3(0, 0.4, 0), to: SIMD3(0, 0, 0.0001)))
        let flat = FlatPhotoInfo(corners: quad, cornersMethod: FlatPhotoInfo.visionMethod, cornersConfidence: 0.97, sheetAtFrameEdge: false,
                                 size: FlatSheetSize(widthM: 0.297, heightM: 0.21, planeSource: "estimatedPlane"),
                                 rectified: FlatRectifiedImage(file: "rectified/11111111-0000-4000-8000-000000000001.jpg", width: 2970, height: 2100))
        s.photos = [PhotoRecorder.makeFlatPhoto(session: s, photoId: "11111111-0000-4000-8000-000000000001", sequence: 1, frame: frame,
                                                context: Fixtures.context(ref: nil), flat: flat, distanceM: 0.4)]
        let data = try SessionJSON.makeEncoder().encode(s)
        let j = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(j["workKind"] as? String, "flat")
        XCTAssertEqual((j["directionPlan"] as? [String: Any])?["id"] as? String, "flat1")
        let photo = try XCTUnwrap((j["photos"] as? [[String: Any]])?.first)
        XCTAssertTrue(photo["referenceFrameId"] is NSNull)
        let f = try XCTUnwrap(photo["flat"] as? [String: Any])
        XCTAssertEqual(Set(f.keys), ["corners", "cornersMethod", "cornersConfidence", "sheetAtFrameEdge", "size", "rectified"])
        let corners = try XCTUnwrap(f["corners"] as? [String: [Double]])
        XCTAssertEqual(corners["topLeft"], [100, 200])
        XCTAssertEqual(corners["bottomLeft"], [110, 690])
        XCTAssertEqual((f["size"] as? [String: Any])?["planeSource"] as? String, "estimatedPlane")
        XCTAssertEqual((f["rectified"] as? [String: Any])?["file"] as? String, "rectified/11111111-0000-4000-8000-000000000001.jpg")
        let direction = try XCTUnwrap(photo["direction"] as? [String: Any])
        XCTAssertTrue(direction["azimuthDeg"] is NSNull)
        XCTAssertEqual(direction["targetId"] as? String, "top-e90")
        // 読み直しても同じ。
        XCTAssertEqual(try SessionJSON.makeDecoder().decode(CaptureSession.self, from: data), s)

        // 用紙が見つからなかった写真：測った値はすべて null。
        s.photos[0].flat = .noSheet
        let j2 = try XCTUnwrap(JSONSerialization.jsonObject(with: SessionJSON.makeEncoder().encode(s)) as? [String: Any])
        let f2 = try XCTUnwrap(((j2["photos"] as? [[String: Any]])?.first)?["flat"] as? [String: Any])
        for key in ["corners", "cornersMethod", "cornersConfidence", "sheetAtFrameEdge", "size", "rectified"] {
            XCTAssertTrue(f2[key] is NSNull, key)
        }
    }
}

final class FlatGeometryTests: XCTestCase {
    /// 机（y = 0）の上の A4 の紙（幅 0.297 × 高さ 0.21、中心が原点）の四隅：左上・右上・右下・左下（上が −Z）。
    let a4: [SIMD3<Double>] = [SIMD3(-0.1485, 0, -0.105), SIMD3(0.1485, 0, -0.105), SIMD3(0.1485, 0, 0.105), SIMD3(-0.1485, 0, 0.105)]

    func testLookDownDeg() {
        XCTAssertEqual(FlatGeometry.lookDownDeg(cameraToWorld: Fixtures.lookAt(from: SIMD3(0, 0.4, 0), to: SIMD3(0, 0, 0.0001))), 90, accuracy: 0.05)
        XCTAssertEqual(FlatGeometry.lookDownDeg(cameraToWorld: Fixtures.lookAt(from: SIMD3(0, 0, 0), to: SIMD3(0, 0, -1))), 0, accuracy: 1e-9)
        XCTAssertEqual(FlatGeometry.lookDownDeg(cameraToWorld: Fixtures.lookAt(from: SIMD3(0, 1, 0), to: SIMD3(0, 0, -1))), 45, accuracy: 1e-9)
        XCTAssertEqual(FlatGeometry.lookDownDeg(cameraToWorld: Fixtures.lookAt(from: SIMD3(0, 0, 0), to: SIMD3(0, 1, -1))), -45, accuracy: 1e-9)
    }

    func testDisplayRotationFallsBackToPortraitScreen() {
        XCTAssertEqual(FlatGeometry.displayRotation(deviceOrientation: "faceUp"), 90)
        XCTAssertEqual(FlatGeometry.displayRotation(deviceOrientation: "faceDown"), 90)
        XCTAssertEqual(FlatGeometry.displayRotation(deviceOrientation: "unknown"), 90)
        XCTAssertEqual(FlatGeometry.displayRotation(deviceOrientation: "landscapeLeft"), 0)
        XCTAssertEqual(FlatGeometry.displayRotation(deviceOrientation: "portrait"), 90)
    }

    func testRayThroughProjectedPointHitsThePoint() {
        for (from, to) in [(SIMD3(0.05, 0.4, 0.02), SIMD3(0, 0, 0.0001)), (SIMD3(0, 0.3, 0.3), SIMD3(0, 0, 0))] {
            let camera = Fixtures.camera(from: from, to: to)
            for corner in a4 {
                let pixel = try! XCTUnwrap(camera.project(corner))
                let ray = FlatGeometry.ray(throughPixel: pixel, camera: camera, imageSize: PixelSize(width: 1920, height: 1440))
                let hit = try! XCTUnwrap(FlatGeometry.intersect(ray, planePoint: .zero, planeNormal: SIMD3(0, 1, 0)))
                XCTAssertEqual(simd_distance(hit, corner), 0, accuracy: 1e-9)
            }
        }
    }

    func testIntersectRejectsPlaneBehindOrParallel() {
        let ray = Ray(origin: SIMD3(0, 0.4, 0), direction: SIMD3(0, 1, 0))
        XCTAssertNil(FlatGeometry.intersect(ray, planePoint: .zero, planeNormal: SIMD3(0, 1, 0)))
        let flatRay = Ray(origin: SIMD3(0, 0.4, 0), direction: SIMD3(1, 0, 0))
        XCTAssertNil(FlatGeometry.intersect(flatRay, planePoint: .zero, planeNormal: SIMD3(0, 1, 0)))
        let far = Ray(origin: SIMD3(0, 10, 0), direction: SIMD3(0, -1, 0))
        XCTAssertNil(FlatGeometry.intersect(far, planePoint: .zero, planeNormal: SIMD3(0, 1, 0)))
    }

    /// 投影した四隅から実寸を測り直す（真上・斜め・保存した画像が K の画像の 2 倍のとき）。
    func testMeasureSizeRecoversA4() throws {
        let views: [(SIMD3<Double>, SIMD3<Double>)] = [
            (SIMD3(0, 0.45, 0), SIMD3(0, 0, 0.0001)),     // 真上
            (SIMD3(0.02, 0.35, 0.2), SIMD3(0, 0, 0)),     // 60° くらいの斜め
        ]
        for (from, to) in views {
            let camera = Fixtures.camera(from: from, to: to)
            for scale in [1, 2] {
                let pixels = try a4.map { try XCTUnwrap(camera.project($0)) * Double(scale) }
                let quad = FlatQuad(topLeft: PixelPoint(pixels[0]), topRight: PixelPoint(pixels[1]),
                                    bottomRight: PixelPoint(pixels[2]), bottomLeft: PixelPoint(pixels[3]))
                let size = try XCTUnwrap(FlatGeometry.measureSize(
                    corners: quad, camera: camera, imageSize: PixelSize(width: 1920 * scale, height: 1440 * scale),
                    planePoint: SIMD3(0.3, 0, -0.2), planeNormal: SIMD3(0, 1, 0), planeSource: "estimatedPlane"))
                XCTAssertEqual(size.widthM, 0.297, accuracy: 0.0002)
                XCTAssertEqual(size.heightM, 0.21, accuracy: 0.0002)
                XCTAssertEqual(size.planeSource, "estimatedPlane")
            }
        }
    }

    func testMeasureSizeIsNilWhenACornerMissesThePlane() {
        let camera = Fixtures.camera(from: SIMD3(0, 0.45, 0), to: SIMD3(0, 0, 0.0001))
        let quad = FlatQuad(topLeft: PixelPoint(x: 100, y: 100), topRight: PixelPoint(x: 1800, y: 100),
                            bottomRight: PixelPoint(x: 1800, y: 1300), bottomLeft: PixelPoint(x: 100, y: 1300))
        // 平面がカメラより上：どの角も当たらない。
        XCTAssertNil(FlatGeometry.measureSize(corners: quad, camera: camera, imageSize: PixelSize(width: 1920, height: 1440),
                                              planePoint: SIMD3(0, 1, 0), planeNormal: SIMD3(0, 1, 0), planeSource: "estimatedPlane"))
    }

    func testOrderCornersWithoutRotation() throws {
        let shuffled: [SIMD2<Double>] = [SIMD2(900, 700), SIMD2(100, 100), SIMD2(100, 700), SIMD2(900, 120)]
        let q = try XCTUnwrap(FlatGeometry.orderCorners(shuffled, imageWidth: 1000, imageHeight: 800, rotationDegClockwise: 0))
        XCTAssertEqual(q.topLeft, PixelPoint(x: 100, y: 100))
        XCTAssertEqual(q.topRight, PixelPoint(x: 900, y: 120))
        XCTAssertEqual(q.bottomRight, PixelPoint(x: 900, y: 700))
        XCTAssertEqual(q.bottomLeft, PixelPoint(x: 100, y: 700))
    }

    /// 縦向き（時計回りに 90° 回して見る）：センサーの左下が、画面の左上になる。
    func testOrderCornersWithPortraitRotation() throws {
        let a = SIMD2<Double>(100, 100), b = SIMD2<Double>(900, 100), c = SIMD2<Double>(900, 700), d = SIMD2<Double>(100, 700)
        let q = try XCTUnwrap(FlatGeometry.orderCorners([b, d, a, c], imageWidth: 1000, imageHeight: 800, rotationDegClockwise: 90))
        XCTAssertEqual(q.topLeft.simd, d)
        XCTAssertEqual(q.topRight.simd, a)
        XCTAssertEqual(q.bottomRight.simd, b)
        XCTAssertEqual(q.bottomLeft.simd, c)
        // 回したあとの辺：上の辺はセンサーの縦の辺。
        XCTAssertEqual(q.edgeLengths.top, 600, accuracy: 1e-9)
        XCTAssertEqual(q.edgeLengths.left, 800, accuracy: 1e-9)
        let q270 = try XCTUnwrap(FlatGeometry.orderCorners([a, b, c, d], imageWidth: 1000, imageHeight: 800, rotationDegClockwise: 270))
        XCTAssertEqual(q270.topLeft.simd, b)
        XCTAssertEqual(q270.bottomRight.simd, d)
    }

    func testOrderCornersRejectsDegenerateInput() {
        XCTAssertNil(FlatGeometry.orderCorners([SIMD2(0, 0), SIMD2(1, 1), SIMD2(2, 2)], imageWidth: 10, imageHeight: 10, rotationDegClockwise: 0))
        XCTAssertNil(FlatGeometry.orderCorners([SIMD2(0, 0), SIMD2(1, 1), SIMD2(2, 2), SIMD2(3, 3)], imageWidth: 10, imageHeight: 10, rotationDegClockwise: 0))
    }

    func testTouchesFrameEdge() {
        let inside = FlatQuad(topLeft: PixelPoint(x: 100, y: 100), topRight: PixelPoint(x: 900, y: 100),
                              bottomRight: PixelPoint(x: 900, y: 700), bottomLeft: PixelPoint(x: 100, y: 700))
        XCTAssertFalse(FlatGeometry.touchesFrameEdge(inside, imageWidth: 1000, imageHeight: 800))
        var edge = inside
        edge.topRight = PixelPoint(x: 995, y: 100)
        XCTAssertTrue(FlatGeometry.touchesFrameEdge(edge, imageWidth: 1000, imageHeight: 800))
        edge = inside
        edge.bottomLeft = PixelPoint(x: 100, y: 790)
        XCTAssertTrue(FlatGeometry.touchesFrameEdge(edge, imageWidth: 1000, imageHeight: 800))
    }

    func testRectifiedSizeUsesMeasuredAspect() throws {
        let quad = FlatQuad(topLeft: PixelPoint(x: 100, y: 100), topRight: PixelPoint(x: 1100, y: 100),
                            bottomRight: PixelPoint(x: 1100, y: 800), bottomLeft: PixelPoint(x: 100, y: 800))
        let measured = try XCTUnwrap(FlatGeometry.rectifiedSize(corners: quad, size: FlatSheetSize(widthM: 0.297, heightM: 0.21, planeSource: "estimatedPlane")))
        XCTAssertEqual(measured.width, 1000)
        XCTAssertEqual(measured.height, Int((1000 / (0.297 / 0.21)).rounded()))
        let unmeasured = try XCTUnwrap(FlatGeometry.rectifiedSize(corners: quad, size: nil))
        XCTAssertEqual(unmeasured.width, 1000)
        XCTAssertEqual(unmeasured.height, 700)
        // 縦長の紙：長い辺は高さ。
        let tall = try XCTUnwrap(FlatGeometry.rectifiedSize(corners: quad, size: FlatSheetSize(widthM: 0.21, heightM: 0.297, planeSource: "estimatedPlane")))
        XCTAssertEqual(tall.height, 1000)
        XCTAssertLessThan(tall.width, tall.height)
    }
}

final class FlatGuidanceTests: XCTestCase {
    let sheet: [SIMD2<Double>] = [SIMD2(0.2, 0.15), SIMD2(0.8, 0.15), SIMD2(0.8, 0.85), SIMD2(0.2, 0.85)]

    func testGuidanceOrder() {
        XCTAssertEqual(FlatGuidance.evaluate(corners: sheet, lookDownDeg: 55), .tilt(currentDeg: 55, minimumDeg: 70))
        XCTAssertEqual(FlatGuidance.evaluate(corners: nil, lookDownDeg: 88), .noSheet)
        XCTAssertEqual(FlatGuidance.evaluate(corners: sheet, lookDownDeg: 88), .ready)
        XCTAssertEqual(FlatGuidance.evaluate(corners: sheet, lookDownDeg: 70), .ready)
        XCTAssertEqual(FlatGuidance.evaluate(corners: sheet, lookDownDeg: nil), .ready)
        let atEdge = [SIMD2(0.005, 0.15), SIMD2(0.8, 0.15), SIMD2(0.8, 0.85), SIMD2(0.2, 0.85)]
        XCTAssertEqual(FlatGuidance.evaluate(corners: atEdge, lookDownDeg: 88), .sheetAtEdge)
        let small = [SIMD2(0.45, 0.45), SIMD2(0.55, 0.45), SIMD2(0.55, 0.55), SIMD2(0.45, 0.55)]
        XCTAssertEqual(FlatGuidance.evaluate(corners: small, lookDownDeg: 88), .sheetSmall)
        XCTAssertTrue(FlatGuidance.ready.allowsAutoCapture)
        XCTAssertFalse(FlatGuidance.sheetAtEdge.allowsAutoCapture)
        XCTAssertTrue(FlatGuidance.tilt(currentDeg: 55, minimumDeg: 70).message.contains("55° → 70°"))
    }

    func testStabilizerNeedsStillCorners() {
        var s = FlatShotStabilizer(holdSeconds: 0.8, maxCornerShift: 0.015)
        XCTAssertEqual(s.update(corners: sheet, timestamp: 0, allowed: true), 0)
        XCTAssertEqual(s.update(corners: sheet, timestamp: 0.4, allowed: true), 0.5, accuracy: 1e-9)
        // 角の順が入れ替わっても、同じ位置なら続けて数える。
        XCTAssertEqual(s.update(corners: sheet.reversed(), timestamp: 0.6, allowed: true), 0.75, accuracy: 1e-9)
        XCTAssertEqual(s.update(corners: sheet, timestamp: 1.0, allowed: true), 1)
        // 動いたら数え直す。
        let moved = sheet.map { $0 + SIMD2(0.05, 0) }
        XCTAssertEqual(s.update(corners: moved, timestamp: 1.1, allowed: true), 0)
        XCTAssertEqual(s.update(corners: moved, timestamp: 1.5, allowed: true), 0.5, accuracy: 1e-9)
        // 案内が ready でない・見失った：数え直す。
        XCTAssertEqual(s.update(corners: moved, timestamp: 1.6, allowed: false), 0)
        XCTAssertEqual(s.update(corners: moved, timestamp: 1.7, allowed: true), 0)
        XCTAssertEqual(s.update(corners: nil, timestamp: 1.8, allowed: true), 0)
    }
}

final class FlatRecordingAndProgressTests: XCTestCase {
    func flatSession() -> CaptureSession {
        CaptureSession(sessionId: SessionStore.newId(), title: "えのぐの絵", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                       device: Fixtures.device, directionPlan: DirectionPlanPreset.flat1.plan, workKind: .flat)
    }

    func photo(_ s: CaptureSession, seq: Int, lookDown: Double, tracking: TrackingState = .normal, flat: FlatPhotoInfo = .noSheet) -> Photo {
        // 真下から lookDown だけ起こした向き。
        let t = (90 - lookDown) * .pi / 180
        let position = SIMD3<Double>(0, 0.4, 0)
        let target = position + SIMD3(0, -cos(t), -sin(t) - 1e-6)
        let frame = Fixtures.frame(cameraToWorld: Fixtures.lookAt(from: position, to: target), tracking: tracking, reason: tracking == .limited ? .excessiveMotion : nil)
        return PhotoRecorder.makeFlatPhoto(session: s, photoId: String(format: "00000000-0000-4000-8000-%012d", seq), sequence: seq,
                                           frame: frame, context: Fixtures.context(ref: nil), flat: flat, distanceM: 0.41234)
    }

    func testFlatPhotoDirection() {
        let s = flatSession()
        let overhead = photo(s, seq: 1, lookDown: 85)
        XCTAssertTrue(overhead.direction.confirmed)
        XCTAssertNil(overhead.direction.unconfirmedReason)
        XCTAssertEqual(overhead.direction.targetId, "top-e90")
        XCTAssertNil(overhead.direction.azimuthDeg)
        XCTAssertEqual(overhead.direction.elevationDeg ?? 0, 85, accuracy: 0.01)
        XCTAssertEqual(overhead.direction.distanceM, 0.4123)
        XCTAssertNil(overhead.referenceFrameId)
        XCTAssertEqual(overhead.mask.status, .notGenerated)
        XCTAssertEqual(overhead.flat, .noSheet)

        let tilted = photo(s, seq: 2, lookDown: 60)
        XCTAssertTrue(tilted.direction.confirmed)
        XCTAssertNil(tilted.direction.targetId)

        // 傾きは重力から決まるので、追跡が limited でも確定。notAvailable は参考値。
        XCTAssertTrue(photo(s, seq: 3, lookDown: 85, tracking: .limited).direction.confirmed)
        let lost = photo(s, seq: 4, lookDown: 85, tracking: .notAvailable)
        XCTAssertFalse(lost.direction.confirmed)
        XCTAssertEqual(lost.direction.unconfirmedReason, .trackingNotNormal)
        XCTAssertNil(lost.direction.targetId)
    }

    func testElevationOnlyMatch() {
        let plan = DirectionPlanPreset.flat1.plan
        XCTAssertEqual(Coverage.matchElevationOnly(elevationDeg: 71, plan: plan)?.id, "top-e90")
        XCTAssertNil(Coverage.matchElevationOnly(elevationDeg: 69, plan: plan))
        XCTAssertNil(Coverage.matchElevationOnly(elevationDeg: nil, plan: plan))
        // 方位のある方向には当てはめない。
        XCTAssertNil(Coverage.matchElevationOnly(elevationDeg: 15, plan: DirectionPlanPreset.ai5.plan))
    }

    func testProgressIgnoresMasksAndReferenceFrames() {
        var s = flatSession()
        let quad = FlatQuad(topLeft: PixelPoint(x: 100, y: 100), topRight: PixelPoint(x: 900, y: 100),
                            bottomRight: PixelPoint(x: 900, y: 700), bottomLeft: PixelPoint(x: 100, y: 700))
        let found = FlatPhotoInfo(corners: quad, cornersMethod: FlatPhotoInfo.visionMethod, cornersConfidence: 0.9, sheetAtFrameEdge: false)

        var r = Readiness.make(session: s)
        XCTAssertTrue(r.isFlat)
        XCTAssertEqual(r.totalCount, 1)
        XCTAssertEqual(r.doneCount, 0)
        XCTAssertEqual(r.directionSummary, "真上の写真 0/1")

        s.photos = [photo(s, seq: 1, lookDown: 85)]  // 用紙なし・マスクは notGenerated のまま
        r = Readiness.make(session: s, pendingPhotoIds: [s.photos[0].photoId])
        XCTAssertTrue(r.isComplete)
        XCTAssertEqual(r.directionSummary, "真上の写真 1/1 そろいました")
        XCTAssertEqual(r.pendingMaskCount, 0)
        XCTAssertEqual(r.issues(for: s.photos[0].photoId), [.sheetNotFound])

        // 撮り直し：新しい写真が代表、前の写真は置き換え済み。真上でない写真は数えない。
        s.photos.append(photo(s, seq: 2, lookDown: 88, flat: found))
        s.photos.append(photo(s, seq: 3, lookDown: 50, flat: found))
        r = Readiness.make(session: s)
        XCTAssertTrue(r.isComplete)
        XCTAssertEqual(r.progress.targets[0].photoId, s.photos[1].photoId)
        XCTAssertEqual(r.supersededPhotoIds, [s.photos[0].photoId])
        XCTAssertEqual(r.issues(for: s.photos[1].photoId), [])
        XCTAssertEqual(r.issues(for: s.photos[2].photoId), [.notOverhead])
        XCTAssertEqual(Set(r.issues(for: s.photos[0].photoId)), [.sheetNotFound, .superseded])

        var edge = found
        edge.sheetAtFrameEdge = true
        s.photos = [photo(s, seq: 4, lookDown: 85, flat: edge)]
        XCTAssertEqual(Readiness.make(session: s).issues(for: s.photos[0].photoId), [.sheetAtFrameEdge])
        XCTAssertEqual(Readiness.make(session: s).attentionSummary, "気になる写真 1 枚（用紙が端で切れているかも 1）")
    }

    func testMaskOutcomeIsAlwaysGoodWhenNotUsed() {
        let s = flatSession()
        var p = photo(s, seq: 1, lookDown: 85)
        for status in [MaskStatus.notGenerated, .processing, .failed, .noObject] {
            p.mask.status = status
            XCTAssertEqual(p.maskOutcome(policy: .notUsed), .good)
        }
    }
}

final class FlatSessionStoreTests: XCTestCase {
    var root: URL!
    var store: SessionStore!

    override func setUp() {
        root = Fixtures.tempDirectory()
        store = SessionStore(rootDirectory: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func addFlatPhoto(_ sessionId: String, rectified: Data?) throws -> Photo {
        let photoId = SessionStore.newId()
        let frame = Fixtures.frame(cameraToWorld: Fixtures.lookAt(from: SIMD3(0, 0.4, 0), to: SIMD3(0, 0, 0.0001)))
        let quad = FlatQuad(topLeft: PixelPoint(x: 100, y: 100), topRight: PixelPoint(x: 900, y: 100),
                            bottomRight: PixelPoint(x: 900, y: 700), bottomLeft: PixelPoint(x: 100, y: 700))
        let flat = FlatPhotoInfo(corners: quad, cornersMethod: FlatPhotoInfo.visionMethod, cornersConfidence: 0.9, sheetAtFrameEdge: false,
                                 rectified: rectified.map { _ in FlatRectifiedImage(file: "", width: 800, height: 600) })
        return try store.addPhoto(sessionId: sessionId, photoId: photoId, jpegData: Data(repeating: 0xAB, count: 50), rectifiedJPEG: rectified) { s, seq in
            PhotoRecorder.makeFlatPhoto(session: s, photoId: photoId, sequence: seq, frame: frame, context: Fixtures.context(ref: nil), flat: flat)
        }
    }

    func testFlatSessionWithRectifiedImage() throws {
        let s = try store.createSession(title: "えのぐの絵", device: Fixtures.device, plan: DirectionPlanPreset.flat1.plan, workKind: .flat)
        XCTAssertEqual(try store.loadSession(s.sessionId).workKind, .flat)
        let p = try addFlatPhoto(s.sessionId, rectified: Data(repeating: 0xCD, count: 30))
        XCTAssertEqual(p.flat?.rectified?.file, "rectified/\(p.photoId).jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.rectifiedURL(s.sessionId, photoId: p.photoId).path))
        let loaded = try store.loadSession(s.sessionId)
        XCTAssertEqual(SessionStore.transferPaths(for: loaded), ["session.json", "photos/\(p.photoId).jpg", "rectified/\(p.photoId).jpg"])
        let snapshot = try store.makeTransferSnapshot(s.sessionId)
        XCTAssertEqual(snapshot.manifest.entry(path: "rectified/\(p.photoId).jpg")?.size, 30)

        // 補正した画像が無くなったら、記録から外す（写真は残す）。
        try FileManager.default.removeItem(at: store.rectifiedURL(s.sessionId, photoId: p.photoId))
        let repaired = try store.loadSession(s.sessionId)
        XCTAssertNil(repaired.photos[0].flat?.rectified)
        XCTAssertNotNil(repaired.photos[0].flat?.corners)
        XCTAssertEqual(SessionStore.transferPaths(for: repaired), ["session.json", "photos/\(p.photoId).jpg"])

        // 写真を消すと、補正した画像も消える。
        let p2 = try addFlatPhoto(s.sessionId, rectified: Data(repeating: 0xCD, count: 30))
        try store.deletePhoto(sessionId: s.sessionId, photoId: p2.photoId)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.rectifiedURL(s.sessionId, photoId: p2.photoId).path))
    }

    func testFlatPhotoWithoutRectifiedImage() throws {
        let s = try store.createSession(title: "", device: Fixtures.device, plan: DirectionPlanPreset.flat1.plan, workKind: .flat)
        let p = try addFlatPhoto(s.sessionId, rectified: nil)
        XCTAssertNil(p.flat?.rectified)
        XCTAssertEqual(SessionStore.transferPaths(for: try store.loadSession(s.sessionId)), ["session.json", "photos/\(p.photoId).jpg"])
    }
}
