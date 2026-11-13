@testable import CaptureCore
import simd
import XCTest

// Mac の写真測量（PhotogrammetrySession）用の 48 方向：一覧・id・撮る順の案内・歩いて 1 周したときの撮れ方。

final class PhotogrammetryPlanTests: XCTestCase {
    let plan = DirectionPlanPreset.photogrammetry.plan

    func testPresetHasThreeBandsAnd48UniqueTargets() {
        XCTAssertEqual(plan.id, "photogrammetry")
        XCTAssertEqual(plan.targets.count, 48)
        XCTAssertEqual(Set(plan.targets.map(\.id)).count, 48)
        let bands = plan.bands
        XCTAssertEqual(bands.map(\.elevationDeg), [20, 45, 70])
        XCTAssertEqual(bands.map(\.targets.count), [24, 16, 8])
        XCTAssertEqual(bands[0].targets.map(\.azimuthDeg), stride(from: 0.0, to: 360, by: 15).map { $0 })
        XCTAssertEqual(bands[1].targets.map(\.azimuthDeg), (0..<16).map { Double($0) * 22.5 })
        XCTAssertEqual(bands[2].targets.map(\.azimuthDeg), (0..<8).map { Double($0) * 45 })
        XCTAssertEqual(bands.map { $0.targets[0].azimuthToleranceDeg }, [7, 10, 20])
        XCTAssertTrue(plan.targets.allSatisfy { $0.elevationToleranceDeg == 10 })
        // 一覧の順は低い段から（段の中は方位の順）。
        XCTAssertEqual(plan.targets.prefix(2).map(\.id), ["a000-e20", "a015-e20"])
        XCTAssertEqual(plan.targets[24...27].map(\.id), ["a000-e45", "a022.5-e45", "a045-e45", "a067.5-e45"])
        XCTAssertEqual(plan.targets.last?.id, "a315-e70")
        XCTAssertTrue(plan.isDense)
        XCTAssertFalse(DirectionPlanPreset.ring8.plan.isDense)
        XCTAssertFalse(DirectionPlanPreset.ring8plusHigh.plan.isDense)
        XCTAssertEqual(DirectionPlanPreset.photogrammetry.summary, "Mac で写真から 3D を作る用。48 枚・約 3〜5 分")
    }

