@testable import CaptureCore
import Foundation
import simd
import XCTest

/// 向きで案内する撮影（guidance: heading）：向きの計算・位置の確かめ・写真の記録・中心と大きさの導出・十字の切り抜き。
final class HeadingGuidanceTests: XCTestCase {
    /// 作品の中心（世界座標）。
    let center = SIMD3<Double>(0.2, -0.3, -0.5)

    /// 作品のまわりの方位 `azimuth`（正面 = 0、+X 側 = 90。正面のカメラは中心から +Z 方向）、見下ろす角度 `elevation`、距離 `distance` から中心を見るカメラ。
    /// `aimError` は中心からずらして見る量（m、世界の x・y・z）。
    func pose(azimuth: Double, elevation: Double = 15, distance: Double = 0.35, aimError: SIMD3<Double> = .zero) -> simd_double4x4 {
        let az = azimuth * .pi / 180, el = elevation * .pi / 180
        let position = center + distance * SIMD3(sin(az) * cos(el), sin(el), cos(az) * cos(el))
        return Fixtures.lookAt(from: position, to: center + aimError)
    }

    func ray(_ m: simd_double4x4) -> Ray {
        HeadingMath.centerRay(cameraToWorld: m, intrinsics: Fixtures.intrinsics, intrinsicsResolution: PixelSize(width: 1920, height: 1440),
                              imageSize: PixelSize(width: 1920, height: 1440))
    }

    /// 決まった乱数（毎回同じ）。
    struct SeededRandom {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func symmetric(_ amplitude: Double) -> Double { (next() * 2 - 1) * amplitude }
    }

    // MARK: 向き

    func testHeadingAndPitch() {
        XCTAssertEqual(HeadingMath.headingDeg(direction: SIMD3(0, 0, -1))!, 0, accuracy: 1e-9)
        XCTAssertEqual(HeadingMath.headingDeg(direction: SIMD3(-1, 0, 0))!, 90, accuracy: 1e-9)  // 正面から右へ回り込んだカメラの向き
        XCTAssertEqual(HeadingMath.headingDeg(direction: SIMD3(0, 0, 1))!, 180, accuracy: 1e-9)
        XCTAssertNil(HeadingMath.headingDeg(direction: SIMD3(0, -1, 0)))  // 真下：向きが無い
        XCTAssertEqual(HeadingMath.pitchDeg(direction: SIMD3(0, -1, 0)), 90, accuracy: 1e-9)
        // 作品のまわりの方位 a のカメラが中心を見るとき、正面からの向きの差は a。
        let front = HeadingMath.headingDeg(cameraToWorld: pose(azimuth: 0))!
        for a in [90.0, 180, 270, 30] {
            let h = HeadingMath.headingDeg(cameraToWorld: pose(azimuth: a))!
            XCTAssertEqual(Geometry.normalizeDegrees(h - front), a, accuracy: 1e-6)
        }
        XCTAssertEqual(HeadingMath.pitchDeg(cameraToWorld: pose(azimuth: 90, elevation: 15)), 15, accuracy: 1e-6)
    }

    // MARK: 線の交わる点

    func testAxisSolverRecoversKnownPointWithNoise() {
        var random = SeededRandom(state: 42)
        var rays: [Ray] = []
        for a in [0.0, 90, 180, 270] {
            let aim = SIMD3(random.symmetric(0.01), random.symmetric(0.01), random.symmetric(0.01))
            rays.append(ray(pose(azimuth: a + random.symmetric(5), elevation: 15 + random.symmetric(4), distance: 0.3 + random.symmetric(0.05), aimError: aim)))
        }
        rays.append(ray(pose(azimuth: 10, elevation: 85, distance: 0.35)))
        let d = HeadingDeriver.solveCenter(photos: rays.enumerated().map { ("P\($0.offset)", $0.element) })
        XCTAssertEqual(d.status, .ok)
        let c = try! XCTUnwrap(d.centerWorld?.simd)
        XCTAssertLessThan(simd_distance(c, center), 0.012)
        XCTAssertLessThan(d.residualRmsM!, 0.012)
        XCTAssertEqual(d.perPhoto.count, 5)
    }

