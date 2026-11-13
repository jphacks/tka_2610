import XCTest
import simd
import CoreGraphics
import CaptureCore
@testable import PackKit

final class PackKitTests: XCTestCase {
    // MARK: - Fixtures

    static let plan = DirectionPlan(id: "test", targets: [
        DirectionTarget(id: "a000-e20", azimuthDeg: 0, elevationDeg: 20, azimuthToleranceDeg: 7, elevationToleranceDeg: 10),
        DirectionTarget(id: "a015-e20", azimuthDeg: 15, elevationDeg: 20, azimuthToleranceDeg: 7, elevationToleranceDeg: 10),
        DirectionTarget(id: "a090-e20", azimuthDeg: 90, elevationDeg: 20, azimuthToleranceDeg: 7, elevationToleranceDeg: 10),
        DirectionTarget(id: "a000-e70", azimuthDeg: 0, elevationDeg: 70, azimuthToleranceDeg: 20, elevationToleranceDeg: 10),
    ])

    static func pid(_ n: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", n) }

    func photo(_ seq: Int, az: Double, el: Double, frame: String? = "ref-1", confirmed: Bool = true, target: String? = nil,
               mask: MaskStatus = .candidate, check: MaskCheckStatus? = .ok, blur: CheckStatus = .ok) -> Photo {
        let id = Self.pid(seq)
        return Photo(
            photoId: id, sequence: seq, capturedAt: Date(timeIntervalSince1970: Double(seq)), trigger: .auto,
            referenceFrameId: frame,
            image: ImageInfo(file: Photo.imagePath(photoId: id), width: 4032, height: 3024, displayRotationDegClockwise: 90, deviceOrientation: "portrait"),
            camera: CameraInfo(arFrameTimestamp: 0, cameraToWorld: Matrix4x4(matrix_identity_double4x4),
                               intrinsics: Matrix3x3(simd_double3x3(rows: [SIMD3(3000, 0, 2016), SIMD3(0, 3000, 1512), SIMD3(0, 0, 1)])),
                               intrinsicsResolution: PixelSize(width: 4032, height: 3024),
                               exposureDurationS: nil, exposureOffsetEV: nil, trackingState: .normal, trackingReason: nil),
            direction: DirectionInfo(confirmed: confirmed, unconfirmedReason: confirmed ? nil : .trackingNotNormal,
                                     targetId: confirmed ? target : nil, azimuthDeg: az, elevationDeg: el, distanceM: 0.3),
            quality: PhotoQuality(live: .unknown, saved: SavedQuality(meanLuma: 0.5, sharpness: 0.01, brightness: .ok, blur: blur)),
            mask: MaskInfo(status: mask, file: mask.hasFile ? Photo.maskPath(photoId: id) : nil, width: 4032, height: 3024,
                           check: mask.hasFile ? check.map { MaskCheck(status: $0, reasons: $0 == .ok ? [] : [.tooLarge]) } : nil)
        )
    }

    func session(_ photos: [Photo], frames: [String] = ["ref-1"]) -> CaptureSession {
        var s = CaptureSession(sessionId: "S", title: "", createdAt: Date(timeIntervalSince1970: 0),
                               device: DeviceInfo(model: "", systemName: "iOS", systemVersion: "", appVersion: "", appBuild: ""),
                               directionPlan: Self.plan)
        s.referenceFrames = frames.map { ReferenceFrame(id: $0, createdAt: Date(timeIntervalSince1970: 0), basePointWorld: .zero) }
        s.photos = photos
        return s
    }

    func choice(_ name: String, _ result: (referenceFrameId: String?, choices: [ViewChoice])) -> ViewChoice {
        result.choices.first { $0.name == name }!
    }

    // MARK: - View selection

    func testClosestAngleWins() {
        let s = session([photo(1, az: 12, el: 21), photo(2, az: 3, el: 22), photo(3, az: 350, el: 30)])
        let r = ViewSelector.select(session: s)
        XCTAssertEqual(choice("front", r).photoId, Self.pid(2))
        XCTAssertEqual(choice("front", r).azimuthDeg, 3)
        XCTAssertTrue(choice("front", r).notes.isEmpty)
    }

    func testSkipsUnusableMasksUnconfirmedAndOtherFrames() {
        let s = session([
            photo(1, az: 0, el: 20, check: .suspicious),            // suspicious mask
            photo(2, az: 1, el: 20, mask: .noObject),                // no mask
            photo(3, az: 0.5, el: 20, frame: nil, confirmed: false), // unconfirmed direction
            photo(4, az: 359, el: 20, frame: "ref-2"),               // minority frame
            photo(5, az: 9, el: 24),                                 // usable, further away
            photo(6, az: 90, el: 20), photo(7, az: 180, el: 20),
        ], frames: ["ref-1", "ref-2"])
        let r = ViewSelector.select(session: s)
        XCTAssertEqual(r.referenceFrameId, "ref-1")
        XCTAssertEqual(choice("front", r).photoId, Self.pid(5))
        XCTAssertEqual(choice("front", r).maskUse, .good)
        XCTAssertEqual(choice("right", r).photoId, Self.pid(6))
    }

    func testUnusableMaskOnlyAsLastResort() {
        let s = session([photo(1, az: 0, el: 20, check: .suspicious)])
        let c = choice("front", ViewSelector.select(session: s))
        XCTAssertEqual(c.photoId, Self.pid(1))
        XCTAssertEqual(c.maskUse, .unusable)
        XCTAssertTrue(c.notes.contains { $0.hasPrefix("no usable mask") })
    }

    func testBlurPreferredLessThanCleanPhoto() {
        let s = session([photo(1, az: 0, el: 20, blur: .warning), photo(2, az: 8, el: 20)])
        XCTAssertEqual(choice("front", ViewSelector.select(session: s)).photoId, Self.pid(2))
    }

    func testSupersededPhotosAreSkipped() {
        // Same target, both usable: the older shot is superseded even though it is closer to the slot.
        let s = session([photo(1, az: 0, el: 20, target: "a000-e20"), photo(2, az: 5, el: 20, target: "a000-e20")])
        XCTAssertEqual(ViewSelector.supersededPhotoIds(s), [Self.pid(1)])
        XCTAssertEqual(choice("front", ViewSelector.select(session: s)).photoId, Self.pid(2))
    }

    func testMajorityReferenceFrame() {
        let s = session([
            photo(1, az: 0, el: 20, frame: "ref-1"), photo(2, az: 90, el: 20, frame: "ref-1"),
            photo(3, az: 0, el: 20, frame: "ref-2"), photo(4, az: 90, el: 20, frame: "ref-2"), photo(5, az: 180, el: 20, frame: "ref-2"),
            photo(6, az: 0, el: 20, frame: nil, confirmed: false), photo(7, az: 0, el: 20, frame: nil, confirmed: false),
            photo(8, az: 0, el: 20, frame: nil, confirmed: false),
        ], frames: ["ref-1", "ref-2"])
        XCTAssertEqual(ViewSelector.majorityReferenceFrame(s), "ref-2")
        XCTAssertEqual(choice("front", ViewSelector.select(session: s)).photoId, Self.pid(3))
        // ties go to the later frame
        let tie = session([photo(1, az: 0, el: 20, frame: "ref-1"), photo(2, az: 0, el: 20, frame: "ref-2")], frames: ["ref-1", "ref-2"])
        XCTAssertEqual(ViewSelector.majorityReferenceFrame(tie), "ref-2")
    }

    func testTopAndFrontHighAndMissingSlots() {
        let s = session([photo(1, az: 0, el: 20), photo(2, az: 120, el: 69), photo(3, az: 10, el: 75), photo(4, az: 5, el: 44)])
        let r = ViewSelector.select(session: s)
        XCTAssertEqual(choice("top", r).photoId, Self.pid(2))       // closest to 70°
        XCTAssertEqual(choice("front_high", r).photoId, Self.pid(4))
        XCTAssertNil(choice("back", r).photoId)
        XCTAssertNotNil(choice("back", r).missingReason)
        // a photo is used once: photo 1 is the front, not also the front-left
        XCTAssertNil(choice("front_left", r).photoId)

        let low = session([photo(1, az: 0, el: 20), photo(2, az: 90, el: 35)])
        XCTAssertNil(choice("top", ViewSelector.select(session: low)).photoId)  // 35° is not a top view
    }

    func testMaskUseRules() {
        XCTAssertEqual(MaskUse.of(photo(1, az: 0, el: 20, mask: .confirmed, check: .suspicious)), .good)
        XCTAssertEqual(MaskUse.of(photo(1, az: 0, el: 20, check: .ok)), .good)
        XCTAssertEqual(MaskUse.of(photo(1, az: 0, el: 20, check: nil)), .unchecked)
        XCTAssertEqual(MaskUse.of(photo(1, az: 0, el: 20, check: .unknown)), .unusable)
        XCTAssertEqual(MaskUse.of(photo(1, az: 0, el: 20, mask: .failed)), .unusable)
        XCTAssertEqual(MaskUse.of(photo(1, az: 0, el: 20), fileExists: false), .unusable)
    }

    // MARK: - Crop and rotation

    func testUprightRectMatchesDisplayRotation() {
        let W = 4032, H = 3024
        let r = PixelBox(x: 1000, y: 500, width: 800, height: 600)
        for rot in [0, 90, 180, 270] {
            let u = CropMath.upright(r, imageWidth: W, imageHeight: H, rotationDegClockwise: rot)
            let size = DisplayRotation.displaySize(width: W, height: H, rotationDegClockwise: rot)
            // the four corners of r land on the corners of u
            let corners = [(r.x, r.y), (r.maxX, r.y), (r.x, r.maxY), (r.maxX, r.maxY)].map { c -> SIMD2<Double> in
                let n = DisplayRotation.displayPoint(fromSensor: SIMD2(Double(c.0) / Double(W), Double(c.1) / Double(H)), rotationDegClockwise: rot)
                return SIMD2(n.x * Double(size.width), n.y * Double(size.height))
            }
            XCTAssertEqual(corners.map(\.x).min()!, Double(u.x), accuracy: 1e-6, "rot \(rot)")
            XCTAssertEqual(corners.map(\.y).min()!, Double(u.y), accuracy: 1e-6, "rot \(rot)")
            XCTAssertEqual(corners.map(\.x).max()!, Double(u.maxX), accuracy: 1e-6, "rot \(rot)")
            XCTAssertEqual(corners.map(\.y).max()!, Double(u.maxY), accuracy: 1e-6, "rot \(rot)")
        }
        XCTAssertEqual(CropMath.upright(r, imageWidth: W, imageHeight: H, rotationDegClockwise: 90),
                       PixelBox(x: 3024 - 1100, y: 1000, width: 600, height: 800))
    }

    func testCropAddsMarginKeepsAspectAndStaysInside() {
        let box = PixelRect(x: 1000, y: 1000, width: 400, height: 100)
        let c = CropMath.crop(around: box, imageWidth: 4032, imageHeight: 3024)!
        // 20 % of the long side on each side → 560 wide, then widened to 4:3 → 420 tall, centred
        XCTAssertEqual(c.width, 560)
        XCTAssertEqual(c.height, 420)
        XCTAssertEqual(Double(c.x) + Double(c.width) / 2, box.midX, accuracy: 1)
        XCTAssertEqual(Double(c.y) + Double(c.height) / 2, box.midY, accuracy: 1)
        // near the corner it shifts inside, keeping its size
        let corner = CropMath.crop(around: PixelRect(x: 0, y: 0, width: 300, height: 300), imageWidth: 4032, imageHeight: 3024)!
        XCTAssertEqual(corner, PixelBox(x: 0, y: 0, width: 420, height: 420))
        // larger than the photo: clipped to it
        let big = CropMath.crop(around: PixelRect(x: 0, y: 0, width: 4000, height: 3000), imageWidth: 4032, imageHeight: 3024)!
        XCTAssertEqual(big, PixelBox(x: 0, y: 0, width: 4032, height: 3024))
        XCTAssertNil(CropMath.crop(around: PixelRect(x: 5000, y: 0, width: 10, height: 10), imageWidth: 4032, imageHeight: 3024))
    }

    func testOutputSizeNeverUpscalesAndCapsLongSide() {
        let small = CropMath.outputSize(crop: PixelBox(x: 0, y: 0, width: 600, height: 400), rotationDegClockwise: 90)
        XCTAssertEqual(small.width, 400)
        XCTAssertEqual(small.height, 600)
        let big = CropMath.outputSize(crop: PixelBox(x: 0, y: 0, width: 3136, height: 2352), rotationDegClockwise: 90)
        XCTAssertEqual(big.width, 1176)
        XCTAssertEqual(big.height, 1568)
    }

    func testUprightCropTurnsPixelsClockwise() throws {
        // A 4 × 2 grid of 10-px blocks with values 0…70; crop the right 3 block columns and turn it.
        let blocks: [[UInt8]] = [[0, 10, 20, 30], [40, 50, 60, 70]]
        let n = 10
        var src = GrayImage(width: 4 * n, height: 2 * n)
        for y in 0..<(2 * n) { for x in 0..<(4 * n) { src[x, y] = blocks[y / n][x / n] } }
        let image = ImageOps.makeGrayImage(src)!
        let crop = PixelBox(x: n, y: 0, width: 3 * n, height: 2 * n)
        let expected: [Int: [[UInt8]]] = [
            0: [[10, 20, 30], [50, 60, 70]],
            90: [[50, 10], [60, 20], [70, 30]],    // the left block column of the crop becomes the top row
            180: [[70, 60, 50], [30, 20, 10]],
            270: [[30, 70], [20, 60], [10, 50]],
        ]
        for (rot, want) in expected {
            let size = CropMath.outputSize(crop: crop, rotationDegClockwise: rot)
            let out = try ImageOps.gray(ImageOps.uprightCrop(image, crop: crop, rotationDegClockwise: rot,
                                                              width: size.width, height: size.height, gray: true))
            XCTAssertEqual(out.width, want[0].count * n, "rot \(rot)")
            XCTAssertEqual(out.height, want.count * n, "rot \(rot)")
            let got = (0..<want.count).map { r in (0..<want[0].count).map { c in out[c * n + n / 2, r * n + n / 2] } }
            XCTAssertEqual(got, want, "rot \(rot)")
            let u = CropMath.upright(crop, imageWidth: 4 * n, imageHeight: 2 * n, rotationDegClockwise: rot)
            XCTAssertEqual([u.width, u.height], [out.width, out.height])
        }
    }

    func testTransparentCutoutUsesMaskAsAlpha() throws {
        let photo = ImageOps.makeGrayImage(GrayImage(width: 3, height: 1, pixels: [200, 200, 200]))!
        let cut = try ImageOps.transparentCutout(photo: photo, alpha: GrayImage(width: 3, height: 1, pixels: [255, 128, 0]))
        XCTAssertEqual(cut.alphaInfo, .last)
        // Written as PNG and read back: alpha survives, colour is untouched (no grey background).
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cutout-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try ImageOps.writePNG(cut, to: url)
        let back = try ImageOps.loadImage(url)
        XCTAssertTrue([.last, .premultipliedLast, .first, .premultipliedFirst].contains(back.alphaInfo))
        var px = [UInt8](repeating: 0, count: 12)
        let ctx = CGContext(data: &px, width: 3, height: 1, bitsPerComponent: 8, bytesPerRow: 12,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(back, in: CGRect(x: 0, y: 0, width: 3, height: 1))
        XCTAssertEqual(px[3], 255)
        XCTAssertEqual(Int(px[7]), 128, accuracy: 1)
        XCTAssertEqual(px[11], 0)
        XCTAssertEqual(Int(px[0]), 200, accuracy: 2)
    }

    // MARK: - Visual hull on a synthetic scene

    /// ARKit-style camera at `position` looking at `target` (+X image right, +Y image up, −Z forward).
    static func lookAt(_ position: SIMD3<Double>, _ target: SIMD3<Double>) -> simd_double4x4 {
        let forward = simd_normalize(target - position)
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
        let up = simd_cross(right, forward)
        return simd_double4x4(columns: (SIMD4(right, 0), SIMD4(up, 0), SIMD4(-forward, 0), SIMD4(position, 1)))
    }

    /// Mask of an axis-aligned box (world) seen by a pinhole camera: a pixel is set when its ray hits the box.
    static func renderBox(min lo: SIMD3<Double>, max hi: SIMD3<Double>, cameraToWorld: simd_double4x4,
                          f: Double, width: Int, height: Int) -> GrayImage {
        var out = GrayImage(width: width, height: height)
        let o = cameraToWorld.translation
        let r = simd_double3x3(SIMD3(cameraToWorld.columns.0.x, cameraToWorld.columns.0.y, cameraToWorld.columns.0.z),
                               SIMD3(cameraToWorld.columns.1.x, cameraToWorld.columns.1.y, cameraToWorld.columns.1.z),
                               SIMD3(cameraToWorld.columns.2.x, cameraToWorld.columns.2.y, cameraToWorld.columns.2.z))
        for y in 0..<height {
            for x in 0..<width {
                let d = simd_normalize(r * SIMD3((Double(x) + 0.5 - Double(width) / 2) / f, -(Double(y) + 0.5 - Double(height) / 2) / f, -1))
                var t0 = 0.0, t1 = Double.infinity
                var hit = true
                for a in 0..<3 {
                    if abs(d[a]) < 1e-12 {
                        if o[a] < lo[a] || o[a] > hi[a] { hit = false; break }
                        continue
                    }
                    var ta = (lo[a] - o[a]) / d[a], tb = (hi[a] - o[a]) / d[a]
                    if ta > tb { swap(&ta, &tb) }
                    t0 = max(t0, ta); t1 = min(t1, tb)
                    if t0 > t1 { hit = false; break }
                }
                if hit { out[x, y] = 1 }
            }
        }
        return out
    }

    func syntheticViews(boxMin: SIMD3<Double>, boxMax: SIMD3<Double>) -> [HullView] {
        let f = 260.0, w = 320, h = 240
        var views: [HullView] = []
        let center = (boxMin + boxMax) / 2
        for el in [20.0, 45.0, 70.0] {
            for i in 0..<12 {
                let az = Double(i) * 30 + (el == 45 ? 15 : 0)
                let e = el * .pi / 180, a = az * .pi / 180
                let p = center + 0.35 * SIMD3(cos(e) * sin(a), sin(e), cos(e) * cos(a))
                let c2w = Self.lookAt(p, center)
                let mask = Self.renderBox(min: boxMin, max: boxMax, cameraToWorld: c2w, f: f, width: w, height: h)
                let k = simd_double3x3(rows: [SIMD3(f, 0, Double(w) / 2), SIMD3(0, f, Double(h) / 2), SIMD3(0, 0, 1)])
                views.append(HullView(id: "v\(views.count)", cameraToWorld: c2w, intrinsics: k,
                                      intrinsicsWidth: Double(w), intrinsicsHeight: Double(h), mask: mask))
            }
        }
        return views
    }

    func testVisualHullRecoversBoxSizeAndTable() {
        // A 10 × 4 × 6 cm box (W × H × D) on the table, a bit off the reference point.
        let lo = SIMD3(-0.04, 0.0, -0.035), hi = SIMD3(0.06, 0.04, 0.025)
        let views = syntheticViews(boxMin: lo, boxMax: hi)
        var settings = HullSettings()
        settings.voxelSize = 0.003
        settings.maskDilation = 0
        settings.carveFraction = 0
        // The reference point was measured 1 cm below the table: the object frame sits 1 cm lower.
        let offset = 0.01
        let objectToWorld = simd_double4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, -offset, 0, 1)))
        let empty = VisualHull.grid(radiusM: 0.09, heightM: 0.06, settings: settings)
        var grid = VisualHull.carve(grid: empty, views: views, objectToWorld: objectToWorld, settings: settings)
        grid.keepLargestComponent()
        let cams = views.map { v -> SIMD3<Double> in
            let p = objectToWorld.inverse * SIMD4(v.cameraToWorld.translation, 1)
            return SIMD3(p.x, p.y, p.z)
        }
        let table = VisualHull.estimateTable(grid: grid, cameraPositions: cams)!
        let s = settings.voxelSize
        XCTAssertEqual(table, offset, accuracy: 1.5 * s)
        grid = VisualHull.clip(grid, belowY: table)
        let b = grid.bounds()!
        let size = b.max - b.min
        XCTAssertEqual(size.x, 0.10, accuracy: 1.5 * s)
        XCTAssertEqual(size.z, 0.06, accuracy: 1.5 * s)
        // height from the table: the flat top makes the hull a little taller, within the reported bias bound
        let height = b.max.y - table
        let bias = VisualHull.flatTopBias(grid: grid, cameraPositions: cams)!
        XCTAssertGreaterThanOrEqual(height, 0.04 - 1.5 * s)
        XCTAssertLessThanOrEqual(height, 0.04 + bias + 1.5 * s)
        let fp = VisualHull.footprint(grid: grid)!
        XCTAssertEqual(fp.lengthM, 0.10, accuracy: 1.5 * s)
        XCTAssertEqual(fp.widthM, 0.06, accuracy: 1.5 * s)
        XCTAssertEqual(fp.longAxisAzimuthDeg, 90)  // long side runs left–right
        // the hull projects inside every mask: slack is about a voxel
        let slack = VisualHull.slack(grid: grid, views: views, objectToWorld: objectToWorld)
        XCTAssertEqual(slack.count, views.count)
        XCTAssertLessThan(slack.map(\.slackM).max()!, 2 * s)
    }

    func testUnknownProjectionsDoNotCarve() {
        // A single view that does not see the grid at all must not carve anything; minSeenViews then drops it all.
        var settings = HullSettings()
        settings.voxelSize = 0.01
        settings.minSeenViews = 0
        let away = Self.lookAt(SIMD3(0, 0.02, 0.5), SIMD3(0, 0.02, 1.5))  // looking away from the object
        let view = HullView(id: "v", cameraToWorld: away, intrinsics: simd_double3x3(rows: [SIMD3(100, 0, 50), SIMD3(0, 100, 50), SIMD3(0, 0, 1)]),
                            intrinsicsWidth: 100, intrinsicsHeight: 100, mask: GrayImage(width: 100, height: 100))
        let empty = VisualHull.grid(radiusM: 0.05, heightM: 0.05, settings: settings)
        let kept = VisualHull.carve(grid: empty, views: [view], objectToWorld: matrix_identity_double4x4, settings: settings)
        XCTAssertEqual(kept.count, empty.nx * empty.ny * empty.nz)
        settings.minSeenViews = 1
        XCTAssertEqual(VisualHull.carve(grid: empty, views: [view], objectToWorld: matrix_identity_double4x4, settings: settings).count, 0)
    }

    func testCarveFractionToleratesOneBadMask() {
        let lo = SIMD3(-0.03, 0.0, -0.03), hi = SIMD3(0.03, 0.03, 0.03)
        var views = syntheticViews(boxMin: lo, boxMax: hi)
        views[0].mask = GrayImage(width: views[0].mask.width, height: views[0].mask.height)  // an empty (wrong) mask
        var settings = HullSettings()
        settings.voxelSize = 0.003
        settings.carveFraction = 0
        let empty = VisualHull.grid(radiusM: 0.06, heightM: 0.05, settings: settings)
        XCTAssertEqual(VisualHull.carve(grid: empty, views: views, objectToWorld: matrix_identity_double4x4, settings: settings).count, 0)
        settings.carveFraction = 0.1
        let tolerant = VisualHull.carve(grid: empty, views: views, objectToWorld: matrix_identity_double4x4, settings: settings)
        XCTAssertGreaterThan(tolerant.count, 0)
    }

    func testObjFacesAreClosedAndOutward() {
        var g = VoxelGrid(nx: 2, ny: 1, nz: 1, voxelSize: 0.01, origin: .zero)
        g.occupied = [true, true]
        let obj = VisualHull.obj(grid: g, header: ["test"])
        XCTAssertEqual(obj.faces, 10)     // a 2 × 1 × 1 block: 10 exposed unit faces
        XCTAssertEqual(obj.vertices, 12)
        XCTAssertTrue(obj.text.hasPrefix("# test\nv "))
        // every face normal (from its winding) points away from the block centre
        let vs = obj.text.split(separator: "\n").filter { $0.hasPrefix("v ") }.map { l -> SIMD3<Double> in
            let p = l.split(separator: " ").dropFirst().map { Double($0)! }
            return SIMD3(p[0], p[1], p[2])
        }
        let centre = SIMD3(0.01, 0.005, 0.005)
        for l in obj.text.split(separator: "\n") where l.hasPrefix("f ") {
            let idx = l.split(separator: " ").dropFirst().map { Int($0)! - 1 }
            let n = simd_cross(vs[idx[1]] - vs[idx[0]], vs[idx[2]] - vs[idx[0]])
            let faceCentre = idx.map { vs[$0] }.reduce(.zero, +) / 4
            XCTAssertGreaterThan(simd_dot(n, faceCentre - centre), 0, String(l))
        }
    }

    func testLargestComponentDropsFragments() {
        var g = VoxelGrid(nx: 5, ny: 1, nz: 1, voxelSize: 0.01, origin: .zero)
        g.occupied = [true, true, false, false, true]
        XCTAssertEqual(g.keepLargestComponent(), 1)
        XCTAssertEqual(g.occupied, [true, true, false, false, false])
    }

    // MARK: - JSON shape

    func testMeasurementsJSONShape() throws {
        var m = Measurements(sessionId: "S", status: "ok")
        m.sizeCm = Size3(width: 6.2, depth: 12.4, height: 4.9)
        m.uncertainty = .init(plusMinusCm: 0.5, voxelCm: 0.2, reprojectionSlackCm: 0.3, heightOverestimateUpToCm: 0.9, note: "n")
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as! [String: Any]
        XCTAssertEqual(obj["schema"] as? String, "memoria.claude-pack.measurements")
        XCTAssertEqual(obj["schemaVersion"] as? Int, 1)
        XCTAssertEqual(obj["method"] as? String, "visualHull")
        let size = obj["sizeCm"] as! [String: Double]
        XCTAssertEqual(size, ["width": 6.2, "depth": 12.4, "height": 4.9])
        // missing values are null, not absent
        XCTAssertTrue(obj["footprint"] is NSNull)
        XCTAssertTrue(obj["tablePlaneAboveReferenceM"] is NSNull)
        XCTAssertNotNil((obj["frame"] as? [String: String])?["z"])
        let back = try JSONDecoder().decode(Measurements.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back.sizeCm, m.sizeCm)
    }

    func testViewChoiceAndPackIndexJSON() throws {
        let s = session([photo(1, az: 2, el: 21)])
        let choices = ViewSelector.select(session: s).choices
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(choices)) as! [[String: Any]]
        XCTAssertEqual(obj.map { $0["name"] as! String },
                       ["front", "front_right", "right", "back_right", "back", "back_left", "left", "front_left", "top", "front_high"])
        XCTAssertEqual(obj[0]["photoId"] as? String, Self.pid(1))
        XCTAssertEqual(obj[0]["maskUse"] as? String, "good")
        XCTAssertTrue(obj[1]["photoId"] is NSNull)
        XCTAssertNotNil(obj[1]["missingReason"] as? String)
        XCTAssertTrue(obj[8]["requestedAzimuthDeg"] is NSNull)  // top: any azimuth
    }

    // MARK: - Options and output location

    func testOptions() throws {
        let o = try PackOptions.parse(["CEB6", "--data-dir", "x", "--force"])
        XCTAssertEqual(o, PackOptions(session: "CEB6", dataDir: "x", force: true))
        XCTAssertFalse(o.cutouts)  // no background-removed images unless asked
        XCTAssertTrue(try PackOptions.parse(["CEB6", "--cutouts"]).cutouts)
        XCTAssertThrowsError(try PackOptions.parse([]))
        XCTAssertThrowsError(try PackOptions.parse(["a", "--nope"]))
    }

    func testOutputGoesToForClaudeAndNeverIntoSessions() throws {
        let data = URL(fileURLWithPath: "/tmp/pack-test-\(UUID().uuidString)", isDirectory: true)
        let located = LocatedSession(folder: data.appendingPathComponent("sessions/S"), dataDir: data,
                                     session: session([]), receipt: nil)
        XCTAssertEqual(try SessionLocator.outputDir(located: located).path, data.appendingPathComponent("for_claude/S").path)
        XCTAssertThrowsError(try SessionLocator.checkWritable(data.appendingPathComponent("sessions/S/for_claude"), located: located))
        XCTAssertThrowsError(try SessionLocator.checkWritable(data.appendingPathComponent("incoming/x"), located: located))
    }

    // MARK: - ai5 (5 views)

    static let ai5 = DirectionPlanPreset.ai5.plan

    func ai5Session(_ photos: [Photo]) -> CaptureSession {
        var s = session(photos)
        s.directionPlan = Self.ai5
        s.object = ObjectSize(heightM: 0.12, radiusM: 0.07)
        return s
    }

    func testAi5SessionSelectsTheFiveNamedViews() {
        let s = ai5Session([
            photo(1, az: 0, el: 15, target: "a000-e15"), photo(2, az: 92, el: 14, target: "a090-e15"),
            photo(3, az: 178, el: 17, target: "a180-e15"), photo(4, az: 266, el: 12, target: "a270-e15"),
            photo(5, az: 30, el: 62),                         // extra high shot, not the top target
            photo(6, az: 211, el: 84, target: "top-e90"),     // the top: any azimuth
        ])
        let r = ViewSelector.select(session: s)
        XCTAssertEqual(r.choices.map(\.name), ["front", "right", "back", "left", "top"])
        XCTAssertEqual(r.choices.map(\.photoId), [1, 2, 3, 4, 6].map(Self.pid))
        XCTAssertEqual(choice("top", r).targetId, "top-e90")
        XCTAssertTrue(choice("top", r).notes.isEmpty, "\(choice("top", r).notes)")
        XCTAssertTrue(r.choices.allSatisfy { !$0.isMissing })
        // the top photo is the top-e90 one even when a lower photo is closer to the front
        XCTAssertEqual(ViewSlot.slots(for: s).map(\.targetId), ["a000-e15", "a090-e15", "a180-e15", "a270-e15", "top-e90"])
        // other plans keep the 10 standard slots
        XCTAssertEqual(ViewSlot.slots(for: session([])).count, 10)
    }

    func testAi5TopMissingAndOblique() {
        let none = ai5Session([photo(1, az: 0, el: 15, target: "a000-e15"), photo(2, az: 30, el: 50)])
        let r = ViewSelector.select(session: none)
        XCTAssertNil(choice("top", r).photoId)
        XCTAssertTrue(choice("top", r).missingReason?.contains("60°") ?? false)
        // an extra 65° photo (outside top-e90's tolerance) is used, but flagged as not a true top view
        let oblique = ai5Session([photo(1, az: 0, el: 15, target: "a000-e15"), photo(2, az: 30, el: 65)])
        XCTAssertTrue(choice("top", ViewSelector.select(session: oblique)).notes.contains { $0.contains("not a true top view") })
    }

    /// Writes a small ai5 session to disk (5 photos with masks) and builds the package: 5 views with their backgrounds,
    /// no cutouts by default, and the size falls back to the user cylinder (5 silhouettes are too few for a hull).
    func testAi5PackageWithFiveViewsFallsBackToCylinder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pack-ai5-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("sessions/S", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("photos"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("masks"), withIntermediateDirectories: true)
        let shots: [(Double, Double, String)] = [(0, 15, "a000-e15"), (90, 15, "a090-e15"), (180, 15, "a180-e15"), (270, 15, "a270-e15"), (40, 88, "top-e90")]
        var photos: [Photo] = []
        let W = 64, H = 48
        for (i, shot) in shots.enumerated() {
            var p = photo(i + 1, az: shot.0, el: shot.1, target: shot.2)
            p.image.width = W
            p.image.height = H
            p.camera.intrinsicsResolution = PixelSize(width: W, height: H)
            p.mask.width = W
            p.mask.height = H
            var mask = GrayImage(width: W, height: H)
            for y in 16..<32 { for x in 24..<40 { mask[x, y] = 255 } }
            try ImageOps.writePNG(ImageOps.makeGrayImage(mask)!, to: folder.appendingPathComponent(p.mask.file!))
            try ImageOps.writeJPEG(ImageOps.makeGrayImage(GrayImage(width: W, height: H, fill: 180))!, to: folder.appendingPathComponent(p.image.file))
            photos.append(p)
        }
        var s = ai5Session(photos)
        s.referenceFrames[0].objectToWorld = Matrix4x4(matrix_identity_double4x4)
        let located = LocatedSession(folder: folder, dataDir: root, session: s, receipt: nil)
        let out = root.appendingPathComponent("for_claude/S", isDirectory: true)
        let summary = try PackBuilder(located: located).build(into: out)
        XCTAssertTrue(summary.contains("user cylinder"), summary)

        let files = try FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent("views").path).sorted()
        XCTAssertEqual(files, ["back.jpg", "front.jpg", "left.jpg", "right.jpg", "top.jpg"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("hull.obj").path))

        let m = try JSONDecoder().decode(Measurements.self, from: Data(contentsOf: out.appendingPathComponent("measurements.json")))
        XCTAssertEqual(m.status, "approximate")
        XCTAssertEqual(m.method, "userCylinder")
        XCTAssertEqual(m.usableSilhouettes, 5)
        XCTAssertEqual(m.viewsUsed, 0)
        XCTAssertEqual(m.sizeCm, Size3(width: 14, depth: 14, height: 12))
        XCTAssertEqual(m.confidence, "low")
        XCTAssertNil(m.mesh)
        XCTAssertNil(m.uncertainty)

        let brief = try String(contentsOf: out.appendingPathComponent("brief.md"), encoding: .utf8)
        XCTAssertTrue(brief.contains("大きさ（目安。実測ではありません）"))
        XCTAssertTrue(brief.contains("信頼度は低め"))
        XCTAssertTrue(brief.contains("真上（top）"))
        XCTAssertFalse(brief.contains("_cutout"), "brief must not point at cutouts that were not written")
        XCTAssertFalse(brief.contains("hull.obj` を読み込んで"))
        let index = try JSONDecoder().decode(PackIndex.self, from: Data(contentsOf: out.appendingPathComponent("pack.json")))
        XCTAssertEqual(index.views.map(\.name), ["front", "right", "back", "left", "top"])
        XCTAssertTrue(index.views.allSatisfy { $0.cutoutFile == nil })
        XCTAssertEqual(index.provenance.cutouts, false)

        // --cutouts: transparent PNGs next to the photos, and the brief mentions them.
        let builder = PackBuilder(located: located)
        builder.writeCutouts = true
        _ = try builder.build(into: out)
        let withCutouts = try FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent("views").path)
        XCTAssertEqual(withCutouts.filter { $0.hasSuffix("_cutout.png") }.count, 5)
        XCTAssertFalse(withCutouts.contains { $0.hasSuffix("_cutout.jpg") })
        let cut = try ImageOps.loadImage(out.appendingPathComponent("views/front_cutout.png"))
        XCTAssertNotEqual(cut.alphaInfo, .none)
        XCTAssertNotEqual(cut.alphaInfo, .noneSkipLast)
        XCTAssertTrue(try String(contentsOf: out.appendingPathComponent("brief.md"), encoding: .utf8).contains("_cutout.png"))
    }

    // MARK: - heading-guided capture (guidance heading)

    /// A heading-guided ai5 session on disk: 5 photos (front, right, back, left, top) of a 10 × 6 × 4 cm box around
    /// `center`, recorded with `PhotoRecorder.makeHeadingPhoto`; masks are the projected box (or failed with `masks: false`).
    func writeHeadingSession(root: URL, masks: Bool = true, derivedOnPhone: Bool = false, declaredHeightM: Double? = nil) throws -> LocatedSession {
        let folder = root.appendingPathComponent("sessions/S", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("photos"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("masks"), withIntermediateDirectories: true)
        let W = 320, H = 240
        let K = simd_double3x3(rows: [SIMD3(280, 0, 160), SIMD3(0, 280, 120), SIMD3(0, 0, 1)])
        let center = SIMD3<Double>(0.1, -0.2, -0.4)
        func lookAt(_ p: SIMD3<Double>) -> simd_double4x4 {
            let f = simd_normalize(center - p)
            var r = simd_cross(f, SIMD3(0, 1, 0))
            if simd_length(r) < 1e-6 { r = SIMD3(1, 0, 0) }
            r = simd_normalize(r)
            let u = simd_cross(r, f)
            return simd_double4x4(columns: (SIMD4(r, 0), SIMD4(u, 0), SIMD4(-f, 0), SIMD4(p, 1)))
        }
        var s = CaptureSession(sessionId: "S", title: "はこ", createdAt: Date(timeIntervalSince1970: 0),
                               device: DeviceInfo(model: "", systemName: "iOS", systemVersion: "", appVersion: "", appBuild: ""),
                               directionPlan: DirectionPlanPreset.ai5.plan, workKind: .object, guidance: .heading,
                               declaredSize: DeclaredSize(heightM: declaredHeightM))
        var frontHeading: Double?
        for (i, (az, el)) in [(0.0, 15.0), (90, 15), (180, 15), (270, 15), (30, 86)].enumerated() {
            let a = az * .pi / 180, e = el * .pi / 180
            let m = lookAt(center + 0.35 * SIMD3(sin(a) * cos(e), sin(e), cos(a) * cos(e)))
            let frame = CapturedFrameInfo(cameraToWorld: m, intrinsics: K, intrinsicsResolution: PixelSize(width: W, height: H),
                                          imageSize: PixelSize(width: W, height: H), timestamp: Double(i), exposureDuration: nil, exposureOffset: nil,
                                          trackingState: .normal, trackingReason: nil)
            let context = CaptureContext(trigger: i == 0 ? .manual : .auto, referenceFrameId: s.referenceFrames.last?.id, liveQuality: .unknown,
                                         deviceOrientation: "landscapeLeft", displayRotationDegClockwise: 0, capturedAt: Date(timeIntervalSince1970: Double(i)))
            var p = PhotoRecorder.makeHeadingPhoto(in: &s, photoId: Self.pid(i + 1), sequence: i + 1, frame: frame, context: context)
            frontHeading = frontHeading ?? s.referenceFrames.last?.heading?.frontHeadingDeg
            XCTAssertNotNil(p.direction.targetId, "photo \(i)")
            p.quality.saved = SavedQuality(meanLuma: 0.5, sharpness: 0.01, brightness: .ok, blur: .ok)
            try ImageOps.writeJPEG(ImageOps.makeGrayImage(GrayImage(width: W, height: H, fill: 150))!, to: folder.appendingPathComponent(p.image.file))
            if masks {
                let o2w = HeadingDeriver.objectToWorld(center: center, frontHeadingDeg: frontHeading!, originY: center.y)
                let camera = CameraModel(cameraToWorld: m, intrinsics: K, imageWidth: Double(W), imageHeight: Double(H))
                var xs: [Double] = [], ys: [Double] = []
                for c in 0..<8 {
                    let q = o2w * SIMD4(c & 1 == 0 ? -0.05 : 0.05, c & 2 == 0 ? -0.02 : 0.02, c & 4 == 0 ? -0.03 : 0.03, 1)
                    let px = camera.project(SIMD3(q.x, q.y, q.z))!
                    xs.append(px.x); ys.append(px.y)
                }
                var mask = GrayImage(width: W, height: H)
                for y in Int(ys.min()!.rounded())..<Int(ys.max()!.rounded()) { for x in Int(xs.min()!.rounded())..<Int(xs.max()!.rounded()) { mask[x, y] = 255 } }
                try ImageOps.writePNG(ImageOps.makeGrayImage(mask)!, to: folder.appendingPathComponent(Photo.maskPath(photoId: p.photoId)))
                p.mask = MaskInfo(status: .candidate, file: Photo.maskPath(photoId: p.photoId), width: W, height: H, method: MaskInfo.visionMethod,
                                  instanceCount: 1, selectedInstances: [1], selection: .auto, check: MaskCheck(status: .ok, reasons: []))
                    .recording(MaskCropPlanner.crosshairPlan(imageWidth: W, imageHeight: H))
            } else {
                p.mask = .failed("noObject")
            }
            s.photos.append(p)
        }
        if derivedOnPhone {
            HeadingSizer.refresh(session: &s) { photo in
                guard let f = photo.mask.file, let m = try? ImageOps.loadMask(folder.appendingPathComponent(f)) else { return nil }
                return MaskBounds.of(pixels: m.pixels, width: m.width, height: m.height)
            }
        }
        return LocatedSession(folder: folder, dataDir: root, session: s, receipt: nil)
    }

    func testHeadingPackageDerivesCenterAndApproximateSize() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pack-heading-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let located = try writeHeadingSession(root: root)
        XCTAssertNil(located.session.referenceFrames.last?.heading?.derivation)  // not derived on the "phone"
        let out = root.appendingPathComponent("for_claude/S", isDirectory: true)
        let summary = try PackBuilder(located: located).build(into: out)
        XCTAssertTrue(summary.contains("derived after capture"), summary)
        // The session folder is never written.
        let onDisk = try? Data(contentsOf: located.folder.appendingPathComponent("session.json"))
        XCTAssertNil(onDisk)

        let files = try FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent("views").path).sorted()
        XCTAssertEqual(files, ["back.jpg", "front.jpg", "left.jpg", "right.jpg", "top.jpg"])
        let m = try JSONDecoder().decode(Measurements.self, from: Data(contentsOf: out.appendingPathComponent("measurements.json")))
        XCTAssertEqual(m.method, "headingDerived")
        XCTAssertEqual(m.status, "approximate")
        let h = try XCTUnwrap(m.heading)
        XCTAssertEqual(h.computedBy, "memoria-pack")
        XCTAssertEqual(h.derivationStatus, "ok")
        XCTAssertEqual(h.origin, "center")
        XCTAssertLessThan(h.residualRmsM!, 0.001)
        let size = try XCTUnwrap(h.size)
        XCTAssertEqual(size.lowerM!.widthM, 0.10, accuracy: 0.01)
        XCTAssertEqual(size.lowerM!.depthM, 0.06, accuracy: 0.01)
        XCTAssertEqual(size.lowerM!.heightM, 0.04, accuracy: 0.01)
        let s = try XCTUnwrap(m.sizeM)
        XCTAssertGreaterThanOrEqual(s.width, size.lowerM!.widthM - 1e-6)
        XCTAssertLessThanOrEqual(s.width, size.upperM!.widthM + 1e-6)
        XCTAssertNotNil(m.confidence)
        XCTAssertNil(m.mesh)
        XCTAssertTrue(m.frame["origin"]!.contains("NOT the bottom"))

        let index = try JSONDecoder().decode(PackIndex.self, from: Data(contentsOf: out.appendingPathComponent("pack.json")))
        XCTAssertEqual(index.guidance, "heading")
        XCTAssertEqual(index.views.map(\.name), ["front", "right", "back", "left", "top"])
        XCTAssertTrue(index.views.allSatisfy { $0.cropSource == "maskBoundingBox" })
        let brief = try String(contentsOf: out.appendingPathComponent("brief.md"), encoding: .utf8)
        XCTAssertTrue(brief.contains("撮ったあとに写真から求めた値"))
        XCTAssertTrue(brief.contains("机の高さは分かりません"))
        XCTAssertTrue(brief.contains("Mac の memoria-pack"))
        XCTAssertFalse(brief.contains("円柱"))

        // Derived on the phone: the pack uses it as is.
        let phone = try writeHeadingSession(root: root.appendingPathComponent("phone"), derivedOnPhone: true)
        XCTAssertNotNil(phone.session.referenceFrames.last?.heading?.derivation?.size)
        let out2 = root.appendingPathComponent("phone/for_claude/S", isDirectory: true)
        _ = try PackBuilder(located: phone).build(into: out2)
        let m2 = try JSONDecoder().decode(Measurements.self, from: Data(contentsOf: out2.appendingPathComponent("measurements.json")))
        XCTAssertEqual(m2.heading?.computedBy, "iPhone")
        XCTAssertEqual(m2.sizeM, m.sizeM)
    }

    func testHeadingPackageWithoutMasksHasNoSizeAndCentredCrops() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pack-heading-nomask-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let located = try writeHeadingSession(root: root, masks: false)
        let out = root.appendingPathComponent("for_claude/S", isDirectory: true)
        let summary = try PackBuilder(located: located).build(into: out)
        XCTAssertTrue(summary.contains("size unavailable"), summary)
        let m = try JSONDecoder().decode(Measurements.self, from: Data(contentsOf: out.appendingPathComponent("measurements.json")))
        XCTAssertEqual(m.method, "headingDerived")
        XCTAssertEqual(m.status, "unavailable")
        XCTAssertNil(m.sizeM)
        XCTAssertEqual(m.heading?.size?.status, "unknown")
        XCTAssertNotNil(m.heading?.centerWorld)  // the centre needs only the poses
        let index = try JSONDecoder().decode(PackIndex.self, from: Data(contentsOf: out.appendingPathComponent("pack.json")))
        XCTAssertTrue(index.views.allSatisfy { $0.cropSource == "crosshairCenter" }, "\(index.views.map(\.cropSource))")
        let brief = try String(contentsOf: out.appendingPathComponent("brief.md"), encoding: .utf8)
        XCTAssertTrue(brief.contains("大きさ（分かりません）"))
    }

    // MARK: - flat artwork (workKind flat, plan flat1)

    func flatPhoto(_ seq: Int, el: Double = 86, rectified: Bool, corners: Bool = true, size: Bool = true, W: Int = 64, H: Int = 48) -> Photo {
        var p = photo(seq, az: 0, el: el, frame: nil, target: el >= 70 ? "top-e90" : nil, mask: .notGenerated)
        p.direction.azimuthDeg = nil
        p.image.width = W
        p.image.height = H
        p.camera.intrinsicsResolution = PixelSize(width: W, height: H)
        p.mask = .notGenerated
        let quad = FlatQuad(topLeft: PixelPoint(x: 8, y: 40), topRight: PixelPoint(x: 8, y: 6),
                            bottomRight: PixelPoint(x: 56, y: 6), bottomLeft: PixelPoint(x: 56, y: 40))
        p.flat = FlatPhotoInfo(
            corners: corners ? quad : nil, cornersMethod: corners ? FlatPhotoInfo.visionMethod : nil, cornersConfidence: corners ? 0.95 : nil,
            sheetAtFrameEdge: corners ? false : nil,
            size: size && corners ? FlatSheetSize(widthM: 0.21, heightM: 0.297, planeSource: "estimatedPlane") : nil,
            rectified: rectified ? FlatRectifiedImage(file: Photo.rectifiedPath(photoId: Self.pid(seq)), width: 34, height: 48) : nil)
        return p
    }

    func flatSession(_ photos: [Photo], declared: DeclaredSheet? = nil) -> CaptureSession {
        var s = CaptureSession(sessionId: "S", title: "えのぐの絵", createdAt: Date(timeIntervalSince1970: 0),
                               device: DeviceInfo(model: "", systemName: "iOS", systemVersion: "", appVersion: "", appBuild: ""),
                               directionPlan: DirectionPlanPreset.flat1.plan, workKind: .flat, declaredSize: DeclaredSize(sheet: declared))
        s.photos = photos
        return s
    }

    func testFlatPhotoChoicePrefersTheLatestOverheadShot() {
        let s = flatSession([flatPhoto(1, rectified: true), flatPhoto(2, rectified: true), flatPhoto(3, el: 50, rectified: true)])
        // #1 is superseded by #2; #3 was not shot from above.
        XCTAssertEqual(PackBuilder.chooseFlatPhoto(session: s)?.photoId, Self.pid(2))
        XCTAssertEqual(PackBuilder.chooseFlatPhoto(session: flatSession([flatPhoto(1, el: 50, rectified: true)]))?.photoId, Self.pid(1))
        XCTAssertNil(PackBuilder.chooseFlatPhoto(session: flatSession([])))
    }

    func writeFlatSession(_ photos: [Photo], root: URL, declared: DeclaredSheet? = nil) throws -> LocatedSession {
        let folder = root.appendingPathComponent("sessions/S", isDirectory: true)
        for sub in ["photos", "rectified"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        for p in photos {
            try ImageOps.writeJPEG(ImageOps.makeGrayImage(GrayImage(width: p.image.width, height: p.image.height, fill: 120))!,
                                   to: folder.appendingPathComponent(p.image.file))
            if let r = p.flat?.rectified {
                try ImageOps.writeJPEG(ImageOps.makeGrayImage(GrayImage(width: r.width, height: r.height, fill: 230))!,
                                       to: folder.appendingPathComponent(r.file))
            }
        }
        return LocatedSession(folder: folder, dataDir: root, session: flatSession(photos, declared: declared), receipt: nil)
    }

    func testFlatPackageWithRectifiedImageAndSize() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pack-flat-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let located = try writeFlatSession([flatPhoto(1, rectified: true)], root: root)
        let out = root.appendingPathComponent("for_claude/S", isDirectory: true)
        let summary = try PackBuilder(located: located).build(into: out)
        XCTAssertTrue(summary.contains("flat artwork"), summary)
        XCTAssertTrue(summary.contains("21.0 × 29.7 cm"), summary)

        let top = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
        XCTAssertEqual(top, ["brief.md", "measurements.json", "pack.json", "views"])  // no overview.jpg, no hull.obj
        let views = try FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent("views").path).sorted()
        XCTAssertEqual(views, ["artwork.jpg", "photo.jpg"])
        let artwork = try ImageOps.loadImage(out.appendingPathComponent("views/artwork.jpg"))
        XCTAssertEqual([artwork.width, artwork.height], [34, 48])  // the rectified image as is (already upright)
        let photo = try ImageOps.loadImage(out.appendingPathComponent("views/photo.jpg"))
        XCTAssertEqual([photo.width, photo.height], [48, 64])  // the original turned 90° clockwise

        let m = try JSONDecoder().decode(Measurements.self, from: Data(contentsOf: out.appendingPathComponent("measurements.json")))
        XCTAssertEqual(m.workKind, "flat")
        XCTAssertEqual(m.status, "ok")
        XCTAssertEqual(m.method, "flatSheetCorners")
        XCTAssertEqual(m.sheet?.source, "measured")
        XCTAssertEqual(m.sheet?.widthCm, 21)
        XCTAssertEqual(m.sheet?.heightCm, 29.7)
        XCTAssertEqual(m.sheet?.planeSource, "estimatedPlane")
        XCTAssertEqual(m.sheet?.measured?.widthCm, 21)
        XCTAssertNil(m.sheet?.declaredSheetId)
        XCTAssertNil(m.sizeCm)
        XCTAssertNil(m.mesh)

        let index = try JSONDecoder().decode(PackIndex.self, from: Data(contentsOf: out.appendingPathComponent("pack.json")))
        XCTAssertEqual(index.workKind, "flat")
        XCTAssertEqual(index.views.map(\.name), ["artwork", "photo"])
        XCTAssertEqual(index.views[0].cropSource, "rectified")
        XCTAssertEqual(index.flat?.artworkSource, "rectified")
        XCTAssertEqual(index.flat?.rectifiedInSession, "rectified/\(Self.pid(1)).jpg")
        XCTAssertEqual(index.flat?.cameraTiltFromVerticalDeg, 4)
        XCTAssertEqual(index.coverage.directionPlanId, "flat1")
        XCTAssertFalse(index.files.contains("overview.jpg"))
        XCTAssertTrue(index.maskIssues.isEmpty)

        let brief = try String(contentsOf: out.appendingPathComponent("brief.md"), encoding: .utf8)
        XCTAssertTrue(brief.contains("これは平面の作品（絵・貼り絵など）です。"))
        XCTAssertTrue(brief.contains("3D の形を推論・再構成する必要はありません"))
        XCTAssertTrue(brief.contains("| 21.0 cm | 29.7 cm |"))
        XCTAssertFalse(brief.contains("overview.jpg"))
        XCTAssertFalse(brief.contains("hull.obj"))
        XCTAssertFalse(brief.contains("分かりません"))
        // up to date: the same manifest hash would skip; a missing receipt never does
        XCTAssertFalse(Runner.isUpToDate(out, manifestHash: "x", cutouts: false))
    }

    func testFlatPackageWithoutSheetSaysSizeIsUnknown() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pack-flat-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let located = try writeFlatSession([flatPhoto(1, rectified: false, corners: false)], root: root)
        let out = root.appendingPathComponent("for_claude/S", isDirectory: true)
        let summary = try PackBuilder(located: located).build(into: out)
        XCTAssertTrue(summary.contains("sheet size unknown"), summary)
        let views = try FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent("views").path).sorted()
        XCTAssertEqual(views, ["artwork.jpg"])
        let artwork = try ImageOps.loadImage(out.appendingPathComponent("views/artwork.jpg"))
        XCTAssertEqual([artwork.width, artwork.height], [48, 64])  // the upright original
        let m = try JSONDecoder().decode(Measurements.self, from: Data(contentsOf: out.appendingPathComponent("measurements.json")))
        XCTAssertEqual(m.status, "unavailable")
        XCTAssertNil(m.sheet)
        XCTAssertEqual(m.unavailableReason, "no sheet (rectangle) was detected in the photo")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: out.appendingPathComponent("measurements.json"))) as! [String: Any]
        XCTAssertTrue(obj["sheet"] is NSNull)
        let index = try JSONDecoder().decode(PackIndex.self, from: Data(contentsOf: out.appendingPathComponent("pack.json")))
        XCTAssertEqual(index.flat?.artworkSource, "uprightPhoto")
        XCTAssertNil(index.flat?.corners)
        XCTAssertTrue(index.views[0].notes.contains { $0.contains("no sheet was detected") })
        let brief = try String(contentsOf: out.appendingPathComponent("brief.md"), encoding: .utf8)
        XCTAssertTrue(brief.contains("**大きさは分かりません**"))
        XCTAssertTrue(brief.contains("遠近を直していない"))
        XCTAssertTrue(brief.contains("3D の形を推論・再構成する必要はありません"))
    }

    // MARK: - declared size (declaredSize: the paper picked from the list, the height typed in)

    func testFlatPackagePrefersTheDeclaredSheet() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pack-flat-declared-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // The rectified image is 34 × 48 (portrait) and the ARKit measurement says 21 × 29.7 cm; the person picked 八つ切.
        let located = try writeFlatSession([flatPhoto(1, rectified: true)], root: root, declared: DeclaredSheet(.yatsugiri))
        let out = root.appendingPathComponent("for_claude/S", isDirectory: true)
        let summary = try PackBuilder(located: located).build(into: out)
        XCTAssertTrue(summary.contains("27.1 × 39.2 cm (declared)"), summary)

        let m = try JSONDecoder().decode(Measurements.self, from: Data(contentsOf: out.appendingPathComponent("measurements.json")))
        XCTAssertEqual(m.status, "ok")
        XCTAssertEqual(m.method, "declaredSheet")
        let sheet = try XCTUnwrap(m.sheet)
        XCTAssertEqual(sheet.source, "declared")
        XCTAssertEqual(sheet.declaredSheetId, "yatsugiri")
        XCTAssertEqual(sheet.declaredSheetName, "八つ切")
        XCTAssertEqual(sheet.orientation, "portrait")
        XCTAssertEqual(sheet.widthCm, 27.1)
        XCTAssertEqual(sheet.heightCm, 39.2)
        XCTAssertEqual(sheet.longSideCm, 39.2)
        XCTAssertEqual(sheet.shortSideCm, 27.1)
        XCTAssertNil(sheet.planeSource)
        XCTAssertEqual(sheet.measured?.widthCm, 21)  // the measurement is kept next to it
        XCTAssertEqual(sheet.measured?.planeSource, "estimatedPlane")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: out.appendingPathComponent("measurements.json"))) as! [String: Any]
        XCTAssertEqual((obj["sheet"] as? [String: Any])?["source"] as? String, "declared")

        let brief = try String(contentsOf: out.appendingPathComponent("brief.md"), encoding: .utf8)
        XCTAssertTrue(brief.contains("| 27.1 cm | 39.2 cm | 撮る人が一覧から選んだ紙の大きさ（八つ切） |"), brief)
        XCTAssertTrue(brief.contains("撮る人が一覧から選んだ値（八つ切"))
        XCTAssertTrue(brief.contains("参考：紙の四隅を ARKit の平面"))
        XCTAssertFalse(brief.contains("**大きさは分かりません**"))
    }

    func testFlatPackageDeclaredSheetWithoutCornersHasNoOrientation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pack-flat-declared-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let located = try writeFlatSession([flatPhoto(1, rectified: false, corners: false)], root: root, declared: DeclaredSheet(.a4))
        let out = root.appendingPathComponent("for_claude/S", isDirectory: true)
        let summary = try PackBuilder(located: located).build(into: out)
        XCTAssertTrue(summary.contains("29.7 × 21.0 cm (declared, orientation unknown)"), summary)
        let m = try JSONDecoder().decode(Measurements.self, from: Data(contentsOf: out.appendingPathComponent("measurements.json")))
        XCTAssertEqual(m.status, "ok")
        let sheet = try XCTUnwrap(m.sheet)
        XCTAssertNil(sheet.widthM)
        XCTAssertNil(sheet.heightCm)
        XCTAssertNil(sheet.orientation)
        XCTAssertNil(sheet.measured)
        XCTAssertEqual(sheet.longSideM, 0.297)
        XCTAssertEqual(sheet.shortSideM, 0.21)
        let brief = try String(contentsOf: out.appendingPathComponent("brief.md"), encoding: .utf8)
        XCTAssertTrue(brief.contains("縦・横の向きは分かりません"))
        XCTAssertFalse(brief.contains("**大きさは分かりません**"))
    }

    func testResolveSheetOrientsTheDeclaredSheetByTheCorners() throws {
        // Corners as seen upright: 34 px wide, 48 px tall (portrait); no rectified image.
        let p = flatPhoto(1, rectified: false, size: false)
        let declared = try XCTUnwrap(PackBuilder.resolveSheet(session: flatSession([p], declared: DeclaredSheet(.b4)), photo: p, artworkIsRectified: false))
        XCTAssertEqual(declared.widthM, 0.257)
        XCTAssertEqual(declared.heightM, 0.364)
        XCTAssertEqual(declared.orientation, "portrait")
        // Neither declared nor measured: nil.
        XCTAssertNil(PackBuilder.resolveSheet(session: flatSession([p]), photo: p, artworkIsRectified: false))
        // Measured only.
        let measured = flatPhoto(2, rectified: false)
        let sheet = try XCTUnwrap(PackBuilder.resolveSheet(session: flatSession([measured]), photo: measured, artworkIsRectified: false))
        XCTAssertEqual(sheet.source, "measured")
        XCTAssertEqual(sheet.widthM, 0.21)
        XCTAssertEqual(sheet.planeSource, "estimatedPlane")
    }

    func testHeadingPackageCarriesTheDeclaredHeight() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pack-heading-declared-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let located = try writeHeadingSession(root: root, declaredHeightM: 0.12)
        let out = root.appendingPathComponent("for_claude/S", isDirectory: true)
        _ = try PackBuilder(located: located).build(into: out)
        let m = try JSONDecoder().decode(Measurements.self, from: Data(contentsOf: out.appendingPathComponent("measurements.json")))
        let d = try XCTUnwrap(m.declaredHeight)
        XCTAssertEqual(d.heightM, 0.12)
        XCTAssertEqual(d.heightCm, 12)
        XCTAssertEqual(d.source, "userEntered")
        // The derived size is written as derived (not rescaled to the declared height).
        XCTAssertEqual(try XCTUnwrap(m.heading?.size?.lowerM).heightM, 0.04, accuracy: 0.01)
        XCTAssertEqual(m.method, "headingDerived")
        let brief = try String(contentsOf: out.appendingPathComponent("brief.md"), encoding: .utf8)
        XCTAssertTrue(brief.contains("## 高さ（撮る人が入力した値）"))
        XCTAssertTrue(brief.contains("**高さは 12.0 cm です。**"))
        XCTAssertTrue(brief.contains("この高さを優先してください"))
        XCTAssertTrue(brief.contains("撮ったあとに写真から求めた値"))

        // Without a declared height the field is null.
        let plain = try writeHeadingSession(root: root.appendingPathComponent("plain"))
        let out2 = root.appendingPathComponent("plain/for_claude/S", isDirectory: true)
        _ = try PackBuilder(located: plain).build(into: out2)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: out2.appendingPathComponent("measurements.json"))) as! [String: Any]
        XCTAssertTrue(obj["declaredHeight"] is NSNull)
        XCTAssertFalse(try String(contentsOf: out2.appendingPathComponent("brief.md"), encoding: .utf8).contains("撮る人が入力した値"))
    }

    // MARK: - free capture (guidance free, plan free)

    func freePhoto(_ seq: Int, el: Double, W: Int = 64, H: Int = 48) -> Photo {
        var p = photo(seq, az: 0, el: el, frame: nil, target: nil, mask: .notGenerated)
        p.direction.azimuthDeg = nil
        p.direction.distanceM = nil
        p.image.width = W
        p.image.height = H
        p.camera.intrinsicsResolution = PixelSize(width: W, height: H)
        return p
    }

    func writeFreeSession(_ photos: [Photo], root: URL, declaredHeightM: Double? = nil) throws -> LocatedSession {
        let folder = root.appendingPathComponent("sessions/S", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("photos"), withIntermediateDirectories: true)
        for p in photos {
            try ImageOps.writeJPEG(ImageOps.makeGrayImage(GrayImage(width: p.image.width, height: p.image.height, fill: 140))!,
                                   to: folder.appendingPathComponent(p.image.file))
        }
        var s = CaptureSession(sessionId: "S", title: "ねんど", createdAt: Date(timeIntervalSince1970: 0),
                               device: DeviceInfo(model: "", systemName: "iOS", systemVersion: "", appVersion: "", appBuild: ""),
                               directionPlan: DirectionPlanPreset.free.plan, workKind: .object, guidance: .free,
                               declaredSize: DeclaredSize(heightM: declaredHeightM))
        s.photos = photos
        return LocatedSession(folder: folder, dataDir: root, session: s, receipt: nil)
    }

    func testChooseFreePhotosKeepsOrderAndSpreadsEvenly() {
        let few = CaptureSession(sessionId: "S", title: "", createdAt: Date(timeIntervalSince1970: 0),
                                 device: DeviceInfo(model: "", systemName: "iOS", systemVersion: "", appVersion: "", appBuild: ""),
                                 directionPlan: DirectionPlanPreset.free.plan, workKind: .object, guidance: .free)
        var s = few
        s.photos = [freePhoto(3, el: 10), freePhoto(1, el: 20), freePhoto(2, el: 30)]
        XCTAssertEqual(PackBuilder.chooseFreePhotos(session: s).map(\.sequence), [1, 2, 3])
        s.photos = (1...40).map { freePhoto($0, el: 20) }
        let chosen = PackBuilder.chooseFreePhotos(session: s).map(\.sequence)
        XCTAssertEqual(chosen.count, PackBuilder.maxFreeViews)
        XCTAssertEqual(chosen.first, 1)
        XCTAssertEqual(chosen.last, 40)
        XCTAssertEqual(chosen, chosen.sorted())
        XCTAssertEqual(Set(chosen).count, chosen.count)
        XCTAssertTrue(PackBuilder.chooseFreePhotos(session: few).isEmpty)
    }

    func testFreePackage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pack-free-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let located = try writeFreeSession([freePhoto(1, el: 18), freePhoto(2, el: 25), freePhoto(3, el: 82)], root: root, declaredHeightM: 0.08)
        let out = root.appendingPathComponent("for_claude/S", isDirectory: true)
        let summary = try PackBuilder(located: located).build(into: out)
        XCTAssertTrue(summary.contains("free capture, 3/3 photos"), summary)
        XCTAssertTrue(summary.contains("declared height 8.0 cm"), summary)

        let top = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
        XCTAssertEqual(top, ["brief.md", "measurements.json", "pack.json", "views"])  // no overview.jpg, no hull.obj
        let views = try FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent("views").path).sorted()
        XCTAssertEqual(views, ["photo-01.jpg", "photo-02.jpg", "photo-03.jpg"])
        let first = try ImageOps.loadImage(out.appendingPathComponent("views/photo-01.jpg"))
        XCTAssertEqual([first.width, first.height], [48, 64])  // turned 90° clockwise

        let m = try JSONDecoder().decode(Measurements.self, from: Data(contentsOf: out.appendingPathComponent("measurements.json")))
        XCTAssertEqual(m.method, "freeCapture")
        XCTAssertEqual(m.status, "unavailable")
        XCTAssertNil(m.sizeM)
        XCTAssertNil(m.sheet)
        XCTAssertEqual(m.declaredHeight?.heightCm, 8)

        let index = try JSONDecoder().decode(PackIndex.self, from: Data(contentsOf: out.appendingPathComponent("pack.json")))
        XCTAssertEqual(index.workKind, "object")
        XCTAssertEqual(index.guidance, "free")
        XCTAssertEqual(index.free, PackIndex.FreeSource(photoCount: 3, viewCount: 3, selection: "all"))
        XCTAssertEqual(index.views.map(\.name), ["photo-01", "photo-02", "photo-03"])
        XCTAssertEqual(index.views.map(\.elevationDeg), [18, 25, 82])
        XCTAssertTrue(index.views.allSatisfy { $0.azimuthDeg == nil && $0.cropSource == "fullImage" })
        XCTAssertEqual(index.coverage.directionPlanId, "free")
        XCTAssertFalse(index.files.contains("overview.jpg"))

        let brief = try String(contentsOf: out.appendingPathComponent("brief.md"), encoding: .utf8)
        XCTAssertTrue(brief.contains("案内なしで自由に撮った写真 3 枚"))
        XCTAssertTrue(brief.contains("写真を見て判断してください"))
        XCTAssertTrue(brief.contains("**高さは 8.0 cm です。**"))
        XCTAssertTrue(brief.contains("| `views/photo-03.jpg` | #3 | 82° |"), brief)
        XCTAssertFalse(brief.contains("**大きさは分かりません**"))
    }

    func testFreePackageWithoutHeightSaysSizeIsUnknown() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pack-free-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let located = try writeFreeSession((1...20).map { freePhoto($0, el: 20) }, root: root)
        let out = root.appendingPathComponent("for_claude/S", isDirectory: true)
        let summary = try PackBuilder(located: located).build(into: out)
        XCTAssertTrue(summary.contains("16/20 photos"), summary)
        XCTAssertTrue(summary.contains("size unknown"), summary)
        let m = try JSONDecoder().decode(Measurements.self, from: Data(contentsOf: out.appendingPathComponent("measurements.json")))
        XCTAssertNil(m.declaredHeight)
        let index = try JSONDecoder().decode(PackIndex.self, from: Data(contentsOf: out.appendingPathComponent("pack.json")))
        XCTAssertEqual(index.free?.selection, "evenlySpaced")
        XCTAssertEqual(index.views.count, 16)
        let brief = try String(contentsOf: out.appendingPathComponent("brief.md"), encoding: .utf8)
        XCTAssertTrue(brief.contains("**大きさは分かりません**"))
        XCTAssertTrue(brief.contains("均等に 16 枚"))
    }

    func testFlatPackageNamesTheCustomSheet() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pack-flat-custom-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let custom = try XCTUnwrap(DeclaredSheet.custom(fromCentimetres: "30", "21"))
        let located = try writeFlatSession([flatPhoto(1, rectified: true)], root: root, declared: custom)
        let out = root.appendingPathComponent("for_claude/S", isDirectory: true)
        _ = try PackBuilder(located: located).build(into: out)
        let m = try JSONDecoder().decode(Measurements.self, from: Data(contentsOf: out.appendingPathComponent("measurements.json")))
        XCTAssertEqual(m.sheet?.declaredSheetId, "custom")
        XCTAssertEqual(m.sheet?.declaredSheetName, "その他")
        XCTAssertEqual(m.sheet?.widthCm, 21)   // portrait rectified image (34 × 48)
        XCTAssertEqual(m.sheet?.heightCm, 30)
        let brief = try String(contentsOf: out.appendingPathComponent("brief.md"), encoding: .utf8)
        XCTAssertTrue(brief.contains("| 21.0 cm | 30.0 cm | 撮る人が入力した紙の大きさ（その他） |"), brief)
    }

    func testObjectPackIndexCarriesWorkKind() throws {
        let s = session([photo(1, az: 2, el: 21)])
        let index = PackIndex(workKind: s.workKind.rawValue, provenance: .init(sessionId: "S", generatedAt: "", tool: "", toolVersion: "", sourceFolder: ""),
                              title: "", views: [], coverage: .init(referenceFrameIds: [], photoCount: 0, photosInReferenceFrame: 0, directionPlanId: "", bands: [], missingViews: [], weakViews: []),
                              maskIssues: [], files: [], timingsS: [:])
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(index)) as! [String: Any]
        XCTAssertEqual(obj["workKind"] as? String, "object")
        XCTAssertNil(obj["flat"])
        // packages written before 0.3.0 have no workKind and still decode
        var old = obj
        old.removeValue(forKey: "workKind")
        XCTAssertNil(try JSONDecoder().decode(PackIndex.self, from: JSONSerialization.data(withJSONObject: old)).workKind)
    }
}
