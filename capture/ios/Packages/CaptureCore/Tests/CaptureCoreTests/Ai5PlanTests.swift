@testable import CaptureCore
import simd
import XCTest

// AI に推論させる用の 5 方向（ai5）：正面・右・後ろ・左（仰角 15°）と、方位を問わない真上（top-e90）。
// 一覧・当てはめ（真上は仰角だけ）・撮る順（正面 → 近い横 → … → 真上）・進み具合（n / 5）・NaN にならないこと。

final class Ai5PlanTests: XCTestCase {
    let plan = DirectionPlanPreset.ai5.plan
    let base = SIMD3<Double>(0.1, -0.7, -0.4)
    let height = 0.15

    // MARK: 一覧

    func testPresetIsDefaultAndHasFiveTargets() {
        XCTAssertEqual(DirectionPlanPreset.default, .ai5)
        XCTAssertEqual(DirectionPlanPreset.allCases.first, .ai5)
        XCTAssertEqual(plan.id, "ai5")
        XCTAssertEqual(plan.targets.map(\.id), ["a000-e15", "a090-e15", "a180-e15", "a270-e15", "top-e90"])
        XCTAssertEqual(plan.targets.map(\.anyAzimuth), [false, false, false, false, true])
        for side in plan.targets.prefix(4) {
            XCTAssertEqual(side.elevationDeg, 15)
            XCTAssertEqual(side.azimuthToleranceDeg, 15)
            XCTAssertEqual(side.elevationToleranceDeg, 12)
        }
        let top = plan.targets[4]
        XCTAssertEqual(top.elevationDeg, 90)
        XCTAssertEqual(top.elevationToleranceDeg, 15)
        // 古い読み手が方位で弾かないように：方位 0・許容 180。
        XCTAssertEqual(top.azimuthDeg, 0)
        XCTAssertEqual(top.azimuthToleranceDeg, 180)
        XCTAssertEqual(plan.bands.map(\.elevationDeg), [15, 90])
        XCTAssertFalse(plan.isDense)
        XCTAssertEqual(QualityThresholds.default.autoCaptureCooldown(for: plan), 1.2)
        XCTAssertEqual(DirectionPlanPreset.ai5.summary, "AI に推論させる用。4 方向 + 真上の 5 枚")
        XCTAssertTrue(plan.usesStepNames)
        XCTAssertFalse(DirectionPlanPreset.ring4.plan.usesStepNames)
        XCTAssertEqual(plan.targets.map { plan.displayName(of: $0) }, ["正面", "右", "後ろ", "左", "真上"])
        XCTAssertEqual(plan.targets.map { DirectionContext.label($0, named: true) }, ["正面", "右", "後ろ", "左", "真上"])
        // ほかの一覧の名前は今までどおり。
        XCTAssertEqual(DirectionContext.label(DirectionPlanPreset.ring4.plan.targets[1]), "90°")
        XCTAssertEqual(DirectionPlanPreset.ring4.plan.displayName(of: DirectionPlanPreset.ring4.plan.targets[1]), "90°・高さ 20°")
    }

    func testAnyAzimuthIsWrittenAndReadBack() throws {
        let data = try SessionJSON.makeEncoder().encode(plan)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let targets = try XCTUnwrap(json["targets"] as? [[String: Any]])
        XCTAssertEqual(targets.map { $0["anyAzimuth"] as? Bool }, [false, false, false, false, true])
        XCTAssertEqual(targets[4]["id"] as? String, "top-e90")
        XCTAssertEqual(try SessionJSON.makeDecoder().decode(DirectionPlan.self, from: data), plan)
    }

    // MARK: 当てはめ

