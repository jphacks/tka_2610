@testable import CaptureCore
import simd
import XCTest

final class MaskCropPlannerTests: XCTestCase {
    private func object(_ box: PixelRect) -> ProjectedObject {
        ProjectedObject(boundingBox: box, silhouette: [
            SIMD2(box.minX, box.minY), SIMD2(box.maxX, box.minY), SIMD2(box.maxX, box.maxY), SIMD2(box.minX, box.maxY),
        ])
    }

    func testExpandsAroundCenterByMarginFactor() {
        let plan = MaskCropPlanner.plan(object: object(PixelRect(x: 1500, y: 1000, width: 1000, height: 800)), imageWidth: 4032, imageHeight: 3024, marginFactor: 1.6)
        XCTAssertEqual(plan.source, .projectedCylinder)
        // 1.6 倍：幅 1600（中心 2000）、高さ 1280（中心 1400）。
        XCTAssertEqual(plan.region, PixelBox(x: 1200, y: 760, width: 1600, height: 1280))
        XCTAssertEqual(plan.recordedRegion, plan.region)
        // 既定の倍率（1.2）：幅 1200、高さ 960。
        let d = MaskCropPlanner.plan(object: object(PixelRect(x: 1500, y: 1000, width: 1000, height: 800)), imageWidth: 4032, imageHeight: 3024)
        XCTAssertEqual(MaskCropPlanner.marginFactor, 1.2)
        XCTAssertEqual(d.region, PixelBox(x: 1400, y: 920, width: 1200, height: 960))
    }

    func testMinimumSide() {
        let plan = MaskCropPlanner.plan(object: object(PixelRect(x: 2000, y: 1500, width: 100, height: 400)), imageWidth: 4032, imageHeight: 3024, marginFactor: 1.6)
        // 幅 160 → 512、高さ 640 はそのまま。
        XCTAssertEqual(plan.region, PixelBox(x: 1794, y: 1380, width: 512, height: 640))
        XCTAssertGreaterThanOrEqual(min(plan.region.width, plan.region.height), MaskCropPlanner.minimumSide)
    }

    func testShiftsInsideImageKeepingSize() {
        // 左上の角にはみ出す作品：大きさを保ったまま内側へずらす。
        let plan = MaskCropPlanner.plan(object: object(PixelRect(x: -100, y: -50, width: 500, height: 500)), imageWidth: 4032, imageHeight: 3024, marginFactor: 1.6)
        XCTAssertEqual(plan.region, PixelBox(x: 0, y: 0, width: 800, height: 800))
        // 右下。
        let br = MaskCropPlanner.plan(object: object(PixelRect(x: 3900, y: 2900, width: 300, height: 300)), imageWidth: 4032, imageHeight: 3024, marginFactor: 1.6)
        XCTAssertEqual(br.region, PixelBox(x: 4032 - 512, y: 3024 - 512, width: 512, height: 512))
    }

    func testClampsToImageWhenLargerThanImage() {
        let plan = MaskCropPlanner.plan(object: object(PixelRect(x: 500, y: 300, width: 3000, height: 2500)), imageWidth: 4032, imageHeight: 3024, marginFactor: 1.6)
        XCTAssertEqual(plan.region, PixelBox(x: 0, y: 0, width: 4032, height: 3024))
        XCTAssertEqual(plan.source, .projectedCylinder)
        // 写真が 512 より小さいときは写真の大きさまで。
        let tiny = MaskCropPlanner.plan(object: object(PixelRect(x: 10, y: 10, width: 20, height: 20)), imageWidth: 300, imageHeight: 200)
        XCTAssertEqual(tiny.region, PixelBox(x: 0, y: 0, width: 300, height: 200))
    }