    func testDegenerateCasesAreUnknown() {
        // 1 枚だけ。
        XCTAssertEqual(HeadingDeriver.solveCenter(photos: [("A", ray(pose(azimuth: 0)))]).status, .unknown)
        XCTAssertEqual(HeadingDeriver.solveCenter(photos: [("A", ray(pose(azimuth: 0)))]).reasons, [.tooFewPhotos])
        XCTAssertNil(HeadingDeriver.solveCenter(photos: [("A", ray(pose(azimuth: 0)))]).centerWorld)
        // ほぼ平行（正面とその横 5°）。
        let parallel = HeadingDeriver.solveCenter(photos: [("A", ray(pose(azimuth: 0))), ("B", ray(pose(azimuth: 5)))])
        XCTAssertEqual(parallel.status, .unknown)
        XCTAssertEqual(parallel.reasons, [.nearParallelAxes])
        XCTAssertNil(parallel.centerWorld)
        // 正面と後ろだけ（向かい合って同じ線の上）：奥行きが決まらない。
        let frontBack = HeadingDeriver.solveCenter(photos: [("A", ray(pose(azimuth: 0, elevation: 0))), ("B", ray(pose(azimuth: 180, elevation: 0)))])
        XCTAssertEqual(frontBack.status, .unknown)
        // 交わる点がカメラの後ろ（2 本とも作品と反対を向いている）。
        let away = [pose(azimuth: 0), pose(azimuth: 90)].map { m -> Ray in let r = ray(m); return Ray(origin: r.origin, direction: -r.direction) }
        let behind = HeadingDeriver.solveCenter(photos: [("A", away[0]), ("B", away[1])])
        XCTAssertEqual(behind.status, .unknown)
        XCTAssertEqual(behind.reasons, [.behindCamera])
        // 2 枚（直角）：求まるが信頼度は低い（外れ方を確かめられない）。
        let two = HeadingDeriver.solveCenter(photos: [("A", ray(pose(azimuth: 0))), ("B", ray(pose(azimuth: 90)))])
        XCTAssertEqual(two.status, .lowConfidence)
        XCTAssertTrue(two.reasons.contains(.onlyTwoPhotos))
        XCTAssertLessThan(simd_distance(two.centerWorld!.simd, center), 1e-6)
    }

    func testOutlierIsExcludedAndLargeResidualIsLowConfidence() {
        var photos = [0.0, 90, 180, 270].enumerated().map { ("P\($0.offset)", ray(pose(azimuth: $0.element))) }
        photos.append(("TOP", ray(pose(azimuth: 0, elevation: 80))))
        // 1 枚だけ、作品の 12 cm 横を十字に合わせた写真。
        photos[1] = ("P1", ray(pose(azimuth: 90, aimError: SIMD3(0, 0, 0.12))))
        let d = HeadingDeriver.solveCenter(photos: photos)
        XCTAssertEqual(d.excludedPhotoIds, ["P1"])
        XCTAssertTrue(d.reasons.contains(.outlierExcluded))
        XCTAssertLessThan(simd_distance(d.centerWorld!.simd, center), 0.005)
        // 3 枚がばらばらにずれている：除かずに、残差が大きいので信頼度が低い。
        let messy = [("A", ray(pose(azimuth: 0, aimError: SIMD3(0.04, 0, 0)))), ("B", ray(pose(azimuth: 90, aimError: SIMD3(0, 0.04, 0.04)))),
                     ("C", ray(pose(azimuth: 200, aimError: SIMD3(-0.04, 0, 0))))]
        let low = HeadingDeriver.solveCenter(photos: messy)
        XCTAssertEqual(low.status, .lowConfidence)
        XCTAssertTrue(low.reasons.contains(.largeResidual))
    }

    // MARK: 位置の確かめ

    func testRotatingOnTheSpotFailsAndWalkingAroundPasses() {
        let front = ray(pose(azimuth: 0))
        // 正面の位置のまま 90° 回した（作品は画面の外）。
        let spot = Fixtures.lookAt(from: front.origin, to: front.origin + SIMD3(-1, -0.27, 0))
        let r = ray(spot)
        let rel = Geometry.normalizeDegrees(HeadingMath.headingDeg(direction: r.direction)! - HeadingMath.headingDeg(direction: front.direction)!)
        XCTAssertEqual(rel, 90, accuracy: 1)
        XCTAssertEqual(HeadingPosition.evaluate(current: r, relativeHeadingDeg: rel, pitchDeg: 15, front: front, shots: []).status, .notWalkedAround)
        // 少し（5 cm）横へずれて回した：まだ歩いていない。
        let shifted = Fixtures.lookAt(from: front.origin + SIMD3(0.05, 0, 0), to: front.origin + SIMD3(-1, -0.27, 0))
        XCTAssertEqual(HeadingPosition.evaluate(current: ray(shifted), relativeHeadingDeg: 90, pitchDeg: 15, front: front, shots: []).status, .notWalkedAround)
        // 作品の右へ歩いて、作品を中央に入れた。
        let right = ray(pose(azimuth: 90))
        let ok = HeadingPosition.evaluate(current: right, relativeHeadingDeg: 90, pitchDeg: 15, front: front, shots: [])
        XCTAssertEqual(ok.status, .ok)
        XCTAssertEqual(ok.distanceM!, 0.35 * cos(15 * .pi / 180), accuracy: 0.01)
        XCTAssertEqual(ok.frontDistanceM!, 0.35 * cos(15 * .pi / 180), accuracy: 0.01)
        // 後ろ（正面の線とほぼ平行）：正面の線の先にいれば ok。その場で 180° 回すと失敗。
        XCTAssertEqual(HeadingPosition.evaluate(current: ray(pose(azimuth: 180)), relativeHeadingDeg: 180, pitchDeg: 15, front: front, shots: []).status, .ok)
        let turned = Fixtures.lookAt(from: front.origin, to: front.origin + SIMD3(0, -0.27, 1))
        XCTAssertEqual(HeadingPosition.evaluate(current: ray(turned), relativeHeadingDeg: 180, pitchDeg: 15, front: front, shots: []).status, .notWalkedAround)
        // 正面と右があれば、作品の位置の推定から確かめる（後ろ・左）。
        let shots = [right]
        XCTAssertEqual(HeadingPosition.evaluate(current: ray(pose(azimuth: 270)), relativeHeadingDeg: 270, pitchDeg: 15, front: front, shots: shots).status, .ok)
        XCTAssertEqual(HeadingPosition.evaluate(current: ray(turned), relativeHeadingDeg: 180, pitchDeg: 15, front: front, shots: shots).status, .notWalkedAround)
        // 真上：作品の上にいれば ok、正面の位置で下を向いただけなら失敗。
        XCTAssertEqual(HeadingPosition.evaluate(current: ray(pose(azimuth: 20, elevation: 85)), relativeHeadingDeg: 20, pitchDeg: 85, front: front, shots: shots).status, .ok)
        let down = Fixtures.lookAt(from: front.origin, to: front.origin + SIMD3(0.01, -1, 0))
        XCTAssertEqual(HeadingPosition.evaluate(current: ray(down), relativeHeadingDeg: 0, pitchDeg: 89, front: front, shots: shots).status, .notWalkedAround)
        XCTAssertEqual(HeadingPosition.evaluate(current: ray(pose(azimuth: 20, elevation: 85)), relativeHeadingDeg: 0, pitchDeg: 85, front: front, shots: []).status, .ok)
    }