    func testTopMatchesByElevationOnlyAtAnyAzimuth() {
        for az in [0.0, 37, 123.4, 180, 271, 359.9] {
            for el in [75.0, 80, 89.9, 90] {
                XCTAssertEqual(Coverage.match(azimuthDeg: az, elevationDeg: el, plan: plan)?.id, "top-e90", "az \(az) el \(el)")
            }
            XCTAssertNil(Coverage.match(azimuthDeg: az, elevationDeg: 74.9, plan: plan), "az \(az)")
        }
        // 横の方向：方位 ±15°・仰角 ±12°。
        XCTAssertEqual(Coverage.match(azimuthDeg: 14, elevationDeg: 3, plan: plan)?.id, "a000-e15")
        XCTAssertEqual(Coverage.match(azimuthDeg: 346, elevationDeg: 27, plan: plan)?.id, "a000-e15")
        XCTAssertEqual(Coverage.match(azimuthDeg: 100, elevationDeg: 15, plan: plan)?.id, "a090-e15")
        XCTAssertNil(Coverage.match(azimuthDeg: 45, elevationDeg: 15, plan: plan))
        XCTAssertNil(Coverage.match(azimuthDeg: 0, elevationDeg: 28, plan: plan))
        XCTAssertNil(Coverage.match(azimuthDeg: 0, elevationDeg: 50, plan: plan))
        // 方位が分からない・壊れた値では当てはめない。
        XCTAssertNil(Coverage.match(azimuthDeg: nil, elevationDeg: 90, plan: plan))
        XCTAssertNil(Coverage.match(azimuthDeg: .nan, elevationDeg: 90, plan: plan))
        XCTAssertNil(Coverage.match(azimuthDeg: 0, elevationDeg: .nan, plan: plan))
        // 真上は正面の 1 枚目の方向にならない。
        XCTAssertEqual(Coverage.frontTarget(plan: plan, elevationDeg: 90)?.id, "a000-e15")
    }

    /// ちょうど真上（水平の成分が 0）でも NaN にならず、真上に当てはまる。
    func testExactlyOverheadHasNoNaN() throws {
        let objectToWorld = try XCTUnwrap(Geometry.objectToWorld(basePoint: base, frontCameraPosition: base + SIMD3(0, 0.1, 0.4)))
        let center = Geometry.objectCenter(basePoint: base, heightM: height)
        let overhead = center + SIMD3(0, 0.4, 0)
        let az = Geometry.azimuth(cameraPosition: overhead, objectToWorld: objectToWorld)
        XCTAssertTrue(az.isFinite)
        let ed = Geometry.elevationAndDistance(cameraPosition: overhead, basePoint: base, heightM: height)
        XCTAssertEqual(ed.elevationDeg, 90, accuracy: 1e-9)
        let sides: Set<String> = ["a000-e15", "a090-e15", "a180-e15", "a270-e15"]
        var route = CaptureRoute()
        route.update(azimuthDeg: az, elevationDeg: ed.elevationDeg, plan: plan, covered: sides)
        let context = DirectionContext.make(cameraPosition: overhead, basePoint: base, heightM: height, objectToWorld: objectToWorld,
                                            plan: plan, covered: sides, route: route)
        XCTAssertEqual(context.matchedTarget?.id, "top-e90")
        XCTAssertTrue(context.isOnUncoveredTarget)
        XCTAssertEqual(context.nextTarget?.id, "top-e90")
        XCTAssertEqual(context.travelDeg, 0)
        XCTAssertTrue(context.elevationDeg.isFinite && context.distanceM.isFinite)
        XCTAssertFalse(context.guidance.lowercased().contains("nan"), context.guidance)

        // 写真の記録も真上に当てはまり、方向は確定する。
        var session = Fixtures.session(base: base)
        session.directionPlan = plan
        session.referenceFrames[0].objectToWorld = Matrix4x4(objectToWorld)
        let photo = PhotoRecorder.makePhoto(in: &session, photoId: "11111111-0000-4000-8000-000000000005", sequence: 5,
                                            frame: Fixtures.frame(cameraToWorld: Fixtures.lookAt(from: overhead, to: center)),
                                            context: Fixtures.context(ref: "ref-1"))
        XCTAssertTrue(photo.direction.confirmed)
        XCTAssertEqual(photo.direction.targetId, "top-e90")
        XCTAssertTrue(photo.direction.azimuthDeg?.isFinite ?? false)
        XCTAssertEqual(photo.direction.elevationDeg ?? 0, 90, accuracy: 1e-3)

        // 真下を向いていても、作品は画面に収まり、マスクの切り抜きは作品のまわり。
        let cylinder = ObjectCylinder(basePoint: base, radiusM: 0.08, heightM: height)
        let projection = Projection.evaluate(cylinder: cylinder, camera: Fixtures.camera(from: overhead, to: center))
        XCTAssertEqual(projection.status, .inside)
        let crop = MaskCropPlanner.plan(photo: photo, session: session)
        XCTAssertEqual(crop.source, .projectedCylinder)
        let object = try XCTUnwrap(crop.object)
        XCTAssertEqual(object.boundingBox.midX, 960, accuracy: 5)
        XCTAssertEqual(object.boundingBox.midY, 720, accuracy: 5)
        XCTAssertLessThanOrEqual(Double(crop.region.x), object.boundingBox.minX)
        XCTAssertGreaterThanOrEqual(Double(crop.region.maxY), object.boundingBox.maxY)
    }