    func testFallsBackToFullImage() {
        let none = MaskCropPlanner.plan(object: nil, imageWidth: 4032, imageHeight: 3024)
        XCTAssertEqual(none.source, .fullImage)
        XCTAssertEqual(none.region, PixelBox(x: 0, y: 0, width: 4032, height: 3024))
        XCTAssertNil(none.recordedRegion)
        // 作品が写真の外にあるときも全体。
        let outside = MaskCropPlanner.plan(object: object(PixelRect(x: 5000, y: 100, width: 300, height: 300)), imageWidth: 4032, imageHeight: 3024)
        XCTAssertEqual(outside.source, .fullImage)
    }

    func testPlanFromSessionAndBehindCamera() throws {
        var session = Fixtures.session()
        let base = SIMD3(0.1, -0.7, -0.4)
        let front = Fixtures.position(base: base, height: 0.15, azimuth: 0, elevation: 20, distance: 0.4)
        let center = base + SIMD3(0, 0.075, 0)
        let photo = PhotoRecorder.makePhoto(in: &session, photoId: "11111111-0000-4000-8000-000000000001", sequence: 1,
                                            frame: Fixtures.frame(cameraToWorld: Fixtures.lookAt(from: front, to: center)), context: Fixtures.context(ref: "ref-1"))
        let plan = MaskCropPlanner.plan(photo: photo, session: session)
        XCTAssertEqual(plan.source, .projectedCylinder)
        let obj = try XCTUnwrap(plan.object)
        // 作品は画像の中央付近、切り抜きは作品を含む。
        XCTAssertEqual(obj.boundingBox.midX, 960, accuracy: 30)
        XCTAssertLessThanOrEqual(Double(plan.region.x), obj.boundingBox.minX)
        XCTAssertGreaterThanOrEqual(Double(plan.region.maxX), obj.boundingBox.maxX)
        XCTAssertGreaterThanOrEqual(obj.silhouette.count, 4)

        // 作品に背を向けたカメラ → 全体。
        let away = front + (front - center)
        var back = photo
        back.camera.cameraToWorld = Matrix4x4(Fixtures.lookAt(from: front, to: away))
        XCTAssertEqual(MaskCropPlanner.plan(photo: back, session: session).source, .fullImage)
        // 基準が無い → 全体。
        var noRef = photo
        noRef.referenceFrameId = nil
        XCTAssertEqual(MaskCropPlanner.plan(photo: noRef, session: session).source, .fullImage)
    }

    func testPlansRetryTighterAndRecordedPlan() throws {
        let obj = object(PixelRect(x: 1500, y: 1000, width: 1000, height: 800))
        let plans = MaskCropPlanner.plans(object: obj, imageWidth: 4032, imageHeight: 3024)
        XCTAssertEqual(plans.map(\.region), [
            PixelBox(x: 1400, y: 920, width: 1200, height: 960),
            PixelBox(x: 1500, y: 1000, width: 1000, height: 800),
        ])
        // 2 つが同じ範囲（小さい作品で 512 の下限にかかる）なら 1 つだけ。
        XCTAssertEqual(MaskCropPlanner.plans(object: object(PixelRect(x: 2000, y: 1500, width: 100, height: 100)), imageWidth: 4032, imageHeight: 3024).count, 1)
        // 投影できなければ全体の 1 つだけ。
        XCTAssertEqual(MaskCropPlanner.plans(object: nil, imageWidth: 4032, imageHeight: 3024).map(\.source), [.fullImage])

        // 記録した範囲から、マスクを作ったときと同じ切り抜きを作り直す（選び直しのため）。
        var session = Fixtures.session()
        let base = SIMD3(0.1, -0.7, -0.4)
        let center = base + SIMD3(0, 0.075, 0)
        let front = Fixtures.position(base: base, height: 0.15, azimuth: 0, elevation: 20, distance: 0.4)
        var photo = PhotoRecorder.makePhoto(in: &session, photoId: "11111111-0000-4000-8000-000000000001", sequence: 1,
                                            frame: Fixtures.frame(cameraToWorld: Fixtures.lookAt(from: front, to: center)), context: Fixtures.context(ref: "ref-1"))
        XCTAssertNil(MaskCropPlanner.recordedPlan(photo: photo, session: session))
        let tighter = MaskCropPlanner.plans(photo: photo, session: session).last!
        photo.mask = MaskInfo(status: .candidate, selectedInstances: [1], selection: .auto).recording(tighter)
        let recorded = try XCTUnwrap(MaskCropPlanner.recordedPlan(photo: photo, session: session))
        XCTAssertEqual(recorded.region, tighter.region)
        XCTAssertEqual(recorded.source, .projectedCylinder)
        XCTAssertNotNil(recorded.object)
        photo.mask = MaskInfo(status: .noObject).recording(.fullImage(width: 1920, height: 1440))
        XCTAssertEqual(MaskCropPlanner.recordedPlan(photo: photo, session: session)?.source, .fullImage)
        XCTAssertEqual(MaskCropPlanner.recordedPlan(photo: photo, session: session)?.region, PixelBox(x: 0, y: 0, width: 1920, height: 1440))
        // 写真からはみ出す記録は使わない。
        photo.mask = MaskInfo(status: .candidate, inputRegion: PixelBox(x: 1800, y: 0, width: 512, height: 512), inputRegionSource: .projectedCylinder)
        XCTAssertNil(MaskCropPlanner.recordedPlan(photo: photo, session: session))
    }

