@testable import CaptureCore
import simd
import XCTest

// 1 回の撮影で 3D にできるデータをそろえるための判定（正面の高さ・基準なしのシャッター・マスクの確かめ・撮り直し・送る前の確認・基準ごとの大きさ）。

final class FrontElevationTests: XCTestCase {
    let base = SIMD3<Double>(0.1, -0.7, -0.4)
    let plan = DirectionPlanPreset.ring8.plan

    private func frontContext(elevation: Double, plan: DirectionPlan? = nil) -> DirectionContext {
        DirectionContext.make(
            cameraPosition: Fixtures.position(base: base, height: 0.15, azimuth: 0, elevation: elevation, distance: 0.4),
            basePoint: base, heightM: 0.15, objectToWorld: nil, plan: plan ?? self.plan, covered: []
        )
    }

    func testFrontTargetIsNearestAzimuthZeroElevation() {
        XCTAssertEqual(Coverage.frontTarget(plan: plan, elevationDeg: 39)?.id, "a000-e20")
        let high = DirectionPlanPreset.ring8plusHigh.plan
        XCTAssertEqual(Coverage.frontTarget(plan: high, elevationDeg: 39)?.id, "a000-e50")
        XCTAssertEqual(Coverage.frontTarget(plan: high, elevationDeg: 30)?.id, "a000-e20")
        XCTAssertNil(Coverage.frontTarget(plan: DirectionPlan(id: "x", targets: [plan.targets[1]]), elevationDeg: 20))
    }

    func testGuidanceAndWarningWhenFrontIsTooHighOrLow() {
        let tooHigh = frontContext(elevation: 39)
        XCTAssertNil(tooHigh.azimuthDeg)
        XCTAssertEqual(tooHigh.frontTarget?.id, "a000-e20")
        XCTAssertEqual(tooHigh.frontElevationOK, false)
        XCTAssertTrue(tooHigh.guidance.contains("もう少し低い位置から"), tooHigh.guidance)

        let tooLow = frontContext(elevation: 0)
        XCTAssertEqual(tooLow.frontElevationOK, false)
        XCTAssertTrue(tooLow.guidance.contains("もう少し高い位置から"), tooLow.guidance)

        let fine = frontContext(elevation: 25)
        XCTAssertEqual(fine.frontElevationOK, true)
        XCTAssertTrue(fine.guidance.contains("正面から撮ってください"), fine.guidance)

        // 上からの方向がある一覧では、39° は a000-e50 の許容の中。
        XCTAssertEqual(frontContext(elevation: 39, plan: DirectionPlanPreset.ring8plusHigh.plan).frontElevationOK, true)
    }

    private func evaluate(_ direction: DirectionContext) -> QualityAssessment {
        var e = QualityEvaluator()
        var last = QualityAssessment.initial
        for i in 0..<10 {
            last = e.evaluate(LiveFrameSample(
                timestamp: Double(i) * 0.1, trackingState: .normal, reference: .awaitingFront,
                projection: ProjectionResult(status: .inside, boundingBox: PixelRect(x: 500, y: 300, width: 900, height: 800), sizeFraction: 0.55, center: SIMD2(960, 720)),
                direction: direction, angularSpeed: 0.05, linearSpeed: 0.02, meanLuma: 0.5, sharpness: 0.01, ambientIntensity: 1000, exposureDuration: 0.01
            ))
        }
        return last
    }

    func testDirectionCheckWarnsButDoesNotBlockFrontPhoto() {
        let high = evaluate(frontContext(elevation: 39))
        XCTAssertEqual(high.status(.direction), .warning)
        XCTAssertTrue(high.canManualCapture)
        XCTAssertFalse(high.canAutoCapture)
        XCTAssertTrue(high.primaryMessage.contains("もう少し低い位置から"), high.primaryMessage)

        let fine = evaluate(frontContext(elevation: 22))
        XCTAssertEqual(fine.status(.direction), .ok)
        XCTAssertFalse(fine.canAutoCapture)  // 正面の 1 枚目は手で撮る
    }