    // MARK: 撮る順

    func testRouteFrontThenNearerSideAroundThenTop() {
        let front: Set<String> = ["a000-e15"]
        // 向きが分からないとき：近い方の横。同じ近さなら一覧の順（右）。
        XCTAssertEqual(CaptureRoute().next(plan: plan, covered: front, currentAzimuthDeg: 0)?.target.id, "a090-e15")
        XCTAssertEqual(CaptureRoute().next(plan: plan, covered: front, currentAzimuthDeg: 5)?.target.id, "a090-e15")
        XCTAssertEqual(CaptureRoute().next(plan: plan, covered: front, currentAzimuthDeg: 352)?.target.id, "a270-e15")

        // 右へ歩く：正面 → 右 → 後ろ → 左 → 真上。
        XCTAssertEqual(walkOrder(direction: 1), ["a000-e15", "a090-e15", "a180-e15", "a270-e15", "top-e90"])
        // 左へ歩く：正面 → 左 → 後ろ → 右 → 真上。
        XCTAssertEqual(walkOrder(direction: -1), ["a000-e15", "a270-e15", "a180-e15", "a090-e15", "top-e90"])
    }

    /// 正面を撮ったあと、`direction` の向きに 1° ずつ歩き、次の方向に着いたら撮る（真上は持ち上げて撮る）。
    private func walkOrder(direction: Double) -> [String] {
        var covered: Set<String> = ["a000-e15"]
        var order = ["a000-e15"]
        var route = CaptureRoute()
        var az = 0.0
        for _ in 0..<2000 {
            route.update(azimuthDeg: Geometry.normalizeDegrees(az), elevationDeg: 15, plan: plan, covered: covered)
            guard let next = route.next(plan: plan, covered: covered, currentAzimuthDeg: Geometry.normalizeDegrees(az)) else { break }
            if next.target.anyAzimuth {
                XCTAssertEqual(next.travelDeg, 0)
                XCTAssertEqual(Coverage.match(azimuthDeg: Geometry.normalizeDegrees(az), elevationDeg: 88, plan: plan)?.id, next.target.id)
                covered.insert(next.target.id)
                order.append(next.target.id)
                continue
            }
            if Geometry.angleDistance(Geometry.normalizeDegrees(az), next.target.azimuthDeg) < 1 {
                covered.insert(next.target.id)
                order.append(next.target.id)
                continue
            }
            // はじめの一歩は決めた向きに。あとは案内の向き（travelDeg）へ。
            let sign = route.walk == nil ? direction : (next.travelDeg >= 0 ? 1.0 : -1.0)
            az += sign
        }
        return order
    }

    /// ほぼ真上の方位は定まらないので、歩く向きに数えない。
    func testOverheadSamplesDoNotSetWalkDirection() {
        var route = CaptureRoute()
        for (i, az) in stride(from: 0.0, to: 40, by: 2).enumerated() {
            route.update(azimuthDeg: az, elevationDeg: 80 + Double(i % 3), plan: plan, covered: [])
        }
        XCTAssertNil(route.walk)
        route.update(azimuthDeg: .nan, elevationDeg: 15, plan: plan, covered: [])
        XCTAssertNil(route.walk)
        for az in stride(from: 0.0, through: 12, by: 1) {
            route.update(azimuthDeg: az, elevationDeg: 15, plan: plan, covered: [])
        }
        XCTAssertEqual(route.walk, .increasing)
    }

    // MARK: 案内