    func testCoordinateMapping() throws {
        let plan = MaskCropPlan(region: PixelBox(x: 1000, y: 500, width: 800, height: 600), source: .projectedCylinder, imageWidth: 4000, imageHeight: 3000,
                                object: object(PixelRect(x: 1200, y: 650, width: 400, height: 300)))
        XCTAssertEqual(plan.cropPoint(fromImage: SIMD2(1100, 600)), SIMD2(100, 100))
        XCTAssertEqual(plan.imagePoint(fromCrop: SIMD2(100, 100)), SIMD2(1100, 600))
        // ラベル画像が切り抜きの半分の大きさ（400 × 300）。
        let p = try XCTUnwrap(plan.labelMapPixel(fromNormalizedImage: SIMD2(1400.0 / 4000, 800.0 / 3000), mapWidth: 400, mapHeight: 300))
        XCTAssertEqual(p.x, 200)
        XCTAssertEqual(p.y, 150)
        // 切り抜きの外。
        XCTAssertNil(plan.labelMapPixel(fromNormalizedImage: SIMD2(0.1, 0.1), mapWidth: 400, mapHeight: 300))
        XCTAssertNil(plan.labelMapPixel(fromNormalizedImage: SIMD2(1800.0 / 4000, 0.2), mapWidth: 400, mapHeight: 300))
        // 端の点は最後のピクセルに入る。
        let edge = try XCTUnwrap(plan.labelMapPixel(fromNormalizedImage: SIMD2(1799.9 / 4000, 1099.9 / 3000), mapWidth: 400, mapHeight: 300))
        XCTAssertEqual(edge.x, 399)
        XCTAssertEqual(edge.y, 299)
        // 選ぶ範囲と輪郭もラベル画像の座標へ。
        XCTAssertEqual(plan.selectionROI(mapWidth: 400, mapHeight: 300), PixelRect(x: 100, y: 75, width: 200, height: 150))
        XCTAssertEqual(plan.silhouette(mapWidth: 400, mapHeight: 300)?.first, SIMD2(100, 75))

        // 全体のときは写真と同じ座標。
        let full = MaskCropPlan.fullImage(width: 4000, height: 3000)
        let q = try XCTUnwrap(full.labelMapPixel(fromNormalizedImage: SIMD2(0.5, 0.25), mapWidth: 400, mapHeight: 300))
        XCTAssertEqual(q.x, 200)
        XCTAssertEqual(q.y, 75)
        XCTAssertNil(full.selectionROI(mapWidth: 400, mapHeight: 300))
    }