    func testFirstPhotoGetsFrontTargetOnlyWithinTolerance() {
        let center = base + SIMD3(0, 0.075, 0)
        for (elevation, expected) in [(22.0, "a000-e20" as String?), (34.0, "a000-e20"), (39.0, nil)] {
            var s = Fixtures.session(base: base)
            let position = Fixtures.position(base: base, height: 0.15, azimuth: 0, elevation: elevation, distance: 0.4)
            let photo = PhotoRecorder.makePhoto(
                in: &s, photoId: SessionStore.newId(), sequence: 1,
                frame: Fixtures.frame(cameraToWorld: Fixtures.lookAt(from: position, to: center)), context: Fixtures.context(ref: "ref-1")
            )
            XCTAssertTrue(photo.direction.confirmed)
            XCTAssertEqual(photo.direction.azimuthDeg, 0)
            XCTAssertEqual(photo.direction.elevationDeg ?? 0, elevation, accuracy: 0.01)
            XCTAssertEqual(photo.direction.targetId, expected, "elevation \(elevation)")
        }
    }
}

final class ShutterPolicyTests: XCTestCase {
    private func assessment(warnings: Bool, manual: Bool = true) -> QualityAssessment {
        let status: CheckStatus = warnings ? .warning : .ok
        return QualityAssessment(
            checks: CheckKind.allCases.map { CheckResult(kind: $0, status: $0 == .brightness ? status : .ok, message: "") },
            canAutoCapture: false, canManualCapture: manual, stabilityProgress: 0, primaryMessage: "", autoTargetId: nil
        )
    }

    func testShutterRequiresReferenceByDefault() {
        XCTAssertEqual(ShutterPolicy.action(hasReference: false, assessment: assessment(warnings: false), captureInFlight: false), .confirmNoReference)
        XCTAssertEqual(ShutterPolicy.action(hasReference: false, assessment: assessment(warnings: false), captureInFlight: false, noReferenceAcknowledged: true), .capture)
        XCTAssertEqual(ShutterPolicy.action(hasReference: false, assessment: assessment(warnings: true), captureInFlight: false, noReferenceAcknowledged: true), .confirmWarnings)
        XCTAssertEqual(ShutterPolicy.action(hasReference: true, assessment: assessment(warnings: false), captureInFlight: false), .capture)
        XCTAssertEqual(ShutterPolicy.action(hasReference: true, assessment: assessment(warnings: true), captureInFlight: false), .confirmWarnings)
        XCTAssertEqual(ShutterPolicy.action(hasReference: true, assessment: assessment(warnings: false), captureInFlight: true), .unavailable)
        XCTAssertEqual(ShutterPolicy.action(hasReference: false, assessment: assessment(warnings: false, manual: false), captureInFlight: false), .unavailable)
    }

    func testAutoCaptureNeverFiresWithoutReadyReference() {
        let plan = DirectionPlanPreset.ring8.plan
        // 方向の情報は「未撮影の方向の上」でも、基準が無い・正面が決まっていないなら自動では撮らない。
        let onTarget = DirectionContext(azimuthDeg: 45, elevationDeg: 20, distanceM: 0.4, matchedTarget: plan.target(id: "a045-e20"),
                                        matchedTargetCovered: false, nextTarget: plan.target(id: "a045-e20"), coveredCount: 1, totalCount: 8)
        for reference in [ReferenceState.none, .awaitingFront] {
            var e = QualityEvaluator()
            var r = QualityAssessment.initial
            for i in 0..<20 {
                r = e.evaluate(LiveFrameSample(
                    timestamp: Double(i) * 0.1, trackingState: .normal, reference: reference,
                    projection: ProjectionResult(status: .inside, boundingBox: PixelRect(x: 500, y: 300, width: 900, height: 800), sizeFraction: 0.55, center: SIMD2(960, 720)),
                    direction: onTarget, angularSpeed: 0, linearSpeed: 0, meanLuma: 0.5, sharpness: 0.01, ambientIntensity: 1000, exposureDuration: 0.01
                ))
                XCTAssertFalse(r.canAutoCapture, "\(reference)")
            }
            XCTAssertNil(r.autoTargetId)
        }
    }
}

final class MaskPlausibilityTests: XCTestCase {
    // 4032 × 3024 の写真、作品の輪郭は (1800, 1200)–(2200, 1700) の長方形。切り抜きは 1.2 倍（480 × 600 → 下限 512）。
    let box = PixelRect(x: 1800, y: 1200, width: 400, height: 500)
    var plan: MaskCropPlan {
        MaskCropPlanner.plan(object: ProjectedObject(boundingBox: box, silhouette: [
            SIMD2(box.minX, box.minY), SIMD2(box.maxX, box.minY), SIMD2(box.maxX, box.maxY), SIMD2(box.minX, box.maxY),
        ]), imageWidth: 4032, imageHeight: 3024)
    }