    func testDistanceHint() {
        XCTAssertEqual(HeadingDistanceHint.make(distanceM: 0.6, frontDistanceM: 0.35), .closer)
        XCTAssertEqual(HeadingDistanceHint.make(distanceM: 0.2, frontDistanceM: 0.35), .farther)
        XCTAssertNil(HeadingDistanceHint.make(distanceM: 0.38, frontDistanceM: 0.35))
        XCTAssertNil(HeadingDistanceHint.make(distanceM: nil, frontDistanceM: 0.35))
    }

    // MARK: 撮影画面の案内

    func testContextGuidanceBeforeAndAfterFront() {
        let plan = DirectionPlanPreset.ai5.plan
        let before = HeadingContext.make(relativeHeadingDeg: nil, pitchDeg: 15, hasFront: false, position: .notChecked, plan: plan, covered: [])
        XCTAssertTrue(before.guidance.contains("正面"))
        XCTAssertNil(before.matchedTarget)
        XCTAssertFalse(before.isOnUncoveredTarget)
        let low = HeadingContext.make(relativeHeadingDeg: nil, pitchDeg: 40, hasFront: false, position: .notChecked, plan: plan, covered: [])
        XCTAssertEqual(low.frontPitchOK, false)
        XCTAssertTrue(low.guidance.contains("40° → 15°"))

        // 正面を撮った。右へ 30° 回ったところ：次は右（あと 60°）。
        let walking = HeadingContext.make(relativeHeadingDeg: 30, pitchDeg: 15, hasFront: true, position: .notChecked, plan: plan, covered: ["a000-e15"])
        XCTAssertEqual(walking.nextTarget?.id, "a090-e15")
        XCTAssertTrue(walking.guidance.contains("右へ回ってください（あと 60°）"), walking.guidance)
        XCTAssertEqual(walking.crosshair, .aligning)
        // 右の向き・高さだが、その場で回しただけ。
        let spot = HeadingContext.make(relativeHeadingDeg: 88, pitchDeg: 14, hasFront: true, position: HeadingPositionCheck(status: .notWalkedAround), plan: plan, covered: ["a000-e15"])
        XCTAssertEqual(spot.matchedTarget?.id, "a090-e15")
        XCTAssertFalse(spot.isOnUncoveredTarget)
        XCTAssertEqual(spot.crosshair, .notWalked)
        XCTAssertTrue(spot.guidance.contains("その場で回さず"))
        // 歩いて右へ来た。
        let here = HeadingContext.make(relativeHeadingDeg: 88, pitchDeg: 14, hasFront: true,
                                       position: HeadingPositionCheck(status: .ok, distanceM: 0.6, frontDistanceM: 0.35), plan: plan, covered: ["a000-e15"])
        XCTAssertTrue(here.isOnUncoveredTarget)
        XCTAssertEqual(here.crosshair, .ready)
        XCTAssertEqual(here.distanceHint, .closer)
        XCTAssertTrue(here.guidance.hasPrefix("右"))
        // 横がそろったら真上（向きは問わない）。真下を向いて向きが無くても当てはまる。
        let sides: Set<String> = ["a000-e15", "a090-e15", "a180-e15", "a270-e15"]
        let top = HeadingContext.make(relativeHeadingDeg: nil, pitchDeg: 88, hasFront: true, position: HeadingPositionCheck(status: .ok), plan: plan, covered: sides)
        XCTAssertEqual(top.matchedTarget?.id, "top-e90")
        XCTAssertTrue(top.isOnUncoveredTarget)
        let notYet = HeadingContext.make(relativeHeadingDeg: 10, pitchDeg: 40, hasFront: true, position: .notChecked, plan: plan, covered: sides)
        XCTAssertTrue(notYet.guidance.contains("真上"))
    }