    func testPasteIntoFullCanvas() {
        // 3 × 2 の切り抜きを 6 × 4 の (2, 1) に貼る。
        let crop: [UInt8] = [255, 0, 255, 0, 255, 0]
        let full = MaskCanvas.paste(crop, region: PixelBox(x: 2, y: 1, width: 3, height: 2), fullWidth: 6, fullHeight: 4)
        XCTAssertEqual(full.count, 24)
        XCTAssertEqual(full, [
            0, 0, 0, 0, 0, 0,
            0, 0, 255, 0, 255, 0,
            0, 0, 0, 255, 0, 0,
            0, 0, 0, 0, 0, 0,
        ])
        // 写真からはみ出す部分は捨てる。
        let edge = MaskCanvas.paste([255, 255, 255, 255], region: PixelBox(x: 5, y: 3, width: 2, height: 2), fullWidth: 6, fullHeight: 4)
        XCTAssertEqual(edge.filter { $0 == 255 }.count, 1)
        XCTAssertEqual(edge[23], 255)
    }

    func testRegionCoding() throws {
        var mask = MaskInfo(status: .candidate, file: "masks/x.png", width: 4032, height: 3024, method: MaskInfo.visionMethod, instanceCount: 2, selectedInstances: [2], selection: .auto)
        let plan = MaskCropPlanner.plan(object: object(PixelRect(x: 1500, y: 1000, width: 1000, height: 800)), imageWidth: 4032, imageHeight: 3024, marginFactor: 1.6)
        mask = mask.recording(plan)
        let data = try JSONEncoder().encode(mask)
        let j = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(j["inputRegion"] as? [String: Int], ["x": 1200, "y": 760, "width": 1600, "height": 1280])
        XCTAssertEqual(j["inputRegionSource"] as? String, "projectedCylinder")
        XCTAssertEqual(try JSONDecoder().decode(MaskInfo.self, from: data), mask)

        let full = MaskInfo(status: .noObject, method: MaskInfo.visionMethod, instanceCount: 0).recording(.fullImage(width: 4032, height: 3024))
        let jf = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(full)) as? [String: Any])
        XCTAssertTrue(jf["inputRegion"] is NSNull)
        XCTAssertEqual(jf["inputRegionSource"] as? String, "fullImage")

        // 前の版のマスク（項目が無い）も読める。
        let old = #"{"status":"candidate","file":"masks/x.png","width":1,"height":1,"method":"m","instanceCount":1,"selectedInstances":[1],"selection":"auto","error":null}"#
        let decoded = try JSONDecoder().decode(MaskInfo.self, from: Data(old.utf8))
        XCTAssertNil(decoded.inputRegion)
        XCTAssertNil(decoded.inputRegionSource)
    }
}

final class PolygonTests: XCTestCase {
    func testConvexHull() {
        let pts: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(4, 0), SIMD2(4, 4), SIMD2(0, 4), SIMD2(2, 2), SIMD2(1, 3)]
        let hull = Polygon.convexHull(pts)
        XCTAssertEqual(Set(hull.map { "\($0.x),\($0.y)" }), ["0.0,0.0", "4.0,0.0", "4.0,4.0", "0.0,4.0"])
    }

    func testRowSpans() {
        let square: [SIMD2<Double>] = [SIMD2(2, 1), SIMD2(6, 1), SIMD2(6, 5), SIMD2(2, 5)]
        XCTAssertEqual(Polygon.rowSpans(square, row: 0, width: 10), [])
        XCTAssertEqual(Polygon.rowSpans(square, row: 1, width: 10), [2..<6])
        XCTAssertEqual(Polygon.rowSpans(square, row: 4, width: 10), [2..<6])
        XCTAssertEqual(Polygon.rowSpans(square, row: 5, width: 10), [])
        // 画像の幅で切り詰める。
        let wide: [SIMD2<Double>] = [SIMD2(-3, 0), SIMD2(20, 0), SIMD2(20, 2), SIMD2(-3, 2)]
        XCTAssertEqual(Polygon.rowSpans(wide, row: 1, width: 10), [0..<10])
    }
}