    /// 切り抜きの大きさのマスク。`fill(x, y)`（写真の座標）が true のところを 255。
    private func cropMask(_ plan: MaskCropPlan, _ fill: (Int, Int) -> Bool) -> [UInt8] {
        let r = plan.region
        var m = [UInt8](repeating: 0, count: r.width * r.height)
        for y in 0..<r.height { for x in 0..<r.width where fill(r.x + x, r.y + y) { m[y * r.width + x] = 255 } }
        return m
    }

    private func check(_ fill: (Int, Int) -> Bool) -> MaskCheck {
        let p = plan
        return MaskPlausibility.evaluate(cropMask: cropMask(p, fill), width: p.region.width, height: p.region.height, plan: p)
    }

    func testObjectInsideSilhouetteIsOK() {
        XCTAssertEqual(plan.region, PixelBox(x: 1744, y: 1150, width: 512, height: 600))
        // 輪郭の中の楕円（マウスのような作品）。
        let c = check { x, y in
            let dx = (Double(x) - 2000) / 150, dy = (Double(y) - 1480) / 180
            return dx * dx + dy * dy <= 1
        }
        XCTAssertEqual(c.status, .ok, "\(c)")
        XCTAssertEqual(c.reasons, [])
        XCTAssertEqual(c.insideSilhouetteRatio ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(c.touchedCropEdges, 0)
        XCTAssertLessThan(c.cropCoverage ?? 1, 0.4)
    }

    func testCornerBlobIsSuspicious() {
        // 切り抜きの左上の角から入りこむ物（撮る人の体のような物）。
        let c = check { x, y in x < 1900 && y < 1350 }
        XCTAssertEqual(c.status, .suspicious)
        XCTAssertTrue(c.reasons.contains(.touchesCropEdge), "\(c.reasons)")
        XCTAssertTrue(c.reasons.contains(.outsideObject), "\(c.reasons)")
        XCTAssertTrue(c.reasons.contains(.offCenter), "\(c.reasons)")
        XCTAssertEqual(c.touchedCropEdges, 2)
    }

    func testWholeCropIsTooLarge() {
        let c = check { _, _ in true }
        XCTAssertEqual(c.status, .suspicious)
        XCTAssertTrue(c.reasons.contains(.tooLarge), "\(c.reasons)")
        XCTAssertTrue(c.reasons.contains(.touchesCropEdge), "\(c.reasons)")
        XCTAssertEqual(c.cropCoverage ?? 0, 1, accuracy: 0.001)
    }

    func testTinySpeckIsTooSmallAndEmptyIsSuspicious() {
        let tiny = check { x, y in abs(x - 2000) < 8 && abs(y - 1450) < 8 }
        XCTAssertEqual(tiny.status, .suspicious)
        XCTAssertEqual(tiny.reasons, [.tooSmall])
        let empty = check { _, _ in false }
        XCTAssertEqual(empty.status, .suspicious)
        XCTAssertEqual(empty.reasons, [.empty])
    }

    func testFullImageMaskIsUnknown() {
        let full = MaskCropPlan.fullImage(width: 400, height: 300)
        let c = MaskPlausibility.evaluate(cropMask: [UInt8](repeating: 255, count: 400 * 300), width: 400, height: 300, plan: full)
        XCTAssertEqual(c, .unknown)
        XCTAssertEqual(c.status, .unknown)
        XCTAssertEqual(c.reasons, [.noProjection])
    }

    func testFullSizeAndDownsampledMasksAgreeWithCropMask() {
        let p = plan
        let fill: (Int, Int) -> Bool = { x, y in x >= 1850 && x < 2150 && y >= 1300 && y < 1650 }
        let crop = MaskPlausibility.evaluate(cropMask: cropMask(p, fill), width: p.region.width, height: p.region.height, plan: p)
        // 写真の大きさのマスクを 1/4 に縮めたもの（Mac で確かめるとき）。
        let w = 1008, h = 756
        var small = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w where fill(x * 4 + 2, y * 4 + 2) { small[y * w + x] = 255 } }
        let full = MaskPlausibility.evaluate(fullMask: small, width: w, height: h, plan: p)
        XCTAssertEqual(crop.status, .ok)
        XCTAssertEqual(full.status, .ok)
        XCTAssertEqual(crop.cropCoverage ?? 0, full.cropCoverage ?? 1, accuracy: 0.02)
        XCTAssertEqual(crop.insideSilhouetteRatio ?? 0, full.insideSilhouetteRatio ?? 1, accuracy: 0.02)
    }