    func testEvaluatorAutoCapturesOnlyWhenPositionIsOK() {
        var evaluator = QualityEvaluator()
        let plan = DirectionPlanPreset.ai5.plan
        func sample(_ t: Double, position: HeadingPositionStatus) -> LiveFrameSample {
            let ctx = HeadingContext.make(relativeHeadingDeg: 91, pitchDeg: 15, hasFront: true, position: HeadingPositionCheck(status: position),
                                          plan: plan, covered: ["a000-e15"])
            return LiveFrameSample(timestamp: t, trackingState: .normal, reference: .ready, meanLuma: 0.5, sharpness: 0.01, heading: ctx)
        }
        var a = evaluator.evaluate(sample(0, position: .notWalkedAround))
        for t in stride(from: 0.1, through: 1.0, by: 0.1) { a = evaluator.evaluate(sample(t, position: .notWalkedAround)) }
        XCTAssertFalse(a.canAutoCapture)
        XCTAssertEqual(a.status(.direction), .warning)
        XCTAssertEqual(a.status(.inFrame), .unknown)  // 収まりは撮る人が十字で合わせる
        for t in stride(from: 1.1, through: 2.0, by: 0.1) { a = evaluator.evaluate(sample(t, position: .ok)) }
        XCTAssertTrue(a.canAutoCapture)
        XCTAssertEqual(a.autoTargetId, "a090-e15")
    }

    // MARK: 写真の記録

    func makeSession() -> CaptureSession {
        CaptureSession(sessionId: SessionStore.newId(), title: "テスト", createdAt: Date(timeIntervalSince1970: 1_800_000_000), device: Fixtures.device,
                       directionPlan: DirectionPlanPreset.ai5.plan, workKind: .object, guidance: .heading)
    }

    func record(_ s: inout CaptureSession, _ m: simd_double4x4, id: String? = nil, ref: String?, tracking: TrackingState = .normal) -> Photo {
        let photoId = id ?? SessionStore.newId()
        let photo = PhotoRecorder.makeHeadingPhoto(in: &s, photoId: photoId, sequence: s.photos.count + 1,
                                                   frame: Fixtures.frame(cameraToWorld: m, tracking: tracking), context: Fixtures.context(ref: ref))
        s.photos.append(photo)
        return photo
    }

    func testRecordingFrontSidesTopAndSpotRotation() throws {
        var s = makeSession()
        XCTAssertTrue(s.usesHeadingGuidance)
        let front = record(&s, pose(azimuth: 0), ref: nil)
        let frame = try XCTUnwrap(s.referenceFrames.last)
        XCTAssertTrue(frame.isHeading)
        XCTAssertNil(frame.basePointWorld)
        XCTAssertEqual(frame.frontPhotoId, front.photoId)
        XCTAssertNotNil(frame.heading?.frontHeadingDeg)
        XCTAssertEqual(front.referenceFrameId, frame.id)
        XCTAssertEqual(front.direction.targetId, "a000-e15")
        XCTAssertTrue(front.direction.confirmed)
        XCTAssertEqual(front.heading?.relativeHeadingDeg, 0)
        XCTAssertEqual(front.heading?.position, .notChecked)

        // その場で 90° 回した写真（手で撮った）：保存はするが、右には数えない。
        let spot = record(&s, Fixtures.lookAt(from: HeadingMath.centerRay(of: front).origin, to: HeadingMath.centerRay(of: front).origin + SIMD3(-1, -0.27, 0)), ref: frame.id)
        XCTAssertNil(spot.direction.targetId)
        XCTAssertTrue(spot.direction.confirmed)
        XCTAssertEqual(spot.heading?.position, .notWalkedAround)
        XCTAssertEqual(spot.heading!.relativeHeadingDeg!, 90, accuracy: 1)
        XCTAssertEqual(Readiness.make(session: s).issues(for: spot.photoId), [.offTarget])

        let right = record(&s, pose(azimuth: 92), ref: frame.id)
        XCTAssertEqual(right.direction.targetId, "a090-e15")
        XCTAssertEqual(right.heading?.position, .ok)
        XCTAssertNotNil(right.direction.distanceM)
        let back = record(&s, pose(azimuth: 181), ref: frame.id)
        XCTAssertEqual(back.direction.targetId, "a180-e15")
        let left = record(&s, pose(azimuth: 268, elevation: 12), ref: frame.id)
        XCTAssertEqual(left.direction.targetId, "a270-e15")
        let top = record(&s, pose(azimuth: 40, elevation: 87), ref: frame.id)
        XCTAssertEqual(top.direction.targetId, "top-e90")
        // 追跡が limited：方向は参考値。
        let limited = record(&s, pose(azimuth: 90), ref: frame.id, tracking: .limited)
        XCTAssertFalse(limited.direction.confirmed)
        XCTAssertEqual(limited.direction.unconfirmedReason, .trackingNotNormal)

        let progress = Coverage.progress(in: s, referenceFrameId: frame.id)
        XCTAssertEqual(progress.targets.filter { $0.state != .notShot }.count, 5)

        // 新しい基準（撮影画面を開き直した）：前の基準は無効になる。
        let again = record(&s, pose(azimuth: 0), ref: nil)
        XCTAssertNotEqual(again.referenceFrameId, frame.id)
        XCTAssertFalse(s.referenceFrame(id: frame.id)!.isValid)
    }