    func testTargetIdFormatIsStable() {
        XCTAssertEqual(DirectionTarget.makeId(azimuthDeg: 22.5, elevationDeg: 45), "a022.5-e45")
        XCTAssertEqual(DirectionTarget.makeId(azimuthDeg: 337.5, elevationDeg: 45), "a337.5-e45")
        XCTAssertEqual(DirectionTarget.makeId(azimuthDeg: 45, elevationDeg: 70), "a045-e70")
        XCTAssertEqual(DirectionTarget.makeId(azimuthDeg: 359.97, elevationDeg: 20), "a000-e20")
        XCTAssertEqual(DirectionTarget.makeId(azimuthDeg: -15, elevationDeg: 20), "a345-e20")
        XCTAssertEqual(DirectionTarget.makeId(azimuthDeg: 7.5, elevationDeg: -5), "a007.5-em05")
        // 前の一覧の id は変わらない。
        XCTAssertEqual(DirectionPlanPreset.ring8.plan.targets.map(\.id).first, "a000-e20")
        // 方位を問わない方向（真上）は `top-e90` の形。
        let pattern = try! NSRegularExpression(pattern: "^(a[0-9]{3}(\\.[0-9])?|top)-em?[0-9]{2}$")
        for id in DirectionPlanPreset.allCases.flatMap({ $0.plan.targets.map(\.id) }) {
            XCTAssertNotNil(pattern.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)), id)
        }
        XCTAssertEqual(DirectionContext.label(plan.target(id: "a022.5-e45")!), "22.5°・高さ 45°")
        XCTAssertEqual(DirectionContext.label(plan.target(id: "a015-e20")!), "15°")
    }

    func testTolerancesDoNotOverlap() {
        // 隣の方向の真ん中はどちらにも入らない。段の間（30〜35°、55〜60°）もどれにも入らない。
        XCTAssertNil(Coverage.match(azimuthDeg: 7.5, elevationDeg: 20, plan: plan))
        XCTAssertEqual(Coverage.match(azimuthDeg: 6.9, elevationDeg: 20, plan: plan)?.id, "a000-e20")
        XCTAssertEqual(Coverage.match(azimuthDeg: 8.1, elevationDeg: 28, plan: plan)?.id, "a015-e20")
        XCTAssertNil(Coverage.match(azimuthDeg: 11.25, elevationDeg: 45, plan: plan))
        XCTAssertEqual(Coverage.match(azimuthDeg: 30, elevationDeg: 50, plan: plan)?.id, "a022.5-e45")
        XCTAssertNil(Coverage.match(azimuthDeg: 0, elevationDeg: 32, plan: plan))
        XCTAssertNil(Coverage.match(azimuthDeg: 0, elevationDeg: 57, plan: plan))
        XCTAssertEqual(Coverage.match(azimuthDeg: 30, elevationDeg: 75, plan: plan)?.id, "a045-e70")
    }

    func testCooldownDependsOnPlan() {
        let t = QualityThresholds.default
        XCTAssertEqual(t.autoCaptureCooldown(for: plan), 0.7)
        XCTAssertEqual(t.autoCaptureCooldown(for: DirectionPlanPreset.ring8.plan), 1.2)
        XCTAssertEqual(t.adapted(to: plan).autoCaptureCooldown, 0.7)
        XCTAssertEqual(t.adapted(to: plan).stableDuration, t.stableDuration)
    }

    func testBandProgressSummary() {
        var progress = CoverageProgress.empty(plan: plan)
        for i in 0..<18 { progress.targets[i].state = .done }
        progress.targets[18].state = .checking
        XCTAssertEqual(progress.bandSummary, "20°: 18/24 · 45°: 0/16 · 70°: 0/8")
        XCTAssertEqual(progress.bands[0].coveredCount, 19)
        XCTAssertNil(CoverageProgress.empty(plan: DirectionPlanPreset.ring8.plan).bandSummary)
    }
}

final class CaptureRouteTests: XCTestCase {
    let plan = DirectionPlanPreset.photogrammetry.plan
    var lowIds: [String] { plan.bands[0].targets.map(\.id) }

    /// 方位を from から to まで 1° ずつ動かして、歩いている向きを決める。
    private func walk(_ route: inout CaptureRoute, from: Double, to: Double, covered: Set<String> = []) {
        let step: Double = to >= from ? 1 : -1
        var az = from
        while (step > 0 && az <= to) || (step < 0 && az >= to) {
            route.update(azimuthDeg: Geometry.normalizeDegrees(az), plan: plan, covered: covered)
            az += step
        }
    }

    func testWalkDirectionNeedsSustainedMotionAndHysteresis() {
        var route = CaptureRoute()
        walk(&route, from: 0, to: 5)
        XCTAssertNil(route.walk)
        walk(&route, from: 5, to: 12)
        XCTAssertEqual(route.walk, .increasing)
        // 少し戻った（位置を合わせ直した）だけでは向きは変わらない。
        walk(&route, from: 12, to: 0)
        XCTAssertEqual(route.walk, .increasing)
        walk(&route, from: 0, to: -12)
        XCTAssertEqual(route.walk, .decreasing)
        // 大きな飛びは数えない。
        var jump = CaptureRoute()
        jump.update(azimuthDeg: 0, plan: plan, covered: [])
        jump.update(azimuthDeg: 90, plan: plan, covered: [])
        XCTAssertNil(jump.walk)
    }