    func testCheckIsRecordedInSessionJSON() throws {
        var mask = MaskInfo(status: .candidate, file: "masks/x.png", width: 4, height: 2, method: MaskInfo.visionMethod, instanceCount: 1, selectedInstances: [1], selection: .auto)
        mask.check = MaskCheck(status: .suspicious, reasons: [.outsideObject, .touchesCropEdge], insideSilhouetteRatio: 0.65, cropCoverage: 0.32,
                               silhouetteAreaRatio: 0.58, centerOffset: 0.38, touchedCropEdges: 2)
        let data = try SessionJSON.makeEncoder().encode(mask)
        let j = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let check = try XCTUnwrap(j["check"] as? [String: Any])
        XCTAssertEqual(check["status"] as? String, "suspicious")
        XCTAssertEqual(check["reasons"] as? [String], ["outsideObject", "touchesCropEdge"])
        XCTAssertEqual(check["insideSilhouetteRatio"] as? Double, 0.65)
        XCTAssertEqual(check["cropCoverage"] as? Double, 0.32)
        XCTAssertEqual(try SessionJSON.makeDecoder().decode(MaskInfo.self, from: data), mask)
        // check の無い前の版のマスクも読める（null と同じ）。
        let old = #"{"status":"candidate","file":"masks/x.png","selectedInstances":[1]}"#
        XCTAssertNil(try SessionJSON.makeDecoder().decode(MaskInfo.self, from: Data(old.utf8)).check)
        // unknown の確かめは割合が null。
        let unknown = try XCTUnwrap(JSONSerialization.jsonObject(with: SessionJSON.makeEncoder().encode(MaskCheck.unknown)) as? [String: Any])
        XCTAssertEqual(unknown["status"] as? String, "unknown")
        XCTAssertTrue(unknown["insideSilhouetteRatio"] is NSNull)
        XCTAssertTrue(unknown["cropCoverage"] is NSNull)
    }
}

final class TargetProgressTests: XCTestCase {
    let plan = DirectionPlanPreset.ring8.plan
    private var sequence = 0

    private func photo(ref: String? = "ref-2", target: String?, confirmed: Bool = true, mask: MaskStatus, check: MaskCheckStatus? = nil) -> Photo {
        sequence += 1
        var m = MaskInfo(status: mask)
        m.check = check.map { MaskCheck(status: $0, reasons: $0 == .ok ? [] : [.outsideObject]) }
        return Photo(
            photoId: String(format: "00000000-0000-4000-8000-%012d", sequence), sequence: sequence, capturedAt: Date(), trigger: .auto, referenceFrameId: ref,
            image: ImageInfo(file: "photos/x.jpg", width: 1, height: 1, displayRotationDegClockwise: 90, deviceOrientation: "portrait"),
            camera: CameraInfo(arFrameTimestamp: 0, cameraToWorld: Matrix4x4(matrix_identity_double4x4), intrinsics: Matrix3x3(matrix_identity_double3x3), intrinsicsResolution: PixelSize(width: 1, height: 1), exposureDurationS: nil, exposureOffsetEV: nil, trackingState: .normal, trackingReason: nil),
            direction: DirectionInfo(confirmed: confirmed, unconfirmedReason: confirmed ? nil : .noReference, targetId: target, azimuthDeg: 0, elevationDeg: 20, distanceM: 0.4),
            quality: PhotoQuality(live: .unknown), mask: m
        )
    }

    func testMaskOutcome() {
        XCTAssertEqual(photo(target: nil, mask: .confirmed).maskOutcome, .good)
        XCTAssertEqual(photo(target: nil, mask: .confirmed, check: .suspicious).maskOutcome, .good)  // ユーザーが確認した
        XCTAssertEqual(photo(target: nil, mask: .candidate, check: .ok).maskOutcome, .good)
        XCTAssertEqual(photo(target: nil, mask: .candidate).maskOutcome, .pending)
        XCTAssertEqual(photo(target: nil, mask: .candidate, check: .suspicious).maskOutcome, .bad)
        XCTAssertEqual(photo(target: nil, mask: .candidate, check: .unknown).maskOutcome, .bad)
        XCTAssertEqual(photo(target: nil, mask: .notGenerated).maskOutcome, .pending)
        XCTAssertEqual(photo(target: nil, mask: .processing).maskOutcome, .pending)
        XCTAssertEqual(photo(target: nil, mask: .failed).maskOutcome, .bad)
        XCTAssertEqual(photo(target: nil, mask: .noObject).maskOutcome, .bad)
    }