final class MaskPreferenceTests: XCTestCase {
    /// 20 × 20。番号 1 はほぼ全体（マット）、番号 2 は中央の小さな物（作品）、番号 3 は隅の小さな物。
    private func padMap() -> InstanceLabelMap {
        let w = 20, h = 20
        var labels = [UInt8](repeating: 1, count: w * h)
        labels[0] = 0
        for y in 8..<12 { for x in 8..<12 { labels[y * w + x] = 2 } }
        for y in 0..<2 { for x in 18..<20 { labels[y * w + x] = 3 } }
        return InstanceLabelMap(labels: labels, width: w, height: h)
    }

    func testTooLargeSelectionIsReplacedByBestSilhouetteOverlap() {
        let map = padMap()
        let roi = PixelRect(x: 4, y: 4, width: 12, height: 12)
        // 範囲との重なりだけで選ぶとマットが選ばれる。
        XCTAssertEqual(MaskInstanceSelector.autoSelect(map: map, roi: roi), [1])
        XCTAssertGreaterThan(MaskInstanceSelector.coverage(map: map, selected: [1]), MaskInstanceSelector.tooLargeCoverage)
        // 輪郭（中央）と一番重なる、広すぎない物に替える。
        let silhouette: [SIMD2<Double>] = [SIMD2(7, 7), SIMD2(13, 7), SIMD2(13, 13), SIMD2(7, 13)]
        XCTAssertEqual(MaskInstanceSelector.autoSelect(map: map, roi: roi, silhouette: silhouette), [2])
        // 輪郭が無ければ ROI を輪郭として使う。
        XCTAssertEqual(MaskInstanceSelector.autoSelect(map: map, roi: roi, silhouette: nil), [2])
    }

    func testKeepsSelectionWhenNoAlternativeOverlaps() {
        let map = padMap()
        // 輪郭が右下の、マットしか無い所：替えない。
        let silhouette: [SIMD2<Double>] = [SIMD2(14, 14), SIMD2(19, 14), SIMD2(19, 19), SIMD2(14, 19)]
        XCTAssertEqual(MaskInstanceSelector.autoSelect(map: map, roi: PixelRect(x: 14, y: 14, width: 5, height: 5), silhouette: silhouette), [1])
    }

    func testPlausibility() {
        let map = padMap()
        XCTAssertFalse(MaskInstanceSelector.isPlausible(map: map, selected: []))
        XCTAssertFalse(MaskInstanceSelector.isPlausible(map: map, selected: [1]))
        XCTAssertTrue(MaskInstanceSelector.isPlausible(map: map, selected: [2]))
        XCTAssertEqual(MaskInstanceSelector.coverage(map: map, selected: [2]), 16.0 / 400, accuracy: 1e-12)
    }

    func testSingleHugeInstanceIsKept() {
        var labels = [UInt8](repeating: 1, count: 100)
        labels[0] = 0
        let map = InstanceLabelMap(labels: labels, width: 10, height: 10)
        XCTAssertEqual(MaskInstanceSelector.autoSelect(map: map, roi: PixelRect(x: 2, y: 2, width: 4, height: 4), silhouette: nil), [1])
    }

    func testNormalSelectionIsUnchanged() {
        // 選んだ物が広すぎなければ、今までどおり。
        let w = 20, h = 10
        var labels = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w {
            if x < 6 { labels[y * w + x] = 1 }
            if x >= 8 && x < 12 && y >= 2 && y < 8 { labels[y * w + x] = 2 }
        } }
        let map = InstanceLabelMap(labels: labels, width: w, height: h)
        XCTAssertEqual(MaskInstanceSelector.autoSelect(map: map, roi: PixelRect(x: 7, y: 1, width: 6, height: 8), silhouette: nil), [2])
    }
}