    func testNextTargetContinuesInWalkingDirection() {
        // 0〜60° を撮った。今 62°、左（方位が減る向き）へ戻りかけていても、右へ歩いてきたので次は 75°。
        let covered = Set(["a000-e20", "a015-e20", "a030-e20", "a045-e20", "a060-e20"])
        var route = CaptureRoute()
        walk(&route, from: 40, to: 62, covered: covered)
        XCTAssertEqual(route.walk, .increasing)
        let step = route.next(plan: plan, covered: covered, currentAzimuthDeg: 62)
        XCTAssertEqual(step?.target.id, "a075-e20")
        XCTAssertEqual(step?.travelDeg ?? 0, 13, accuracy: 1e-9)

        // 左へ歩いている：0° から左へ。345° を撮ったら次は 330°（15° の右側には戻らない）。
        var left = CaptureRoute()
        walk(&left, from: 10, to: -16, covered: ["a000-e20", "a345-e20"])
        XCTAssertEqual(left.walk, .decreasing)
        XCTAssertEqual(left.next(plan: plan, covered: ["a000-e20", "a345-e20"], currentAzimuthDeg: 344)?.target.id, "a330-e20")
    }

    func testMissedTargetIsLeftForTheEndOfTheLapUnlessMuchCloser() {
        // 右へ歩いて 90° を撮りそこねた。今 100°、次は前の 105°（90° は 1 周の終わりに撮る）。
        var covered = Set(lowIds.filter { ["a000-e20", "a015-e20", "a030-e20", "a045-e20", "a060-e20", "a075-e20"].contains($0) })
        var route = CaptureRoute()
        walk(&route, from: 70, to: 100, covered: covered)
        XCTAssertEqual(route.next(plan: plan, covered: covered, currentAzimuthDeg: 100)?.target.id, "a105-e20")
        // 許容の中で少し通り過ぎただけならそこ。
        XCTAssertEqual(route.next(plan: plan, covered: covered, currentAzimuthDeg: 95)?.target.id, "a090-e20")
        // 1 周の終わり：残りは 90° だけ。今 350° → 前へ 100°（右へ回る。近い向きの左ではない）。
        covered = Set(lowIds).subtracting(["a090-e20"])
        var end = CaptureRoute()
        walk(&end, from: 330, to: 350, covered: covered)
        let last = end.next(plan: plan, covered: covered, currentAzimuthDeg: 350)
        XCTAssertEqual(last?.target.id, "a090-e20")
        XCTAssertEqual(last?.travelDeg ?? 0, 100, accuracy: 1e-9)
        // 残りが後ろのすぐ近く（30°）で、前へは 330° → 戻る。
        var back = CaptureRoute()
        walk(&back, from: 100, to: 120, covered: covered)
        let backStep = back.next(plan: plan, covered: covered, currentAzimuthDeg: 120)
        XCTAssertEqual(backStep?.target.id, "a090-e20")
        XCTAssertEqual(backStep?.travelDeg ?? 0, -30, accuracy: 1e-9)
    }

    func testBandsAreFinishedInOrderAndStick() {
        var route = CaptureRoute()
        route.update(azimuthDeg: 0, plan: plan, covered: [])
        XCTAssertEqual(route.bandElevationDeg, 20)
        // 20° の段が 1 つでも残っていれば 45° へ行かない（カメラが 45° の高さにあっても）。
        let most = Set(lowIds.dropLast())
        route.update(azimuthDeg: 0, plan: plan, covered: most)
        XCTAssertEqual(route.next(plan: plan, covered: most, currentAzimuthDeg: 0)?.target.id, "a345-e20")
        // 20° がそろった → 45°。
        let low = Set(lowIds)
        route.update(azimuthDeg: 0, plan: plan, covered: low)
        XCTAssertEqual(route.bandElevationDeg, 45)
        XCTAssertEqual(route.next(plan: plan, covered: low, currentAzimuthDeg: 0)?.target.id, "a000-e45")
        // 45° の途中で 20° の撮り直しが出ても、45° を先に終える。
        let mid = Set(plan.bands[1].targets.prefix(4).map(\.id)).union(low).subtracting(["a030-e20"])
        route.update(azimuthDeg: 70, plan: plan, covered: mid)
        XCTAssertEqual(route.bandElevationDeg, 45)
        XCTAssertEqual(route.next(plan: plan, covered: mid, currentAzimuthDeg: 70)?.target.elevationDeg, 45)
        // 45° がそろった → 上の 70°、そのあとで下の 20° の撮り直し。
        let upper = Set(plan.bands[1].targets.map(\.id)).union(low).subtracting(["a030-e20"])
        route.update(azimuthDeg: 0, plan: plan, covered: upper)
        XCTAssertEqual(route.bandElevationDeg, 70)
        let top = upper.union(plan.bands[2].targets.map(\.id))
        route.update(azimuthDeg: 0, plan: plan, covered: top)
        XCTAssertEqual(route.bandElevationDeg, 20)
        XCTAssertEqual(route.next(plan: plan, covered: top, currentAzimuthDeg: 0)?.target.id, "a030-e20")
        route.update(azimuthDeg: 0, plan: plan, covered: Set(plan.targets.map(\.id)))
        XCTAssertNil(route.bandElevationDeg)
        XCTAssertNil(route.next(plan: plan, covered: Set(plan.targets.map(\.id)), currentAzimuthDeg: 0))
    }