    private func session(_ photos: [Photo]) -> CaptureSession {
        var s = Fixtures.session()
        s.referenceFrames[0].invalidatedAt = Date()
        s.referenceFrames.append(ReferenceFrame(id: "ref-2", createdAt: Date(), basePointWorld: .zero))
        s.photos = photos
        return s
    }

    func testStatesAndNewerPhotoWins() {
        let a000 = photo(target: "a000-e20", mask: .candidate, check: .ok)
        let a045 = photo(target: "a045-e20", mask: .processing)
        let a090bad = photo(target: "a090-e20", mask: .noObject)
        let a090good = photo(target: "a090-e20", mask: .candidate, check: .ok)
        let a135bad = photo(target: "a135-e20", mask: .candidate, check: .suspicious)
        let a135retry = photo(target: "a135-e20", mask: .notGenerated)
        let a180good = photo(target: "a180-e20", mask: .confirmed)
        let a180worse = photo(target: "a180-e20", mask: .failed)
        let a225good = photo(target: "a225-e20", mask: .candidate, check: .ok)
        let a225pending = photo(target: "a225-e20", mask: .processing)
        let a270bad = photo(target: "a270-e20", mask: .candidate, check: .suspicious)
        let other = [
            photo(ref: "ref-1", target: "a315-e20", mask: .candidate, check: .ok),       // 前の基準
            photo(target: "a315-e20", confirmed: false, mask: .candidate, check: .ok),  // 方向が参考値
            photo(target: nil, mask: .candidate, check: .ok),                           // 一覧の外
        ]
        let s = session([a000, a045, a090bad, a090good, a135bad, a135retry, a180good, a180worse, a225good, a225pending, a270bad] + other)
        let p = Coverage.progress(in: s, referenceFrameId: "ref-2")
        XCTAssertEqual(p.state(of: "a000-e20"), .done)
        XCTAssertEqual(p.state(of: "a045-e20"), .checking)
        XCTAssertEqual(p.state(of: "a090-e20"), .done)
        XCTAssertEqual(p.state(of: "a135-e20"), .checking)
        XCTAssertEqual(p.state(of: "a180-e20"), .done)
        XCTAssertEqual(p.state(of: "a225-e20"), .done)
        XCTAssertEqual(p.state(of: "a270-e20"), .retake)
        XCTAssertEqual(p.state(of: "a315-e20"), .notShot)
        XCTAssertEqual(p.doneIds, ["a000-e20", "a090-e20", "a180-e20", "a225-e20"])
        XCTAssertEqual(p.retakeIds, ["a270-e20"])
        XCTAssertEqual(p.coveredForCapture, ["a000-e20", "a045-e20", "a090-e20", "a135-e20", "a180-e20", "a225-e20"])
        XCTAssertFalse(p.isComplete)
        // 新しい写真が勝つ：撮り直す前の写真は置き換え済み。使える写真より新しくて確認中の写真は、まだ置き換え済みにしない。
        XCTAssertEqual(p.targets.first { $0.target.id == "a090-e20" }?.photoId, a090good.photoId)
        XCTAssertEqual(p.supersededPhotoIds, [a090bad.photoId, a135bad.photoId, a180worse.photoId])
        XCTAssertEqual(p.targets.first { $0.target.id == "a225-e20" }?.photoId, a225good.photoId)
    }

