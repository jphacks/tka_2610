import CaptureCore
import Foundation
import simd
import XCTest

/// 決まった乱数（テストを毎回同じにする）。
private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 平均 0・標準偏差 sigma の正規分布。
    mutating func gaussian(_ sigma: Double) -> Double {
        let u1 = max(1e-12, Double.random(in: 0..<1, using: &self)), u2 = Double.random(in: 0..<1, using: &self)
        return sigma * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

final class FeaturePointSurfaceTests: XCTestCase {
    /// カメラは高さ 0.35 m、作品の足もと (0, 0, -0.30)（机の高さ 0）を斜め上から見る。
    let camera = SIMD3<Double>(0, 0.35, 0)
    let foot = SIMD3<Double>(0, 0, -0.30)
    var ray: Ray { Ray(origin: camera, direction: foot - camera) }

    /// 中心のまわり（半径 radius の円の中）の、高さ y の面の点（高さに正規分布の誤差）。
    private func plane(_ n: Int, y: Double, center: SIMD3<Double>, radius: Double, sigma: Double, rng: inout SeededRandom) -> [SIMD3<Double>] {
        (0..<n).map { _ in
            let a = Double.random(in: 0..<(2 * .pi), using: &rng), r = radius * Double.random(in: 0..<1, using: &rng).squareRoot()
            return SIMD3(center.x + r * cos(a), y + rng.gaussian(sigma), center.z + r * sin(a))
        }
    }

    func testFindsTableHeightFromNoisyPoints() throws {
        var rng = SeededRandom(state: 1)
        let points = plane(80, y: 0.012, center: SIMD3(foot.x, 0.012, foot.z), radius: 0.06, sigma: 0.003, rng: &rng)
        let search = FeaturePointSurfaceEstimator.search(points: points, ray: ray)
        let estimate = try XCTUnwrap(search.estimate)
        XCTAssertEqual(estimate.heightY, 0.012, accuracy: 0.002)
        XCTAssertGreaterThanOrEqual(estimate.supportPoints, 40)
        XCTAssertLessThan(estimate.spreadM, 0.005)
        XCTAssertEqual(estimate.level, .high)
        XCTAssertEqual(search.progress, 1)
    }

    func testTooFewPointsIsNotASurface() {
        var rng = SeededRandom(state: 2)
        let points = plane(6, y: 0, center: foot, radius: 0.05, sigma: 0.002, rng: &rng)
        let search = FeaturePointSurfaceEstimator.search(points: points, ray: ray)
        XCTAssertNil(search.estimate)
        XCTAssertEqual(search.bestSupport, 6)
        XCTAssertEqual(search.progress, 0.5, accuracy: 1e-9)  // 6 / 12
    }

    func testScatteredHeightsAreRejected() {
        // 作品の側面のように、高さが一様に散らばった点（面ではない）。
        var rng = SeededRandom(state: 3)
        let points = (0..<200).map { _ in
            SIMD3(Double.random(in: -0.04...0.04, using: &rng), Double.random(in: 0...0.12, using: &rng), foot.z + Double.random(in: -0.04...0.04, using: &rng))
        }
        XCTAssertNil(FeaturePointSurfaceEstimator.search(points: points, ray: ray).estimate)
    }

    func testFloorAndTablePrefersTheNearerTable() throws {
        // 机の高さ 0（作品のまわり）と、ずっと下の床 −0.72（線の先の、机の縁の向こう）。床の点の方が多い。
        var rng = SeededRandom(state: 4)
        var points = plane(30, y: 0, center: foot, radius: 0.05, sigma: 0.003, rng: &rng)
        let floorCenter = camera + (foot - camera) * ((camera.y + 0.72) / camera.y)
        points += plane(60, y: -0.72, center: floorCenter, radius: 0.2, sigma: 0.004, rng: &rng)
        let estimate = try XCTUnwrap(FeaturePointSurfaceEstimator.search(points: points, ray: ray).estimate)
        XCTAssertEqual(estimate.heightY, 0, accuracy: 0.003)
    }

    func testOutliersDoNotMoveTheTable() throws {
        var rng = SeededRandom(state: 5)
        var points = plane(50, y: 0.004, center: foot, radius: 0.06, sigma: 0.003, rng: &rng)
        // ばらばらの外れ値（線のまわりの空間に一様に）。
        points += (0..<40).map { _ in
            let t = Double.random(in: 0.1...0.6, using: &rng)
            let p = camera + (foot - camera) * t
            return p + SIMD3(Double.random(in: -0.05...0.05, using: &rng), Double.random(in: -0.1...0.1, using: &rng), Double.random(in: -0.05...0.05, using: &rng))
        }
        // カメラより上の点（天井など）と、線から遠い点は使わない。
        points += plane(100, y: 0.8, center: SIMD3(0, 0.8, -0.3), radius: 0.2, sigma: 0.001, rng: &rng)
        points += plane(100, y: 0.1, center: SIMD3(0.6, 0.1, -0.3), radius: 0.05, sigma: 0.001, rng: &rng)
        let estimate = try XCTUnwrap(FeaturePointSurfaceEstimator.search(points: points, ray: ray).estimate)
        XCTAssertEqual(estimate.heightY, 0.004, accuracy: 0.002)
    }

    func testAccumulatesOverFramesAndForgetsOldPoints() throws {
        var rng = SeededRandom(state: 6)
        var estimator = FeaturePointSurfaceEstimator()
        // 1 フレームに 4 点ずつ（足りない）→ 10 フレームで足りる。同じ番号の点は置き換える。
        for frame in 0..<10 {
            let points = plane(4, y: 0, center: foot, radius: 0.05, sigma: 0.002, rng: &rng)
            let ids = (0..<4).map { UInt64(frame * 4 + $0) }
            estimator.add(points: points, identifiers: ids, ray: ray, timestamp: Double(frame) * 0.1)
        }
        XCTAssertEqual(estimator.bufferedCount, 40)
        XCTAssertNotNil(estimator.search(ray: ray).estimate)
        // 同じ番号で動いた点は 1 つとして数える。
        estimator.add(points: [foot], identifiers: [0], ray: ray, timestamp: 1.0)
        XCTAssertEqual(estimator.bufferedCount, 40)
        // 1.5 秒より古い点は捨てる。
        estimator.prune(now: 3.0)
        XCTAssertEqual(estimator.bufferedCount, 0)
        XCTAssertNil(estimator.search(ray: ray).estimate)
    }

    func testBufferIsBounded() {
        var config = FeaturePointSurfaceEstimator.Configuration()
        config.maxBufferedPoints = 100
        var estimator = FeaturePointSurfaceEstimator(configuration: config)
        var rng = SeededRandom(state: 7)
        for frame in 0..<5 {
            estimator.add(points: plane(60, y: 0, center: foot, radius: 0.05, sigma: 0.002, rng: &rng), identifiers: nil, ray: ray, timestamp: Double(frame) * 0.05)
        }
        XCTAssertEqual(estimator.bufferedCount, 100)
    }
}

final class BasePlacementTests: XCTestCase {
    func testRayIntersectsHorizontalPlane() throws {
        let ray = Ray(origin: SIMD3(0, 0.4, 0), direction: SIMD3(0, -1, -1))
        let p = try XCTUnwrap(ray.intersectHorizontalPlane(height: 0.1))
        XCTAssertEqual(p.x, 0, accuracy: 1e-12)
        XCTAssertEqual(p.y, 0.1, accuracy: 1e-12)
        XCTAssertEqual(p.z, -0.3, accuracy: 1e-12)
        // 面がカメラより上・線が上を向いている・遠すぎる。
        XCTAssertNil(ray.intersectHorizontalPlane(height: 0.5))
        XCTAssertNil(Ray(origin: .zero, direction: SIMD3(0, 0.2, -1)).intersectHorizontalPlane(height: -0.1))
        XCTAssertNil(Ray(origin: SIMD3(0, 0.4, 0), direction: SIMD3(0, -0.01, -1)).intersectHorizontalPlane(height: 0, maxDistance: 3))
    }

    func testManualOffsetMovesAlongTheAimRay() {
        let aim = SIMD3<Double>(0, -1, -1)  // 45° で見下ろす
        let base = SIMD3<Double>(0, 0.1, -0.3)
        let up = BasePlacement.offset(base, byHeight: 0.02, alongAimDirection: aim)
        // 2 cm 上げると、線の上で手前（カメラの側）に 2 cm 来る。
        XCTAssertEqual(up.y, 0.12, accuracy: 1e-12)
        XCTAssertEqual(up.z, -0.28, accuracy: 1e-12)
        XCTAssertEqual(up.x, 0, accuracy: 1e-12)
        // 線の上の点は、線の上に残る（ずらしたあとの高さの面と線の交点と同じ）。
        let ray = Ray(origin: SIMD3(0, 0.4, 0), direction: aim)
        let onRay = ray.intersectHorizontalPlane(height: 0.1)!
        let moved = BasePlacement.offset(onRay, byHeight: -0.035, alongAimDirection: aim)
        let expected = ray.intersectHorizontalPlane(height: 0.065)!
        XCTAssertEqual(simd_distance(moved, expected), 0, accuracy: 1e-12)
        // 0 なら変えない。
        XCTAssertEqual(BasePlacement.offset(base, byHeight: 0, alongAimDirection: aim), base)
        // 線が水平に近いとき・線が無いときは真上・真下に動かす。
        XCTAssertEqual(BasePlacement.offset(base, byHeight: 0.01, alongAimDirection: SIMD3(0, -0.1, -1)), base + SIMD3(0, 0.01, 0))
        XCTAssertEqual(BasePlacement.offset(base, byHeight: -0.01, alongAimDirection: nil), base + SIMD3(0, -0.01, 0))
    }

    private func surface(_ y: Double, support: Int = 40, confidence: Double = 0.8) -> SurfaceEstimate {
        SurfaceEstimate(heightY: y, supportPoints: support, spreadM: 0.003, confidence: confidence)
    }

    func testChoosesPlaneFeaturePointsOrPinnedHeight() throws {
        let ray = Ray(origin: SIMD3(0, 0.35, 0), direction: SIMD3(0, -0.35, -0.3))
        let table = BasePlacement.PlaneCandidate(point: ray.intersectHorizontalPlane(height: 0)!, source: .existingPlaneInfinite)
        let floor = BasePlacement.PlaneCandidate(point: ray.intersectHorizontalPlane(height: -0.72)!, source: .existingPlaneGeometry)

        // 机の平面があれば、それ（特徴点の面が近くても）。
        var c = try XCTUnwrap(BasePlacement.choose(ray: ray, plane: table, surface: surface(0.004), pinnedHeight: nil))
        XCTAssertEqual(c.source, .existingPlaneInfinite)
        XCTAssertNil(c.supportPoints)

        // 床しか見つかっていなくて、特徴点の面が十分高い → 手前の特徴点の面。
        c = try XCTUnwrap(BasePlacement.choose(ray: ray, plane: floor, surface: surface(0.0), pinnedHeight: nil))
        XCTAssertEqual(c.source, .featurePoints)
        XCTAssertEqual(c.point.y, 0, accuracy: 1e-12)
        XCTAssertEqual(c.supportPoints, 40)

        // 特徴点の面の信頼度が低ければ、床の平面のまま。
        c = try XCTUnwrap(BasePlacement.choose(ray: ray, plane: floor, surface: surface(0.0, support: 12, confidence: 0.3), pinnedHeight: nil))
        XCTAssertEqual(c.source, .existingPlaneGeometry)

        // 平面が無ければ、特徴点の面。
        c = try XCTUnwrap(BasePlacement.choose(ray: ray, plane: nil, surface: surface(0.01, confidence: 0.3), pinnedHeight: nil))
        XCTAssertEqual(c.source, .featurePoints)
        XCTAssertEqual(c.point.y, 0.01, accuracy: 1e-12)

        // iPhone の下端で測った高さは、ほかより優先。
        c = try XCTUnwrap(BasePlacement.choose(ray: ray, plane: floor, surface: surface(0.0), pinnedHeight: 0.02))
        XCTAssertEqual(c.source, .deviceEdge)
        XCTAssertEqual(c.point.y, 0.02, accuracy: 1e-12)

        // 何も無い・面がカメラより上。
        XCTAssertNil(BasePlacement.choose(ray: ray, plane: nil, surface: nil, pinnedHeight: nil))
        XCTAssertNil(BasePlacement.choose(ray: ray, plane: nil, surface: surface(0.5), pinnedHeight: nil))
    }
}

final class DeviceEdgeTests: XCTestCase {
    let profile = DeviceCameraProfile.iPhone15

    /// 縦に立てた iPhone（画面は +Z の人の方、カメラは −Z の作品の方）。ARKit のカメラの軸：
    /// +X（本体の下へ）＝ 世界の下、+Y（画面から見て本体の右）＝ 世界の +X、+Z（画面の側）＝ 世界の +Z。
    private func uprightPose(camera: SIMD3<Double>) -> simd_double4x4 {
        simd_double4x4(columns: (SIMD4(0, -1, 0, 0), SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(camera, 1)))
    }

    /// 本体の外形（角を丸めた長方形に厚み）の点を細かく並べ、一番低い点を探す（計算を別の方法で確かめる）。
    private func bruteForceLowest(_ pose: simd_double4x4) -> Double {
        let e = profile.bottomEdgeOffsetInCamera
        let r = profile.cornerRadiusM, half = profile.widthM / 2
        // 本体の中央線（下端の中央を通る）の上の、下の角の丸みの中心。
        var lowest = Double.infinity
        for face in stride(from: -1.0, through: 1.0, by: 0.5) {
            for i in 0...400 {
                // 下の辺（角の丸みを含む）を角度で回る：−90°（左の角）〜 +90°（右の角）と、まっすぐな部分。
                let a = Double(i) / 400 * .pi
                for side in [-1.0, 1.0] {
                    let cx = e.x - r, cy = e.y + side * (half - r)
                    let local = SIMD3(cx + r * sin(a), cy + side * r * cos(a), e.z + face * profile.thicknessM / 2)
                    let w = pose * SIMD4(local, 1)
                    lowest = min(lowest, w.y)
                }
            }
        }
        return lowest
    }

    func testCameraAxesForUprightPhone() {
        let pose = uprightPose(camera: SIMD3(0.1, 0.30, 0.2))
        XCTAssertEqual(DeviceEdgeMeasurement.tiltFromUprightDeg(cameraToWorld: pose), 0, accuracy: 1e-9)
        XCTAssertTrue(DeviceEdgeMeasurement.isUpright(cameraToWorld: pose))
        // 下端の中央は、カメラの 147.64 − 25.6 = 122.04 mm 下、画面から見て左（世界の −X）へ 35.81 − 25.6 = 10.21 mm、
        // 人の方（+Z）へ厚みの半分。
        let edge = DeviceEdgeMeasurement.bottomEdgeCenter(cameraToWorld: pose, profile: profile)
        XCTAssertEqual(edge.y, 0.30 - 0.12204, accuracy: 1e-9)
        XCTAssertEqual(edge.x, 0.1 - 0.01021, accuracy: 1e-9)
        XCTAssertEqual(edge.z, 0.2 + 0.0039, accuracy: 1e-9)
        XCTAssertEqual(DeviceEdgeMeasurement.tableHeight(cameraToWorld: pose, profile: profile), 0.30 - 0.12204, accuracy: 1e-9)
        XCTAssertEqual(DeviceEdgeMeasurement.tableHeight(cameraToWorld: pose, profile: profile), bruteForceLowest(pose), accuracy: 1e-5)
    }

    func testTiltedPhoneUsesTheLowestPoint() {
        let base = uprightPose(camera: SIMD3(0, 0.25, 0))
        // 後ろへ 15° 傾ける（本体の左右の軸＝世界の X のまわり）、横へ 8° 傾ける（画面の法線＝世界の Z のまわり）、その両方。
        let lean = simd_double4x4(simd_quatd(angle: Geometry.radians(15), axis: SIMD3(1, 0, 0)))
        let roll = simd_double4x4(simd_quatd(angle: Geometry.radians(8), axis: SIMD3(0, 0, 1)))
        for rotation in [lean, roll, lean * roll, roll * lean] {
            var pose = rotation * base
            pose.columns.3 = base.columns.3
            let h = DeviceEdgeMeasurement.tableHeight(cameraToWorld: pose, profile: profile)
            XCTAssertEqual(h, bruteForceLowest(pose), accuracy: 2e-4)
            // 傾けると、下端の中央より低い点（縁や角）が机に当たる。
            XCTAssertLessThanOrEqual(h, DeviceEdgeMeasurement.bottomEdgeCenter(cameraToWorld: pose, profile: profile).y + 1e-9)
            XCTAssertTrue(DeviceEdgeMeasurement.isUpright(cameraToWorld: pose))
        }
        // 横に寝かせたら、立てているとはみなさない。
        let flat = simd_double4x4(simd_quatd(angle: Geometry.radians(60), axis: SIMD3(1, 0, 0))) * base
        XCTAssertFalse(DeviceEdgeMeasurement.isUpright(cameraToWorld: flat))
    }

    func testProfiles() {
        XCTAssertEqual(DeviceCameraProfile.forModel("iPhone15,4"), .iPhone15)
        XCTAssertEqual(DeviceCameraProfile.forModel("iPhone17,3"), .iPhone16)
        XCTAssertFalse(DeviceCameraProfile.forModel("iPhone99,1").isKnownModel)
        // iPhone 16 のメインカメラは縦の並びの下（上端から 31.34 mm、端から 13.62 mm）。
        let o = DeviceCameraProfile.iPhone16.bottomEdgeOffsetInCamera
        XCTAssertEqual(o.x, 0.1163, accuracy: 1e-4)
        XCTAssertEqual(o.y, -0.022195, accuracy: 1e-6)
    }

    func testStillness() {
        var still = StillnessTracker()
        let pose = matrix_identity_double4x4
        XCTAssertEqual(still.update(transform: pose, timestamp: 0), 0)
        var p = pose
        p.columns.3 = SIMD4(0.002, 0, 0, 1)  // 2 mm は手の揺れとみなす
        XCTAssertEqual(still.update(transform: p, timestamp: 0.6), 0.6, accuracy: 1e-12)
        XCTAssertEqual(still.update(transform: p, timestamp: 1.1), 1.1, accuracy: 1e-12)
        p.columns.3 = SIMD4(0.01, 0, 0, 1)  // 1 cm 動いた → 数え直す
        XCTAssertEqual(still.update(transform: p, timestamp: 1.2), 0)
        let turned = simd_double4x4(simd_quatd(angle: Geometry.radians(3), axis: SIMD3(0, 1, 0)))
        var t = turned
        t.columns.3 = p.columns.3
        XCTAssertEqual(still.update(transform: t, timestamp: 1.3), 0)
        XCTAssertEqual([3.0, 1.0, 2.0].median, 2)
        XCTAssertEqual([4.0, 1.0, 2.0, 3.0].median, 2.5)
        XCTAssertNil([Double]().median)
    }
}

final class BasePointInfoCodingTests: XCTestCase {
    func testReferenceFrameRecordsHowTheBaseWasFound() throws {
        let encoder = SessionJSON.makeEncoder()
        var ref = ReferenceFrame(id: "ref-1", createdAt: Date(timeIntervalSince1970: 0), basePointWorld: SIMD3(0, 0, -0.3),
                                 base: BasePointInfo(source: .featurePoints, manualOffsetM: -0.005, supportPoints: 34))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: try encoder.encode(ref)) as? [String: Any])
        let base = try XCTUnwrap(json["base"] as? [String: Any])
        XCTAssertEqual(base["source"] as? String, "featurePoints")
        XCTAssertEqual(base["manualOffsetM"] as? Double, -0.005)
        XCTAssertEqual(base["supportPoints"] as? Int, 34)

        ref.base = BasePointInfo(source: .deviceEdge)
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: try encoder.encode(ref)) as? [String: Any])
        let edge = try XCTUnwrap(json["base"] as? [String: Any])
        XCTAssertEqual(edge["source"] as? String, "deviceEdge")
        XCTAssertTrue(edge["supportPoints"] is NSNull)

        // 前の版の基準（base の無い JSON）も読める。
        let old = #"{"id":"ref-1","createdAt":"2026-11-09T10:00:00+09:00","basePointWorld":[0,0,0],"objectToWorld":null,"frontPhotoId":null,"invalidatedAt":null,"invalidationReason":null}"#
        let decoded = try SessionJSON.makeDecoder().decode(ReferenceFrame.self, from: Data(old.utf8))
        XCTAssertNil(decoded.base)
    }
}