    func testTopFirstDoesNotDecideFront() {
        var s = makeSession()
        let top = record(&s, pose(azimuth: 0, elevation: 85), ref: nil)
        XCTAssertFalse(top.direction.confirmed)
        XCTAssertEqual(top.direction.unconfirmedReason, .noReference)
        XCTAssertNil(s.referenceFrames.last?.heading?.frontHeadingDeg)
        let front = record(&s, pose(azimuth: 0), ref: top.referenceFrameId)
        XCTAssertEqual(s.referenceFrames.last?.frontPhotoId, front.photoId)
    }

    // MARK: 撮ったあとの導出

    func fullSession(surface: Bool = false) -> (CaptureSession, String) {
        var s = makeSession()
        let front = record(&s, pose(azimuth: 0), ref: nil)
        let ref = front.referenceFrameId!
        _ = record(&s, pose(azimuth: 90, aimError: SIMD3(0, 0.003, 0)), ref: ref)
        _ = record(&s, pose(azimuth: 180, distance: 0.4), ref: ref)
        _ = record(&s, pose(azimuth: 270, elevation: 18), ref: ref)
        _ = record(&s, pose(azimuth: 10, elevation: 86), ref: ref)
        return (s, ref)
    }

    func testDeriveFillsFrameAndDirections() throws {
        var (s, ref) = fullSession()
        XCTAssertTrue(HeadingDeriver.update(session: &s, frameId: ref))
        let frame = try XCTUnwrap(s.referenceFrame(id: ref))
        let d = try XCTUnwrap(frame.heading?.derivation)
        XCTAssertEqual(d.status, .ok)
        XCTAssertEqual(d.photoIds.count, 5)
        XCTAssertLessThan(simd_distance(d.centerWorld!.simd, center), 0.005)
        // 机の高さが分からない：原点は中心、basePointWorld は null。
        XCTAssertEqual(d.origin, .center)
        XCTAssertNil(frame.basePointWorld)
        let o2w = try XCTUnwrap(frame.objectToWorld?.simd)
        XCTAssertLessThan(simd_distance(o2w.translation, d.centerWorld!.simd), 1e-9)
        // 写真ごとの方向：中心から測った方位・仰角・距離（targetId は撮ったときのまま）。
        let byTarget = Dictionary(uniqueKeysWithValues: s.photos.map { ($0.direction.targetId ?? "-", $0) })
        XCTAssertEqual(byTarget["a000-e15"]!.direction.azimuthDeg!, 0, accuracy: 1)
        XCTAssertEqual(byTarget["a090-e15"]!.direction.azimuthDeg!, 90, accuracy: 1)
        XCTAssertEqual(byTarget["a180-e15"]!.direction.azimuthDeg!, 180, accuracy: 1)
        XCTAssertEqual(byTarget["a270-e15"]!.direction.azimuthDeg!, 270, accuracy: 1)
        XCTAssertEqual(byTarget["a180-e15"]!.direction.distanceM!, 0.4, accuracy: 0.01)
        XCTAssertEqual(byTarget["a270-e15"]!.direction.elevationDeg!, 18, accuracy: 0.5)
        XCTAssertGreaterThan(byTarget["top-e90"]!.direction.elevationDeg!, 80)
        // 撮ったときの向きは heading に残る。
        XCTAssertEqual(byTarget["a180-e15"]!.heading!.relativeHeadingDeg!, 180, accuracy: 0.5)
        // 同じ入力なら変わらない。
        XCTAssertFalse(HeadingDeriver.update(session: &s, frameId: ref))
    }

    func testDeriveUsesSupportSurfaceAsBase() throws {
        var (s, ref) = fullSession()
        HeadingDeriver.update(session: &s, frameId: ref, surface: SupportSurface(heightY: center.y - 0.03, source: .existingPlaneGeometry))
        let frame = try XCTUnwrap(s.referenceFrame(id: ref))
        XCTAssertEqual(frame.heading?.derivation?.origin, .base)
        XCTAssertEqual(frame.basePointWorld!.simd.y, center.y - 0.03, accuracy: 1e-6)
        XCTAssertEqual(frame.base?.source, .existingPlaneGeometry)
        XCTAssertEqual(frame.objectToWorld!.simd.translation.y, center.y - 0.03, accuracy: 1e-6)
        // 次に測れなくても、前に測った面を使う。
        HeadingDeriver.update(session: &s, frameId: ref, surface: nil)
        XCTAssertEqual(s.referenceFrame(id: ref)?.heading?.derivation?.origin, .base)
        // 床（中心の 1 m 下）は作品を置いた面ではない。
        var (s2, ref2) = fullSession()
        HeadingDeriver.update(session: &s2, frameId: ref2, surface: SupportSurface(heightY: center.y - 1.0, source: .existingPlaneGeometry))
        XCTAssertEqual(s2.referenceFrame(id: ref2)?.heading?.derivation?.origin, .center)
        XCTAssertNil(s2.referenceFrame(id: ref2)?.basePointWorld)
    }