    func testPreferredRetakeWins() {
        let route = CaptureRoute()
        XCTAssertEqual(route.next(plan: plan, covered: [], currentAzimuthDeg: 0, preferredTargetId: "a045-e70")?.target.id, "a045-e70")
    }

    func testGuidanceAnnouncesBandChangeAndRaisingThePhone() throws {
        let base = SIMD3<Double>(0, 0, 0)
        let m = try XCTUnwrap(Geometry.objectToWorld(basePoint: base, frontCameraPosition: SIMD3(0, 0, 1)))
        func context(az: Double, el: Double, covered: Set<String>, route: CaptureRoute = CaptureRoute()) -> DirectionContext {
            DirectionContext.make(
                cameraPosition: Fixtures.position(base: base, height: 0.15, azimuth: az, elevation: el, distance: 0.45),
                basePoint: base, heightM: 0.15, objectToWorld: m, plan: plan, covered: covered, route: route
            )
        }
        let low = Set(lowIds)
        var route = CaptureRoute()
        route.update(azimuthDeg: 350, plan: plan, covered: low)
        let next45 = context(az: 350, el: 20, covered: low, route: route)
        XCTAssertEqual(next45.nextTarget?.id, "a000-e45")
        XCTAssertTrue(next45.nextBandIsNew)
        XCTAssertTrue(next45.guidance.contains("次は少し上から（45°）一周します"), next45.guidance)
        // 45° を撮り始めたら、ふつうの案内（高さがずれたら高さ）。
        let started = low.union(["a000-e45"])
        let drift = context(az: 22.5, el: 30, covered: started)
        XCTAssertFalse(drift.nextBandIsNew)
        XCTAssertTrue(drift.guidance.contains("もう少し上から見下ろして"), drift.guidance)
        // 70°：スマホを上げて下に傾ける。
        let mid = low.union(plan.bands[1].targets.map(\.id))
        let next70 = context(az: 0, el: 45, covered: mid)
        XCTAssertEqual(next70.nextTarget?.id, "a000-e70")
        XCTAssertTrue(next70.guidance.contains("（70°）一周します"), next70.guidance)
        XCTAssertTrue(next70.guidance.contains("下に傾けて"), next70.guidance)
        let high = context(az: 45, el: 52, covered: mid.union(["a000-e70"]))
        XCTAssertTrue(high.guidance.contains("スマホをもっと高く上げて、下に傾けて"), high.guidance)
    }

    func testGuidanceFollowsWalkingDirectionPast180() throws {
        let base = SIMD3<Double>(0, 0, 0)
        let m = try XCTUnwrap(Geometry.objectToWorld(basePoint: base, frontCameraPosition: SIMD3(0, 0, 1)))
        // 右へ歩いてきて、残りは 90° だけ（前へ 200°）。近い向きは左だが、案内は右。
        let covered = Set(lowIds).subtracting(["a090-e20"])
        var route = CaptureRoute()
        walk(&route, from: 230, to: 250, covered: covered)
        let ctx = DirectionContext.make(
            cameraPosition: Fixtures.position(base: base, height: 0.15, azimuth: 250, elevation: 20, distance: 0.45),
            basePoint: base, heightM: 0.15, objectToWorld: m, plan: plan, covered: covered, route: route
        )
        XCTAssertEqual(ctx.nextTarget?.id, "a090-e20")
        XCTAssertEqual(ctx.travelDeg ?? 0, 200, accuracy: 1e-6)
        XCTAssertTrue(ctx.guidance.contains("右へ回ってください（あと 200°）"), ctx.guidance)
    }