    func testTopGuidance() throws {
        let objectToWorld = try XCTUnwrap(Geometry.objectToWorld(basePoint: base, frontCameraPosition: base + SIMD3(0, 0.1, 0.4)))
        let sides: Set<String> = ["a000-e15", "a090-e15", "a180-e15", "a270-e15"]
        func context(az: Double, el: Double, covered: Set<String>) -> DirectionContext {
            DirectionContext.make(cameraPosition: Fixtures.position(base: base, height: height, azimuth: az, elevation: el, distance: 0.45),
                                  basePoint: base, heightM: height, objectToWorld: objectToWorld, plan: plan, covered: covered)
        }
        // 横が終わって低い位置にいる：真上の段を始める案内（回る向きは言わない）。
        let start = context(az: 270, el: 15, covered: sides)
        XCTAssertEqual(start.nextTarget?.id, "top-e90")
        XCTAssertTrue(start.nextBandIsNew)
        XCTAssertEqual(start.guidance, DirectionContext.topMessage + "（高さ 15° → 75° 以上）")
        XCTAssertEqual(DirectionContext.topMessage, "最後に真上から撮ります。iPhone を作品の真上に持ち上げて、画面を下に向けてください")
        XCTAssertEqual(DirectionContext.bandStartMessage(plan.targets[4], fromElevationDeg: 15), DirectionContext.topMessage)
        XCTAssertFalse(start.guidance.contains("回って"))
        // 途中（60°）：高さだけ。
        let rising = context(az: 200, el: 60, covered: sides)
        XCTAssertTrue(rising.guidance.hasPrefix(DirectionContext.topMessage), rising.guidance)
        XCTAssertTrue(rising.guidance.contains("75° 以上"), rising.guidance)
        // 75° 以上ならどの方位でも撮れる。
        for az in [0.0, 95, 181, 300] {
            let above = context(az: az, el: 78, covered: sides)
            XCTAssertTrue(above.isOnUncoveredTarget, "az \(az)")
            XCTAssertEqual(above.guidance, "真上：この方向で撮影できます")
        }
        // 横の案内は名前付き。
        let next = context(az: 0, el: 15, covered: ["a000-e15"])
        XCTAssertEqual(next.nextTarget?.id, "a090-e15")
        XCTAssertTrue(next.guidance.contains("次は右です。もう少し右へ回ってください（あと 90°）"), next.guidance)
        // 真上の近くで横が残っているときは、回る向きより先に高さを下げてもらう。
        let lost = context(az: 10, el: 80, covered: ["a000-e15", "top-e90"])
        XCTAssertFalse(lost.guidance.contains("回って"), lost.guidance)
        XCTAssertTrue(lost.guidance.contains("低い位置"), lost.guidance)
    }

    // MARK: 進み具合

    func testProgressAndReadinessCountFive() throws {
        var session = Fixtures.session(base: base)
        session.directionPlan = plan
        let objectToWorld = try XCTUnwrap(Geometry.objectToWorld(basePoint: base, frontCameraPosition: base + SIMD3(0, 0.1, 0.4)))
        session.referenceFrames[0].objectToWorld = Matrix4x4(objectToWorld)
        let center = Geometry.objectCenter(basePoint: base, heightM: height)
        let shots: [(Double, Double)] = [(0, 15), (92, 14), (178, 18), (268, 12), (140, 86)]
        for (i, shot) in shots.enumerated() {
            let position = Fixtures.position(base: base, height: height, azimuth: shot.0, elevation: shot.1, distance: 0.45)
            // Fixtures.position は作品座標が単位行列のとき。正面の向きを合わせた objectToWorld で世界へ。
            let world = objectToWorld * SIMD4(position - base, 1)
            let camera = SIMD3(world.x, world.y, world.z)
            var photo = PhotoRecorder.makePhoto(in: &session, photoId: String(format: "11111111-0000-4000-8000-%012d", i + 1), sequence: i + 1,
                                                frame: Fixtures.frame(cameraToWorld: Fixtures.lookAt(from: camera, to: center)),
                                                context: Fixtures.context(ref: "ref-1"))
            photo.mask = MaskInfo(status: .confirmed)
            session.photos.append(photo)
            let progress = Coverage.progress(in: session, referenceFrameId: "ref-1")
            XCTAssertEqual(progress.doneCount, i + 1)
            XCTAssertEqual(progress.totalCount, 5)
        }
        XCTAssertEqual(session.photos.map(\.direction.targetId), ["a000-e15", "a090-e15", "a180-e15", "a270-e15", "top-e90"])
        let readiness = Readiness.make(session: session)
        XCTAssertTrue(readiness.isComplete)
        XCTAssertEqual(readiness.directionSummary, "方向 5/5 そろいました")
        XCTAssertEqual(readiness.progress.bandSummary, "15°: 4/4 · 90°: 1/1")
        XCTAssertTrue(session.photos.allSatisfy { ($0.direction.azimuthDeg ?? .nan).isFinite })
    }

    // MARK: 歩いて撮る