    func testRetakeFlowCheckingThenSuspiciousThenGood() {
        var shot = photo(target: "a045-e20", mask: .notGenerated)
        var s = session([shot])
        // 撮った直後：確認中（撮影中は撮ったとみなす → 自動撮影ですぐに撮り直さない）。
        XCTAssertEqual(Coverage.progress(in: s, referenceFrameId: "ref-2").state(of: "a045-e20"), .checking)
        XCTAssertTrue(Coverage.progress(in: s, referenceFrameId: "ref-2").coveredForCapture.contains("a045-e20"))
        // 怪しい結果が返った：撮り直し（撮ったとみなさない → 自動撮影がまた狙う）。
        shot.mask = MaskInfo(status: .candidate, check: MaskCheck(status: .suspicious, reasons: [.touchesCropEdge]))
        s.photos = [shot]
        let p = Coverage.progress(in: s, referenceFrameId: "ref-2")
        XCTAssertEqual(p.state(of: "a045-e20"), .retake)
        XCTAssertFalse(p.coveredForCapture.contains("a045-e20"))
        // 撮り直した写真がうまくいった：そろった。前の写真は残して置き換え済み。
        s.photos.append(photo(target: "a045-e20", mask: .candidate, check: .ok))
        let after = Coverage.progress(in: s, referenceFrameId: "ref-2")
        XCTAssertEqual(after.state(of: "a045-e20"), .done)
        XCTAssertEqual(after.supersededPhotoIds, [shot.photoId])
        XCTAssertEqual(s.photos.count, 2)
    }

    func testDirectionContextTargetsRetakeWithGuidance() throws {
        let base = SIMD3<Double>(0, 0, 0)
        let m = try XCTUnwrap(Geometry.objectToWorld(basePoint: base, frontCameraPosition: SIMD3(0, 0, 1)))
        let covered: Set<String> = ["a000-e20", "a090-e20", "a135-e20", "a180-e20", "a225-e20", "a270-e20", "a315-e20"]
        // 0° にいる。45° は撮り直し → 次は 45°、案内に撮り直しの理由。
        let ctx = DirectionContext.make(
            cameraPosition: Fixtures.position(base: base, height: 0.15, azimuth: 0, elevation: 20, distance: 0.5),
            basePoint: base, heightM: 0.15, objectToWorld: m, plan: plan, covered: covered, retake: ["a045-e20"]
        )
        XCTAssertEqual(ctx.nextTarget?.id, "a045-e20")
        XCTAssertEqual(ctx.retakeTargetIds, ["a045-e20"])
        XCTAssertTrue(ctx.guidance.contains("45° の写真の切り抜きがうまくいきませんでした。もう一度撮ります"), ctx.guidance)
        XCTAssertTrue(ctx.guidance.contains("右"), ctx.guidance)
        // 45° の上に来た：撮り直しの方向は未撮影と同じに扱う（自動撮影の対象）。
        let on = DirectionContext.make(
            cameraPosition: Fixtures.position(base: base, height: 0.15, azimuth: 45, elevation: 20, distance: 0.5),
            basePoint: base, heightM: 0.15, objectToWorld: m, plan: plan, covered: covered, retake: ["a045-e20"]
        )
        XCTAssertTrue(on.isOnUncoveredTarget)
        XCTAssertTrue(on.guidance.contains("撮り直します"), on.guidance)
    }

    func testReadinessSummaryAndIssues() {
        let good = (0..<8).map { i in photo(target: plan.targets[i].id, mask: .candidate, check: .ok) }
        let bad = photo(target: "a045-e20", mask: .candidate, check: .suspicious)
        let noRef = photo(ref: nil, target: nil, confirmed: false, mask: .candidate, check: .unknown)
        let failed = photo(ref: "ref-1", target: "a000-e20", mask: .failed)
        // 45° は、怪しい写真のあとで撮り直してうまくいった（怪しい写真は置き換え済み）。
        var photos = [noRef, failed, bad] + good
        var s = session(photos)
        var r = Readiness.make(session: s)
        XCTAssertEqual(r.referenceFrameId, "ref-2")
        XCTAssertTrue(r.isComplete)
        XCTAssertEqual(r.doneCount, 8)
        XCTAssertEqual(r.directionSummary, "方向 8/8 そろいました")
        XCTAssertEqual(r.issues(for: bad.photoId), [.maskSuspicious, .superseded])
        XCTAssertEqual(r.issues(for: noRef.photoId), [.maskUnchecked, .directionUnconfirmed])
        XCTAssertEqual(r.issues(for: failed.photoId), [.maskMissing])
        XCTAssertEqual(r.supersededPhotoIds, [bad.photoId])
        XCTAssertEqual(r.attentionCount, 3)
        XCTAssertEqual(r.attentionSummary, "気になる写真 3 枚（切り抜きが怪しい 1・切り抜きを確かめられない 1・切り抜きなし 1・方向が参考値 1・置き換え済み 1）")

        // 最後の 1 枚がまだ確認中・別の 1 枚が撮り直し。
        photos = [noRef] + good.dropLast()
        photos.append(photo(target: "a315-e20", mask: .processing))
        photos[3].mask.check = MaskCheck(status: .suspicious, reasons: [.outsideObject])
        s = session(photos)
        r = Readiness.make(session: s)
        XCTAssertFalse(r.isComplete)
        XCTAssertEqual(r.pendingMaskCount, 1)
        XCTAssertEqual(r.directionSummary, "方向 6/8・確認中 1・撮り直し 1")
    }
}