    func testSizeIsKeptUntilPhotosChange() throws {
        var (s, ref) = fullSession()
        HeadingDeriver.update(session: &s, frameId: ref)
        let center = s.referenceFrame(id: ref)!.heading!.derivation!.centerWorld
        let size = HeadingSizeEstimate.unknown([.notEnoughMasks])
        XCTAssertTrue(HeadingDeriver.setSize(size, session: &s, frameId: ref, forCenter: center))
        XCTAssertFalse(HeadingDeriver.update(session: &s, frameId: ref))
        XCTAssertEqual(s.referenceFrame(id: ref)?.heading?.derivation?.size, size)
        // 違う中心の大きさは書かない。
        XCTAssertFalse(HeadingDeriver.setSize(size, session: &s, frameId: ref, forCenter: Vector3(SIMD3(9, 9, 9))))
        // 右を撮り直した（代表の写真が変わった）：大きさは求め直す（null）。
        _ = record(&s, pose(azimuth: 95, distance: 0.3), ref: ref)
        XCTAssertTrue(HeadingDeriver.update(session: &s, frameId: ref))
        XCTAssertNil(s.referenceFrame(id: ref)?.heading?.derivation?.size)
    }

    func testDeriveWithOnlyFrontIsUnknown() {
        var s = makeSession()
        let front = record(&s, pose(azimuth: 0), ref: nil)
        HeadingDeriver.update(session: &s, frameId: front.referenceFrameId!)
        let d = s.referenceFrames.last?.heading?.derivation
        XCTAssertEqual(d?.status, .unknown)
        XCTAssertEqual(d?.reasons, [.tooFewPhotos])
        XCTAssertNil(s.referenceFrames.last?.objectToWorld)
        XCTAssertEqual(s.photos[0].direction.azimuthDeg, 0)  // 撮ったときの向きのまま
    }

    // MARK: 大きさ

    /// 箱（中心 `center`、作品座標の幅 w・奥行き d・高さ h）を写真に投影した外接長方形。
    func boxView(_ m: simd_double4x4, role: String, w: Double, d: Double, h: Double, frontHeading: Double) -> HeadingSizeView {
        let o2w = HeadingDeriver.objectToWorld(center: center, frontHeadingDeg: frontHeading, originY: center.y)
        let camera = CameraModel(cameraToWorld: m, intrinsics: Fixtures.intrinsics, imageWidth: 1920, imageHeight: 1440)
        var xs: [Double] = [], ys: [Double] = []
        for i in 0..<8 {
            let p = o2w * SIMD4((i & 1 == 0 ? -w : w) / 2, (i & 2 == 0 ? -h : h) / 2, (i & 4 == 0 ? -d : d) / 2, 1)
            let px = camera.project(SIMD3(p.x, p.y, p.z))!
            xs.append(px.x)
            ys.append(px.y)
        }
        return HeadingSizeView(photoId: role, role: role, camera: camera, maskBox: PixelRect(minX: xs.min()!, minY: ys.min()!, maxX: xs.max()!, maxY: ys.max()!),
                               touches: [false, false, false, false])
    }

    func testSizeOfABoxIsBracketed() {
        let frontHeading = HeadingMath.headingDeg(cameraToWorld: pose(azimuth: 0))!
        let views = [("front", 0.0, 15.0), ("right", 90, 15), ("back", 180, 15), ("left", 270, 15), ("top", 20, 85)].map {
            boxView(pose(azimuth: $0.1, elevation: $0.2), role: $0.0, w: 0.10, d: 0.06, h: 0.04, frontHeading: frontHeading)
        }
        let size = HeadingSizer.estimate(center: center, frontHeadingDeg: frontHeading, views: views)
        XCTAssertEqual(size.status, "approximate")
        // 箱の当てはめ（下の目安）は箱ならほぼ正しい。
        XCTAssertEqual(size.lowerM!.widthM, 0.10, accuracy: 0.002)
        XCTAssertEqual(size.lowerM!.depthM, 0.06, accuracy: 0.002)
        XCTAssertEqual(size.lowerM!.heightM, 0.04, accuracy: 0.002)
        XCTAssertLessThan(size.fitResidualDeg!, 0.05)
        // 中心の面での広がり（上の目安）は大きめ。大きさはその間。
        for (v, lo, hi) in [(size.widthM!, size.lowerM!.widthM, size.upperM!.widthM), (size.depthM!, size.lowerM!.depthM, size.upperM!.depthM),
                            (size.heightM!, size.lowerM!.heightM, size.upperM!.heightM)] {
            XCTAssertGreaterThanOrEqual(hi, lo)
            XCTAssertGreaterThanOrEqual(v, lo - 1e-9)
            XCTAssertLessThanOrEqual(v, hi + 1e-9)
        }
        XCTAssertEqual(size.crossChecks.first { $0.dimension == "width" }?.values.count, 2)
        XCTAssertLessThan(size.crossChecks.first { $0.dimension == "width" }!.disagreement, 0.05)
        // 足りない切り抜き：分からない（数字を入れない）。
        let few = HeadingSizer.estimate(center: center, frontHeadingDeg: frontHeading, views: Array(views.prefix(1)) + [views[4]])
        XCTAssertEqual(few.status, "unknown")
        XCTAssertNil(few.widthM)
        XCTAssertEqual(few.reasons, [.notEnoughMasks])
        // 中心の信頼度が低い：大きさの信頼度も低い。
        XCTAssertEqual(HeadingSizer.estimate(center: center, frontHeadingDeg: frontHeading, views: views, centerConfident: false).confidence, "low")
    }