    func testHighElevationInFrameMessageSaysTiltDown() {
        var e = QualityEvaluator()
        let direction = DirectionContext(azimuthDeg: 0, elevationDeg: 70, distanceM: 0.45, matchedTarget: plan.target(id: "a000-e70"),
                                         matchedTargetCovered: false, nextTarget: plan.target(id: "a000-e70"), coveredCount: 40, totalCount: 48)
        let r = e.evaluate(LiveFrameSample(
            timestamp: 0, trackingState: .normal, reference: .ready,
            projection: ProjectionResult(status: .partiallyOutside, boundingBox: nil, sizeFraction: nil, center: nil), direction: direction
        ))
        XCTAssertEqual(r.status(.inFrame), .warning)
        XCTAssertTrue(r.check(.inFrame).message.contains("下に傾けて"), r.check(.inFrame).message)
    }
}

/// 作品のまわりを歩く人をまねて、判定（QualityEvaluator）・撮影済みの方向・次の方向（CaptureRoute）を通し、
/// 48 方向が無理のない回数で、重複なく、段の順（20° → 45° → 70°）に、行ったり来たりせずに撮れることを確かめる。
final class PhotogrammetryWalkSimulationTests: XCTestCase {
    let plan = DirectionPlanPreset.photogrammetry.plan
    let base = SIMD3<Double>(0, 0, 0)
    let height = 0.15, radius = 0.08, distance = 0.45
    /// 撮影前の解析の間隔（約 8 Hz。ARFrameProcessor と同じ）。
    let dt = 1.0 / 8.0
    /// captureHighResolutionFrame から JPEG の保存が終わるまでの解析の回数（約 0.4 秒）。
    let captureSamples = 3

    struct Result {
        var captured: [DirectionTarget] = []
        var samples = 0
    }