final class ReferenceObjectSizeTests: XCTestCase {
    let base = SIMD3<Double>(0.1, -0.7, -0.4)

    func testPhotosUseTheirOwnReferenceFrameSize() throws {
        var s = Fixtures.session(base: base)
        s.referenceFrames[0].object = ObjectSize(heightM: 0.15, radiusM: 0.08)
        let center = base + SIMD3(0, 0.075, 0)
        let front = Fixtures.position(base: base, height: 0.15, azimuth: 0, elevation: 20, distance: 0.4)
        let first = PhotoRecorder.makePhoto(in: &s, photoId: SessionStore.newId(), sequence: 1,
                                            frame: Fixtures.frame(cameraToWorld: Fixtures.lookAt(from: front, to: center)), context: Fixtures.context(ref: "ref-1"))
        s.photos.append(first)
        let before = try XCTUnwrap(MaskCropPlanner.projectObject(photo: first, session: s))

        // 基準を設定し直して、もっと小さな円柱にした（セッションの object は最後の値になる）。
        s.referenceFrames[0].invalidatedAt = Date()
        s.referenceFrames.append(ReferenceFrame(id: "ref-2", createdAt: Date(), basePointWorld: base, object: ObjectSize(heightM: 0.04, radiusM: 0.05)))
        s.object = ObjectSize(heightM: 0.04, radiusM: 0.05)
        XCTAssertEqual(s.objectSize(referenceFrameId: "ref-1"), ObjectSize(heightM: 0.15, radiusM: 0.08))
        XCTAssertEqual(s.objectSize(referenceFrameId: "ref-2"), ObjectSize(heightM: 0.04, radiusM: 0.05))
        XCTAssertNil(s.objectSize(referenceFrameId: nil))
        // 前の基準の写真は、前の大きさで投影する。
        XCTAssertEqual(try XCTUnwrap(MaskCropPlanner.projectObject(photo: first, session: s)), before)

        // 新しい基準の写真の仰角は、新しい高さ（中心は基準点から 2 cm 上）で測る。
        let camera = base + SIMD3(0, 0.02 + 0.2, 0.4)
        let second = PhotoRecorder.makePhoto(in: &s, photoId: SessionStore.newId(), sequence: 2,
                                             frame: Fixtures.frame(cameraToWorld: Fixtures.lookAt(from: camera, to: base)), context: Fixtures.context(ref: "ref-2"))
        XCTAssertEqual(second.direction.elevationDeg ?? 0, atan2(0.2, 0.4) * 180 / .pi, accuracy: 0.01)

        // 基準ごとの大きさが無い（この項目より前の）基準は、セッションの大きさを使う。
        s.referenceFrames[0].object = nil
        XCTAssertEqual(s.objectSize(referenceFrameId: "ref-1"), ObjectSize(heightM: 0.04, radiusM: 0.05))
    }

    func testReferenceFrameObjectIsEncodedAndOptional() throws {
        var s = Fixtures.session(base: base)
        s.referenceFrames[0].object = ObjectSize(heightM: 0.15, radiusM: 0.08)
        let data = try SessionJSON.makeEncoder().encode(s)
        let j = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let ref = try XCTUnwrap((j["referenceFrames"] as? [[String: Any]])?.first)
        let object = try XCTUnwrap(ref["object"] as? [String: Any])
        XCTAssertEqual(object["heightM"] as? Double, 0.15)
        XCTAssertEqual(object["radiusM"] as? Double, 0.08)
        XCTAssertEqual(object["source"] as? String, "userAdjusted")
        XCTAssertEqual(try SessionJSON.makeDecoder().decode(CaptureSession.self, from: data), s)
    }
}