    func testRefreshComputesSizeOnceMasksAreReady() throws {
        var (s, ref) = fullSession()
        let frontHeading = try XCTUnwrap(s.referenceFrame(id: ref)?.heading?.frontHeadingDeg)
        let bounds: (Photo) -> MaskBounds? = { photo in
            let v = self.boxView(photo.camera.cameraToWorld.simd, role: "x", w: 0.10, d: 0.06, h: 0.04, frontHeading: frontHeading)
            return MaskBounds(box: v.maskBox, touches: [false, false, false, false], width: 1920, height: 1440)
        }
        // 切り抜きを作っている間は、中心だけ求めて大きさは待つ。
        XCTAssertTrue(HeadingSizer.refresh(session: &s, maskBounds: bounds))
        XCTAssertNotNil(s.referenceFrame(id: ref)?.heading?.derivation?.centerWorld)
        XCTAssertNil(s.referenceFrame(id: ref)?.heading?.derivation?.size)
        for i in s.photos.indices {
            s.photos[i].mask = MaskInfo(status: .candidate, file: "masks/\(s.photos[i].photoId).png", check: MaskCheck(status: .ok, reasons: []))
        }
        XCTAssertTrue(HeadingSizer.refresh(session: &s, maskBounds: bounds))
        let size = try XCTUnwrap(s.referenceFrame(id: ref)?.heading?.derivation?.size)
        XCTAssertEqual(size.status, "approximate")
        XCTAssertEqual(size.photoIds.count, 5)
        XCTAssertEqual(size.lowerM!.widthM, 0.10, accuracy: 0.003)
        XCTAssertFalse(HeadingSizer.refresh(session: &s, maskBounds: bounds))
        // 大きさが分かれば、切り抜きの範囲の代わりに箱を写真に投影できる（Mac の memoria-pack の切り抜きの目安）。
        let projected = MaskCropPlanner.projectObject(photo: s.photos[0], session: s)
        XCTAssertNotNil(projected)
        // 切り抜きが使えない：大きさは分からない（数字なし）。
        var (s2, ref2) = fullSession()
        for i in s2.photos.indices { s2.photos[i].mask = .failed("x") }
        HeadingSizer.refresh(session: &s2, maskBounds: bounds)
        let unknown = try XCTUnwrap(s2.referenceFrame(id: ref2)?.heading?.derivation?.size)
        XCTAssertEqual(unknown.status, "unknown")
        XCTAssertNil(unknown.heightM)
    }

    func testMaskBounds() {
        var pixels = [UInt8](repeating: 0, count: 20 * 10)
        for y in 2..<6 { for x in 4..<9 { pixels[y * 20 + x] = 255 } }
        pixels[9 * 20 + 19] = 255  // 1 ピクセルの飛び地は数えない
        let b = MaskBounds.of(pixels: pixels, width: 20, height: 10)!
        XCTAssertEqual(b.box, PixelRect(minX: 4, minY: 2, maxX: 9, maxY: 6))
        XCTAssertEqual(b.touches, [false, false, false, false])
        XCTAssertEqual(b.scaled(toImageWidth: 40, imageHeight: 20), PixelRect(minX: 8, minY: 4, maxX: 18, maxY: 12))
        XCTAssertNil(MaskBounds.of(pixels: [UInt8](repeating: 0, count: 200), width: 20, height: 10))
        var edge = [UInt8](repeating: 0, count: 200)
        for y in 0..<10 { edge[y * 20] = 255; edge[y * 20 + 1] = 255 }
        XCTAssertEqual(MaskBounds.of(pixels: edge, width: 20, height: 10)?.touches, [true, false, true, true])
    }

    // MARK: 十字のまわりの切り抜き