    /// `stepDeg(i)` は i 回目の解析のあとに回る方位（度）。高さは 1 回に 2° まで動かす。
    private func simulate(stepDeg: (Int) -> Double, maxSamples: Int = 4000) throws -> Result {
        let objectToWorld = try XCTUnwrap(Geometry.objectToWorld(basePoint: base, frontCameraPosition: SIMD3(0, 0, 1)))
        let cylinder = ObjectCylinder(basePoint: base, radiusM: radius, heightM: height)
        let center = Geometry.objectCenter(basePoint: base, heightM: height)
        var evaluator = QualityEvaluator(thresholds: QualityThresholds.default.adapted(to: plan))
        var route = CaptureRoute()
        // 正面の 1 枚目は手で撮る（a000-e20）。
        var covered: Set<String> = ["a000-e20"]
        var result = Result(captured: [plan.target(id: "a000-e20")!])
        var az = 0.0, el = 20.0
        var inFlight: (target: String, remaining: Int)?
        var lastAz = az, lastEl = el

        for i in 0..<maxSamples {
            let t = Double(i) * dt
            let position = Fixtures.position(base: base, height: height, azimuth: az, elevation: el, distance: distance)
            let camera = Fixtures.camera(from: position, to: center)
            let projection = Projection.evaluate(cylinder: cylinder, camera: camera)
            let measuredAz = Geometry.azimuth(cameraPosition: position, objectToWorld: objectToWorld)
            route.update(azimuthDeg: measuredAz, plan: plan, covered: covered)
            let direction = DirectionContext.make(
                cameraPosition: position, basePoint: base, heightM: height, objectToWorld: objectToWorld,
                plan: plan, covered: covered, route: route
            )
            let turned = Geometry.radians(Geometry.angleDistance(lastAz, az) + abs(el - lastEl)) / dt
            let assessment = evaluator.evaluate(LiveFrameSample(
                timestamp: t, trackingState: .normal, reference: .ready, projection: projection, direction: direction,
                angularSpeed: turned, linearSpeed: turned * distance, meanLuma: 0.5, sharpness: 0.01,
                ambientIntensity: 1000, exposureDuration: 0.01, captureInFlight: inFlight != nil
            ))
            XCTAssertEqual(projection.status, .inside, "作品が画面に収まらない（方位 \(az)・高さ \(el)）")

            if var flight = inFlight {
                flight.remaining -= 1
                if flight.remaining == 0 {
                    // 保存が終わった：確認中（撮ったとみなす）になり、待ち時間を数え始める。
                    covered.insert(flight.target)
                    evaluator.noteCapture(at: t)
                    inFlight = nil
                } else {
                    inFlight = flight
                }
            } else if assessment.canAutoCapture, let id = assessment.autoTargetId {
                XCTAssertFalse(covered.contains(id), "同じ方向を 2 回撮った：\(id)")
                result.captured.append(plan.target(id: id)!)
                inFlight = (id, captureSamples)
            }
            result.samples = i + 1
            if covered.count == plan.targets.count { break }

            // 歩く：案内の向き（travelDeg）へ止まらずに回り、高さは次の方向の高さへ。
            guard let next = direction.nextTarget else { continue }
            lastAz = az
            lastEl = el
            let travel = direction.travelDeg ?? Geometry.signedAngleDifference(from: measuredAz, to: next.azimuthDeg)
            let sign: Double = travel >= 0 ? 1 : -1
            az = Geometry.normalizeDegrees(az + sign * stepDeg(i))
            let dEl = next.elevationDeg - el
            el += max(-2, min(2, dEl))
        }
        return result
    }

    private func assertGoodPass(_ r: Result, maxSamples: Int, file: StaticString = #filePath, line: UInt = #line) {
        let ids = r.captured.map(\.id)
        XCTAssertEqual(ids.count, 48, "撮れた方向 \(ids.count)/48（\(r.samples) 回）", file: file, line: line)
        XCTAssertEqual(Set(ids).count, ids.count, "重複", file: file, line: line)
        XCTAssertLessThanOrEqual(r.samples, maxSamples, "時間がかかりすぎ（\(r.samples) 回 ≈ \(Double(r.samples) / 8) 秒）", file: file, line: line)
        // 段の順（20 → 45 → 70）。
        let elevations = r.captured.map(\.elevationDeg)
        XCTAssertEqual(elevations, elevations.sorted(), "段の順が違う", file: file, line: line)
        // 段の中では、いつも同じ向き（右回り）に進む（行ったり来たりしない）。
        for (a, b) in zip(r.captured, r.captured.dropFirst()) where a.elevationDeg == b.elevationDeg {
            let d = Geometry.signedAngleDifference(from: a.azimuthDeg, to: b.azimuthDeg)
            XCTAssertGreaterThan(d, 0, "\(a.id) → \(b.id) で戻った", file: file, line: line)
        }
    }

    func testSteadyWalkAt1DegreePerSample() throws {
        let r = try simulate { _ in 1 }
        // 3 周 ≈ 1,080° ÷ 1°/回 ＋ 段の移り。実際は約 1,030 回（約 2 分 10 秒。止まらずに歩いた場合）。
        assertGoodPass(r, maxSamples: 1300)
    }

    func testSteadyWalkAt2DegreesPerSample() throws {
        // 実際は約 690 回（約 1 分 30 秒）。15° 間隔・±7° の段で、待ち時間 0.7 秒でも通り過ぎない速さの上限。
        let r = try simulate { _ in 2 }
        assertGoodPass(r, maxSamples: 850)
    }

    func testUnevenWalkBetween1And2DegreesPerSample() throws {
        let r = try simulate { i in [1.0, 1.5, 2.0, 1.25, 1.75][i % 5] }
        assertGoodPass(r, maxSamples: 1050)
    }
}