    /// 判定（QualityEvaluator）と自動撮影を通して、正面（手で撮る）のあと 右 → 後ろ → 左 → 真上 が重複なく撮れる。
    /// 真上は、横がそろったら持ち上げて（仰角を 90° まで上げて）撮る。収まりは真下を向いても ok。
    func testWalkSimulationCapturesFiveInOrder() throws {
        let base = SIMD3<Double>(0, 0, 0)
        let radius = 0.08, distance = 0.45, dt = 1.0 / 8.0
        let objectToWorld = try XCTUnwrap(Geometry.objectToWorld(basePoint: base, frontCameraPosition: SIMD3(0, 0, 1)))
        let cylinder = ObjectCylinder(basePoint: base, radiusM: radius, heightM: height)
        let center = Geometry.objectCenter(basePoint: base, heightM: height)
        var evaluator = QualityEvaluator(thresholds: QualityThresholds.default.adapted(to: plan))
        var route = CaptureRoute()
        var covered: Set<String> = ["a000-e15"]
        var captured = ["a000-e15"]
        var az = 0.0, el = 15.0
        var lastAz = az, lastEl = el
        var inFlight: (target: String, remaining: Int)?
        for i in 0..<3000 {
            let t = Double(i) * dt
            let position = Fixtures.position(base: base, height: height, azimuth: az, elevation: el, distance: distance)
            let projection = Projection.evaluate(cylinder: cylinder, camera: Fixtures.camera(from: position, to: center))
            XCTAssertEqual(projection.status, .inside, "収まらない（方位 \(az)・高さ \(el)）")
            let measuredAz = Geometry.azimuth(cameraPosition: position, objectToWorld: objectToWorld)
            XCTAssertTrue(measuredAz.isFinite)
            let measuredEl = Geometry.elevationAndDistance(cameraPosition: position, basePoint: base, heightM: height).elevationDeg
            route.update(azimuthDeg: measuredAz, elevationDeg: measuredEl, plan: plan, covered: covered)
            let direction = DirectionContext.make(cameraPosition: position, basePoint: base, heightM: height, objectToWorld: objectToWorld,
                                                  plan: plan, covered: covered, route: route)
            let turned = Geometry.radians(Geometry.angleDistance(lastAz, az) + abs(el - lastEl)) / dt
            let assessment = evaluator.evaluate(LiveFrameSample(
                timestamp: t, trackingState: .normal, reference: .ready, projection: projection, direction: direction,
                angularSpeed: turned, linearSpeed: turned * distance, meanLuma: 0.5, sharpness: 0.01,
                ambientIntensity: 1000, exposureDuration: 0.01, captureInFlight: inFlight != nil
            ))
            if var flight = inFlight {
                flight.remaining -= 1
                if flight.remaining == 0 {
                    covered.insert(flight.target)
                    evaluator.noteCapture(at: t)
                    inFlight = nil
                } else {
                    inFlight = flight
                }
            } else if assessment.canAutoCapture, let id = assessment.autoTargetId {
                XCTAssertFalse(covered.contains(id), "同じ方向を 2 回撮った：\(id)")
                captured.append(id)
                inFlight = (id, 3)
            }
            if covered.count == plan.targets.count { break }
            guard let next = direction.nextTarget else { continue }
            lastAz = az
            lastEl = el
            // 真上は回らずに持ち上げる。横は案内の向きへ 2°/回。
            if !next.anyAzimuth {
                let travel = direction.travelDeg ?? 0
                if abs(travel) > 1 { az = Geometry.normalizeDegrees(az + (travel >= 0 ? 2 : -2)) }
            }
            el += max(-3, min(3, next.elevationDeg - el))
        }
        XCTAssertEqual(captured, ["a000-e15", "a090-e15", "a180-e15", "a270-e15", "top-e90"])
        XCTAssertEqual(covered.count, 5)
    }
}

/// 切り抜きで撮り直すかの決まり（一覧ごと）：ai5 ははっきり失敗したときだけ、方向の多い一覧は ok 以外すべて。
final class MaskRetakePolicyTests: XCTestCase {
    private var sequence = 0