    func testCrosshairPlanAndCheck() {
        let plan = MaskCropPlanner.crosshairPlan(imageWidth: 4032, imageHeight: 3024)
        XCTAssertEqual(plan.source, .crosshair)
        XCTAssertEqual(plan.region.width, 2117)
        XCTAssertEqual(plan.region.height, 2117)
        XCTAssertEqual(Double(plan.region.x) + Double(plan.region.width) / 2, 2016, accuracy: 1)
        XCTAssertEqual(plan.recordedRegion, plan.region)
        XCTAssertEqual(MaskCropPlanner.crosshairPlans(imageWidth: 4032, imageHeight: 3024).count, 2)

        func check(_ inside: (Int, Int) -> Bool) -> MaskCheck { MaskPlausibility.evaluate(plan: plan, isMask: inside) }
        // 十字のまわりの作品。
        let ok = check { x, y in abs(x - 2016) < 300 && abs(y - 1512) < 200 }
        XCTAssertEqual(ok.status, .ok)
        XCTAssertNil(ok.insideSilhouetteRatio)
        XCTAssertNil(ok.silhouetteAreaRatio)
        XCTAssertEqual(check { _, _ in false }.reasons, [.empty])
        XCTAssertEqual(check { x, y in abs(x - 2016) < 20 && abs(y - 1512) < 20 }.reasons, [.tooSmall])
        let table = check { _, _ in true }
        XCTAssertTrue(table.reasons.contains(.tooLarge))
        XCTAssertTrue(table.reasons.contains(.touchesCropEdge))
        let aside = check { x, y in x < plan.region.x + 300 && abs(y - 1512) < 200 }
        XCTAssertTrue(aside.reasons.contains(.offCenter))
        // ai5（lenient）：作品が写っていない（空・小さすぎる）ときだけ撮り直す。
        XCTAssertTrue(MaskRetakePolicy.lenient.needsRetake(check { x, y in abs(x - 2016) < 20 && abs(y - 1512) < 20 }))
        XCTAssertFalse(MaskRetakePolicy.lenient.needsRetake(aside))

        // セッションの写真の切り抜きは、向きで案内したセッションなら十字のまわり（撮ったあとも）。
        var (s, _) = fullSession()
        s.photos[0].image.width = 4032
        s.photos[0].image.height = 3024
        XCTAssertEqual(MaskCropPlanner.plans(photo: s.photos[0], session: s).first?.source, .crosshair)
        var recorded = s.photos[0]
        recorded.mask = MaskInfo(status: .candidate, file: "masks/x.png").recording(plan)
        XCTAssertEqual(MaskCropPlanner.recordedPlan(photo: recorded, session: s)?.region, plan.region)
        XCTAssertEqual(MaskCropPlanner.recordedPlan(photo: recorded, session: s)?.source, .crosshair)
    }

    // MARK: session.json

    func testGuidanceCodingAndDefaults() throws {
        var (s, ref) = fullSession()
        HeadingDeriver.update(session: &s, frameId: ref)
        let data = try SessionJSON.makeEncoder().encode(s)
        let back = try SessionJSON.makeDecoder().decode(CaptureSession.self, from: data)
        XCTAssertEqual(back, s)
        let j = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(j["guidance"] as? String, "heading")
        let frame = try XCTUnwrap((j["referenceFrames"] as? [[String: Any]])?.last)
        XCTAssertTrue(frame["basePointWorld"] is NSNull)
        let derivation = try XCTUnwrap((frame["heading"] as? [String: Any])?["derivation"] as? [String: Any])
        XCTAssertEqual(derivation["method"] as? String, "opticalAxesLeastSquares")
        XCTAssertEqual(derivation["origin"] as? String, "center")
        XCTAssertTrue(derivation["size"] is NSNull)

        // guidance の無い（前の）立体のセッションは前の方法、平面の作品は無し。
        var old = makeSession()
        old.guidance = nil
        XCTAssertEqual(old.captureGuidance, .baseCylinder)
        XCTAssertFalse(old.usesHeadingGuidance)
        let flat = CaptureSession(sessionId: SessionStore.newId(), title: "", createdAt: Date(), device: Fixtures.device,
                                  directionPlan: DirectionPlanPreset.flat1.plan, workKind: .flat, guidance: .heading)
        XCTAssertNil(flat.guidance)
        XCTAssertNil(flat.captureGuidance)
        XCTAssertEqual(CaptureGuidance.resolve(preferred: .heading, plan: DirectionPlanPreset.ai5.plan, workKind: .object), .heading)
        XCTAssertEqual(CaptureGuidance.resolve(preferred: .heading, plan: DirectionPlanPreset.photogrammetry.plan, workKind: .object), .baseCylinder)
        XCTAssertNil(CaptureGuidance.resolve(preferred: .heading, plan: DirectionPlanPreset.flat1.plan, workKind: .flat))
    }
}

final class SupportSurfaceFinderTests: XCTestCase {
    func testTableUnderTheCenterFromFeaturePoints() {
        let center = SIMD3<Double>(0, 0.02, 0)
        var points: [SIMD3<Double>] = []
        var seed: UInt64 = 7
        func r() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
        // 机（y = 0、±1.5 mm）の点と、作品の側面に散らばる点、遠くの床（y = −0.7）。
        for _ in 0..<80 { points.append(SIMD3(r() * 0.4 - 0.2, (r() - 0.5) * 0.003, r() * 0.4 - 0.2)) }
        for _ in 0..<40 { points.append(SIMD3(r() * 0.06 - 0.03, r() * 0.04, r() * 0.06 - 0.03)) }
        for _ in 0..<80 { points.append(SIMD3(r() * 0.4 - 0.2, -0.7, r() * 0.4 - 0.2)) }
        let s = SupportSurfaceFinder.fromFeaturePoints(points, center: center)
        XCTAssertEqual(s?.source, .featurePoints)
        XCTAssertEqual(s!.heightY, 0, accuracy: 0.003)
        // 点が少ないと分からない。
        XCTAssertNil(SupportSurfaceFinder.fromFeaturePoints(Array(points.prefix(5)), center: center))
    }
}