    private func photo(target: String, mask: MaskStatus, check: MaskCheck? = nil) -> Photo {
        sequence += 1
        var m = MaskInfo(status: mask)
        m.check = check
        return Photo(
            photoId: String(format: "00000000-0000-4000-8000-%012d", sequence), sequence: sequence, capturedAt: Date(), trigger: .auto, referenceFrameId: "ref-1",
            image: ImageInfo(file: "photos/x.jpg", width: 1, height: 1, displayRotationDegClockwise: 90, deviceOrientation: "portrait"),
            camera: CameraInfo(arFrameTimestamp: 0, cameraToWorld: Matrix4x4(matrix_identity_double4x4), intrinsics: Matrix3x3(matrix_identity_double3x3), intrinsicsResolution: PixelSize(width: 1, height: 1), exposureDurationS: nil, exposureOffsetEV: nil, trackingState: .normal, trackingReason: nil),
            direction: DirectionInfo(confirmed: true, unconfirmedReason: nil, targetId: target, azimuthDeg: 0, elevationDeg: 15, distanceM: 0.4),
            quality: PhotoQuality(live: .unknown), mask: m
        )
    }

    private func suspicious(_ reasons: [MaskCheckReason], inside: Double? = 0.8) -> MaskCheck {
        MaskCheck(status: .suspicious, reasons: reasons, insideSilhouetteRatio: inside)
    }

    func testPolicyIsPerPlan() {
        XCTAssertEqual(DirectionPlanPreset.ai5.plan.retakePolicy, .lenient)
        XCTAssertEqual(DirectionPlanPreset.flat1.plan.retakePolicy, .notUsed)
        XCTAssertEqual(DirectionPlanPreset.free.plan.retakePolicy, .notUsed)
        for preset in DirectionPlanPreset.allCases where preset != .ai5 && preset != .flat1 && preset != .free {
            XCTAssertEqual(preset.plan.retakePolicy, .strict, preset.rawValue)
        }
        // 保存してある一覧（id で決まる）でも同じ。
        XCTAssertEqual(DirectionPlan(id: "ai5", targets: []).retakePolicy, .lenient)
        XCTAssertEqual(DirectionPlan(id: "custom", targets: []).retakePolicy, .strict)
    }

    func testLenientRetakesOnlyClearFailures() {
        let cases: [(MaskStatus, MaskCheck?, lenient: MaskOutcome, strict: MaskOutcome)] = [
            (.confirmed, nil, .good, .good),
            (.candidate, MaskCheck(status: .ok, reasons: []), .good, .good),
            (.candidate, nil, .pending, .pending),
            (.processing, nil, .pending, .pending),
            (.noObject, nil, .bad, .bad),
            (.failed, nil, .bad, .bad),
            // 端に届いている・中心からずれている・広すぎる・作品の外に少しはみ出す：ai5 では撮り直さない。
            (.candidate, suspicious([.touchesCropEdge]), .good, .bad),
            (.candidate, suspicious([.offCenter]), .good, .bad),
            (.candidate, suspicious([.tooLarge, .touchesCropEdge]), .good, .bad),
            (.candidate, suspicious([.outsideObject], inside: 0.8), .good, .bad),
            (.candidate, MaskCheck.unknown, .good, .bad),
            // 作品が写っていない・マスクの大半が作品の外：撮り直す。
            (.candidate, suspicious([.empty], inside: nil), .bad, .bad),
            (.candidate, suspicious([.tooSmall]), .bad, .bad),
            (.candidate, suspicious([.outsideObject, .offCenter], inside: 0.3), .bad, .bad),
        ]
        for (i, c) in cases.enumerated() {
            let p = photo(target: "a000-e15", mask: c.0, check: c.1)
            XCTAssertEqual(p.maskOutcome(policy: .lenient), c.lenient, "case \(i)")
            XCTAssertEqual(p.maskOutcome(policy: .strict), c.strict, "case \(i)")
            XCTAssertEqual(p.maskOutcome, c.strict, "case \(i)")
        }
    }

    func testProgressUsesThePlansPolicy() {
        let borderline = photo(target: "a000-e15", mask: .candidate, check: suspicious([.touchesCropEdge, .offCenter]))
        let missing = photo(target: "a090-e15", mask: .noObject)
        let ai5 = Coverage.progress(photos: [borderline, missing], referenceFrameId: "ref-1", plan: DirectionPlanPreset.ai5.plan)
        XCTAssertEqual(ai5.state(of: "a000-e15"), .done)
        XCTAssertEqual(ai5.state(of: "a090-e15"), .retake)
        XCTAssertEqual(ai5.doneCount, 1)

        var ring = borderline
        ring.direction.targetId = "a000-e20"
        let strict = Coverage.progress(photos: [ring], referenceFrameId: "ref-1", plan: DirectionPlanPreset.ring8.plan)
        XCTAssertEqual(strict.state(of: "a000-e20"), .retake)
    }
}
