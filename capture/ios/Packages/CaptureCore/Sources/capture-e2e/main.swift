// capture-e2e：小さな合成セッションを作って、受信側（receiver/memoria_receiver.py）へ送る確認ツール（macOS）。
//
//   swift run capture-e2e http://127.0.0.1:8765 123456 [--keep] [--flat [--sheet=<紙の id>] | --heading [--height-cm=<高さ>] | --free [--height-cm=<高さ>]]
//
// 1. 一時フォルダに SessionStore で合成セッション（写真 3 枚・マスク 2 枚）を作る
//    --flat のときは平面の作品のセッション（workKind flat・flat1。真上の写真 1 枚・用紙の四隅・実寸・補正した画像）
//      --sheet=yatsugiri などで、撮る人が選んだ紙（declaredSize.sheet。id は SheetPreset）も付ける
//    --heading のときは向きで案内した立体のセッション（guidance heading・ai5。5 枚・十字のまわりのマスク・撮ったあとに求めた中心と大きさ）
//      --height-cm=12 などで、撮る人が入力した高さ（declaredSize.heightM）も付ける
//    --free のときは自由に撮った立体のセッション（guidance free・一覧 free。4 枚・基準もマスクも無し）。--height-cm も使える
//    どちらのオプションも付けなければ declaredSize は null（今までどおり）
// 2. 送る → complete を期待
// 3. もう一度送る → alreadyComplete を期待
// 4. 作品名を変えて送る → 新しい manifestHash で complete を期待（受信側は前の版を replaced/ へ）
// 失敗したら 0 以外で終わる。

import CaptureCore
import Foundation
import simd

#if os(macOS)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
}

func encodeImage(width: Int, height: Int, gray: Bool, type: UTType, draw: (CGContext) -> Void) -> Data {
    let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
    let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info) else {
        fail("CGContext")
    }
    draw(context)
    guard let image = context.makeImage() else { fail("makeImage") }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { fail("CGImageDestination") }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { fail("finalize") }
    return data as Data
}

let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }
let keep = CommandLine.arguments.contains("--keep")
let flatMode = CommandLine.arguments.contains("--flat")
let headingMode = CommandLine.arguments.contains("--heading")
let freeMode = CommandLine.arguments.contains("--free")
let usage = "使い方: capture-e2e <受信側の URL（http://IP:port）> <ペアリングコード> [--keep] [--flat [--sheet=<紙の id>] | --heading [--height-cm=<高さ>] | --free [--height-cm=<高さ>]]"
guard args.count >= 2, let receiverURL = TransferClient.receiverURL(fromUserInput: args[args.startIndex]) else {
    print(usage)
    exit(2)
}

/// `--name=value` の value（無ければ nil）。
func optionValue(_ name: String) -> String? {
    let prefix = "--\(name)="
    return CommandLine.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
}

/// 撮る人が選んだ紙（--sheet=<id>）。--flat のときだけ使う。
let declaredSheet: DeclaredSheet? = {
    guard let id = optionValue("sheet") else { return nil }
    guard let preset = SheetPreset(rawValue: id) else {
        print("--sheet は \(SheetPreset.allCases.map(\.rawValue).joined(separator: " / ")) のどれかです（\(id)）")
        exit(2)
    }
    return DeclaredSheet(preset)
}()
/// 撮る人が入力した高さ（--height-cm=<cm>）。--heading・--free のときだけ使う。
let declaredHeightM: Double? = {
    guard let text = optionValue("height-cm") else { return nil }
    guard let height = DeclaredSize.heightM(fromCentimetres: text) else {
        print("--height-cm は \(DeclaredSize.minimumHeightCm)〜\(DeclaredSize.maximumHeightCm) の数です（\(text)）")
        exit(2)
    }
    return height
}()
if declaredSheet != nil && !flatMode { print("注意: --sheet は --flat のときだけ使います（無視します）") }
if declaredHeightM != nil && !headingMode && !freeMode { print("注意: --height-cm は --heading・--free のときだけ使います（無視します）") }
let token = args[args.startIndex + 1]

let root = FileManager.default.temporaryDirectory.appendingPathComponent("capture-e2e-\(UUID().uuidString)")
let store = SessionStore(rootDirectory: root)
print("一時フォルダ: \(root.path)")

let device = DeviceInfo(model: "Mac-e2e", systemName: "macOS", systemVersion: ProcessInfo.processInfo.operatingSystemVersionString, appVersion: "0.1.0", appBuild: "1")
var session: CaptureSession
if flatMode {
    session = makeFlatSession()
} else if headingMode {
    session = makeHeadingSession()
} else if freeMode {
    session = makeFreeSession()
} else {
    session = makeObjectSession()
}
let sessionId = session.sessionId

/// 自由に撮った立体：作品（原点）のまわりの 3 方向と真上に近い 1 枚（0.35 m）。基準・マスクは無く、向きは傾きだけ。
func makeFreeSession() -> CaptureSession {
    var session: CaptureSession
    do {
        session = try store.createSession(title: "e2e 自由に撮る", device: device, plan: DirectionPlanPreset.free.plan, workKind: .object,
                                          guidance: .free, declaredSize: DeclaredSize(heightM: declaredHeightM))
    } catch {
        fail("セッションを作れません: \(error)")
    }
    let width = 640, height = 480, fx = 560.0
    let intrinsics = simd_double3x3(rows: [SIMD3(fx, 0, Double(width) / 2), SIMD3(0, fx, Double(height) / 2), SIMD3(0, 0, 1)])
    for (i, (az, el)) in [(0.0, 20.0), (120, 25), (240, 15), (40, 80)].enumerated() {
        let a = az * .pi / 180, e = el * .pi / 180
        let position = 0.35 * SIMD3(sin(a) * cos(e), sin(e), cos(a) * cos(e))
        let forward = simd_normalize(-position)
        var right = simd_cross(forward, SIMD3(0, 1, 0))
        if simd_length(right) < 1e-6 { right = SIMD3(1, 0, 0) }
        right = simd_normalize(right)
        let up = simd_cross(right, forward)
        let cameraToWorld = simd_double4x4(columns: (SIMD4(right, 0), SIMD4(up, 0), SIMD4(-forward, 0), SIMD4(position, 1)))
        let jpeg = encodeImage(width: width, height: height, gray: false, type: .jpeg) { c in
            c.setFillColor(CGColor(red: 0.85, green: 0.8, blue: 0.7, alpha: 1))
            c.fill(CGRect(x: 0, y: 0, width: width, height: height))
            c.setFillColor(CGColor(red: 0.3 + 0.15 * Double(i), green: 0.5, blue: 0.3, alpha: 1))
            c.fillEllipse(in: CGRect(x: Double(width) / 2 - 80, y: Double(height) / 2 - 60, width: 160, height: 120))
        }
        let frame = CapturedFrameInfo(
            cameraToWorld: cameraToWorld, intrinsics: intrinsics, intrinsicsResolution: PixelSize(width: width, height: height),
            imageSize: PixelSize(width: width, height: height), timestamp: 300 + Double(i), exposureDuration: 0.01,
            exposureOffset: 0, trackingState: .normal, trackingReason: nil
        )
        let context = CaptureContext(
            trigger: .manual, referenceFrameId: nil, liveQuality: .unknown,
            deviceOrientation: "landscapeLeft", displayRotationDegClockwise: 0, capturedAt: Date()
        )
        let photoId = SessionStore.newId()
        do {
            try store.addPhoto(sessionId: session.sessionId, photoId: photoId, jpegData: jpeg) { s, sequence in
                PhotoRecorder.makeFreePhoto(session: s, photoId: photoId, sequence: sequence, frame: frame, context: context)
            }
            session = try store.loadSession(session.sessionId)
        } catch {
            fail("写真を保存できません: \(error)")
        }
    }
    guard session.usesFreeCapture, session.photos.count == 4, session.photos.allSatisfy({ $0.direction.targetId == nil && $0.mask.status == .notGenerated }),
          Readiness.make(session: session).isComplete else { fail("自由に撮った写真の記録が想定と違います") }
    guard session.declaredHeightM == declaredHeightM else { fail("入力した高さを記録できません") }
    print("自由に撮る：写真 \(session.photos.count) 枚、見下ろす角度 " + session.photos.map { String(format: "%.0f°", $0.direction.elevationDeg ?? -1) }.joined(separator: "・")
          + (session.declaredHeightM.map { String(format: "、入力した高さ %.1f cm", $0 * 100) } ?? "、高さは入力していない"))
    return session
}

/// 平面の作品：真上（0.4 m）から見下ろした写真 1 枚。紙（白）の四隅・実寸（机 y = 0 の平面に当てたもの）・補正した画像。
func makeFlatSession() -> CaptureSession {
    var session: CaptureSession
    do {
        session = try store.createSession(title: "e2e 平面の絵", device: device, plan: DirectionPlanPreset.flat1.plan, workKind: .flat,
                                          declaredSize: DeclaredSize(sheet: declaredSheet))
    } catch {
        fail("セッションを作れません: \(error)")
    }
    let width = 640, height = 480
    let fx = 600.0
    let intrinsics = simd_double3x3(rows: [SIMD3(fx, 0, Double(width) / 2), SIMD3(0, fx, Double(height) / 2), SIMD3(0, 0, 1)])
    // 光軸が真下、センサーの右が −Z。
    let cameraToWorld = simd_double4x4(columns: (SIMD4(0, 0, -1, 0), SIMD4(-1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0.4, 0, 1)))
    let camera = CameraModel(cameraToWorld: cameraToWorld, intrinsics: intrinsics, imageWidth: Double(width), imageHeight: Double(height))
    // 縦長に見える A5 くらいの紙（0.148 × 0.21 m）：画面の上が −Z。
    let world: [SIMD3<Double>] = [SIMD3(-0.074, 0, -0.105), SIMD3(0.074, 0, -0.105), SIMD3(0.074, 0, 0.105), SIMD3(-0.074, 0, 0.105)]
    let pixels = world.map { camera.project($0)! }
    guard let quad = FlatGeometry.orderCorners(pixels, imageWidth: width, imageHeight: height, rotationDegClockwise: 90) else { fail("四隅") }
    let size = FlatGeometry.measureSize(corners: quad, camera: camera, imageSize: PixelSize(width: width, height: height),
                                        planePoint: .zero, planeNormal: SIMD3(0, 1, 0), planeSource: "estimatedPlane")
    guard let size else { fail("実寸を測れません") }
    let box = quad.boundingBox
    let jpeg = encodeImage(width: width, height: height, gray: false, type: .jpeg) { c in
        c.setFillColor(CGColor(red: 0.45, green: 0.35, blue: 0.25, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: width, height: height))
        c.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1))
        c.fill(CGRect(x: box.minX, y: Double(height) - box.maxY, width: box.width, height: box.height))
        c.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1))
        c.fillEllipse(in: CGRect(x: box.midX - 40, y: Double(height) - box.midY - 40, width: 80, height: 80))
    }
    guard session.declaredSheet == declaredSheet else { fail("選んだ紙を記録できません") }
    guard let rs = FlatGeometry.rectifiedSize(corners: quad, size: size, declaredSheet: session.declaredSheet) else { fail("補正した画像の大きさ") }
    let rectified = encodeImage(width: rs.width, height: rs.height, gray: false, type: .jpeg) { c in
        c.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: rs.width, height: rs.height))
        c.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1))
        c.fillEllipse(in: CGRect(x: Double(rs.width) / 2 - 40, y: Double(rs.height) / 2 - 40, width: 80, height: 80))
    }
    let frame = CapturedFrameInfo(
        cameraToWorld: cameraToWorld, intrinsics: intrinsics, intrinsicsResolution: PixelSize(width: width, height: height),
        imageSize: PixelSize(width: width, height: height), timestamp: 100, exposureDuration: 0.01,
        exposureOffset: 0, trackingState: .normal, trackingReason: nil
    )
    let context = CaptureContext(
        trigger: .auto, referenceFrameId: nil, liveQuality: .unknown,
        deviceOrientation: "faceUp", displayRotationDegClockwise: FlatGeometry.displayRotation(deviceOrientation: "faceUp"), capturedAt: Date()
    )
    let flat = FlatPhotoInfo(
        corners: quad, cornersMethod: FlatPhotoInfo.visionMethod, cornersConfidence: 0.98,
        sheetAtFrameEdge: FlatGeometry.touchesFrameEdge(quad, imageWidth: width, imageHeight: height), size: size,
        rectified: FlatRectifiedImage(file: "", width: rs.width, height: rs.height)
    )
    let photoId = SessionStore.newId()
    do {
        try store.addPhoto(sessionId: session.sessionId, photoId: photoId, jpegData: jpeg, rectifiedJPEG: rectified) { s, sequence in
            PhotoRecorder.makeFlatPhoto(session: s, photoId: photoId, sequence: sequence, frame: frame, context: context, flat: flat, distanceM: 0.4)
        }
        session = try store.loadSession(session.sessionId)
    } catch {
        fail("写真を保存できません: \(error)")
    }
    guard let p = session.photos.first, p.direction.targetId == "top-e90", p.flat?.rectified != nil else { fail("平面の写真の記録が想定と違います") }
    print(String(format: "平面の作品：用紙 %.3f × %.3f m、補正した画像 %d × %d", size.widthM, size.heightM, rs.width, rs.height)
          + (session.declaredSheet.map { "、選んだ紙 \($0.id)" } ?? "、紙は選んでいない"))
    return session
}

/// 向きで案内した立体：中心 `center` の 10 × 6 × 4 cm の箱を、正面（0.35 m・15°）・右・後ろ・左と真上から撮った 5 枚。
/// 写真には箱の投影を塗り、マスクはその長方形（十字のまわりの切り抜きで作った扱い）。撮ったあとに中心と大きさを求める（iPhone と同じ計算）。
func makeHeadingSession() -> CaptureSession {
    var session: CaptureSession
    do {
        session = try store.createSession(title: "e2e 向きの案内", device: device, plan: DirectionPlanPreset.ai5.plan, workKind: .object, guidance: .heading,
                                          declaredSize: DeclaredSize(heightM: declaredHeightM))
    } catch {
        fail("セッションを作れません: \(error)")
    }
    let width = 640, height = 480, fx = 560.0
    let intrinsics = simd_double3x3(rows: [SIMD3(fx, 0, Double(width) / 2), SIMD3(0, fx, Double(height) / 2), SIMD3(0, 0, 1)])
    let center = SIMD3<Double>(0.05, -0.3, -0.45)
    let half = SIMD3<Double>(0.05, 0.02, 0.03)
    var bounds: [String: MaskBounds] = [:]
    var frontHeading: Double?
    for (i, (az, el)) in [(0.0, 15.0), (90, 14), (180, 16), (270, 15), (25, 86)].enumerated() {
        let a = az * .pi / 180, e = el * .pi / 180
        let position = center + 0.35 * SIMD3(sin(a) * cos(e), sin(e), cos(a) * cos(e))
        let forward = simd_normalize(center - position)
        var right = simd_cross(forward, SIMD3(0, 1, 0))
        if simd_length(right) < 1e-6 { right = SIMD3(1, 0, 0) }
        right = simd_normalize(right)
        let up = simd_cross(right, forward)
        let cameraToWorld = simd_double4x4(columns: (SIMD4(right, 0), SIMD4(up, 0), SIMD4(-forward, 0), SIMD4(position, 1)))
        frontHeading = frontHeading ?? HeadingMath.headingDeg(cameraToWorld: cameraToWorld)
        let o2w = HeadingDeriver.objectToWorld(center: center, frontHeadingDeg: frontHeading!, originY: center.y)
        let camera = CameraModel(cameraToWorld: cameraToWorld, intrinsics: intrinsics, imageWidth: Double(width), imageHeight: Double(height))
        let pixels = (0..<8).compactMap { c -> SIMD2<Double>? in
            let q = o2w * SIMD4(c & 1 == 0 ? -half.x : half.x, c & 2 == 0 ? -half.y : half.y, c & 4 == 0 ? -half.z : half.z, 1)
            return camera.project(SIMD3(q.x, q.y, q.z))
        }
        let box = PixelRect(minX: pixels.map(\.x).min()!, minY: pixels.map(\.y).min()!, maxX: pixels.map(\.x).max()!, maxY: pixels.map(\.y).max()!)
        let jpeg = encodeImage(width: width, height: height, gray: false, type: .jpeg) { c in
            c.setFillColor(CGColor(red: 0.85, green: 0.8, blue: 0.7, alpha: 1))
            c.fill(CGRect(x: 0, y: 0, width: width, height: height))
            c.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
            c.fill(CGRect(x: box.minX, y: Double(height) - box.maxY, width: box.width, height: box.height))
        }
        let png = encodeImage(width: width, height: height, gray: true, type: .png) { c in
            c.setFillColor(gray: 0, alpha: 1)
            c.fill(CGRect(x: 0, y: 0, width: width, height: height))
            c.setFillColor(gray: 1, alpha: 1)
            c.fill(CGRect(x: box.minX, y: Double(height) - box.maxY, width: box.width, height: box.height))
        }
        let frame = CapturedFrameInfo(
            cameraToWorld: cameraToWorld, intrinsics: intrinsics, intrinsicsResolution: PixelSize(width: width, height: height),
            imageSize: PixelSize(width: width, height: height), timestamp: 200 + Double(i), exposureDuration: 0.01,
            exposureOffset: 0, trackingState: .normal, trackingReason: nil
        )
        let context = CaptureContext(
            trigger: i == 0 ? .manual : .auto, referenceFrameId: session.referenceFrames.last?.id, liveQuality: .unknown,
            deviceOrientation: "landscapeLeft", displayRotationDegClockwise: 0, capturedAt: Date()
        )
        let photoId = SessionStore.newId()
        do {
            let photo = try store.addPhoto(sessionId: session.sessionId, photoId: photoId, jpegData: jpeg) { s, sequence in
                PhotoRecorder.makeHeadingPhoto(in: &s, photoId: photoId, sequence: sequence, frame: frame, context: context)
            }
            guard photo.direction.targetId != nil else { fail("写真 \(i) が方向に当てはまりません") }
            let plan = MaskCropPlanner.crosshairPlan(imageWidth: width, imageHeight: height)
            try store.saveMask(sessionId: session.sessionId, photoId: photoId, pngData: png, mask: MaskInfo(
                status: .candidate, width: width, height: height, method: MaskInfo.visionMethod, instanceCount: 1, selectedInstances: [1],
                selection: .auto, check: MaskCheck(status: .ok, reasons: [])
            ).recording(plan))
            bounds[photoId] = MaskBounds(box: PixelRect(minX: box.minX.rounded(), minY: box.minY.rounded(), maxX: box.maxX.rounded(), maxY: box.maxY.rounded()),
                                         touches: [false, false, false, false], width: width, height: height)
            session = try store.loadSession(session.sessionId)
        } catch {
            fail("写真を保存できません: \(error)")
        }
    }
    do {
        session = try store.updateSession(session.sessionId) { s in
            HeadingSizer.refresh(session: &s) { bounds[$0.photoId] }
        }
    } catch {
        fail("中心と大きさを書けません: \(error)")
    }
    guard let d = session.referenceFrames.last?.heading?.derivation, let c = d.centerWorld?.simd, let size = d.size, size.isKnown else {
        fail("中心か大きさを求められません")
    }
    guard session.declaredHeightM == declaredHeightM else { fail("入力した高さを記録できません") }
    print(String(format: "向きの案内：中心のずれ %.1f mm、大きさ %.1f × %.1f × %.1f cm（下の目安 %.1f × %.1f × %.1f）", simd_distance(c, center) * 1000,
                 size.widthM! * 100, size.depthM! * 100, size.heightM! * 100, size.lowerM!.widthM * 100, size.lowerM!.depthM * 100, size.lowerM!.heightM * 100)
          + (session.declaredHeightM.map { String(format: "、入力した高さ %.1f cm", $0 * 100) } ?? "、高さは入力していない"))
    return session
}

func makeObjectSession() -> CaptureSession {
    var session: CaptureSession
    do {
        session = try store.createSession(title: "e2e テスト", device: device, plan: DirectionPlanPreset.ring8.plan)
        session = try store.updateSession(session.sessionId) { s in
            s.object = ObjectSize(heightM: 0.15, radiusM: 0.08)
            s.referenceFrames.append(ReferenceFrame(id: s.nextReferenceFrameId, createdAt: Date(), basePointWorld: SIMD3(0, -0.5, -0.5)))
        }
    } catch {
        fail("セッションを作れません: \(error)")
    }
    let refId = session.referenceFrames[0].id

    let width = 320, height = 240
    let fx = 280.0
    let intrinsics = simd_double3x3(rows: [SIMD3(fx, 0, Double(width) / 2), SIMD3(0, fx, Double(height) / 2), SIMD3(0, 0, 1)])
    for i in 0..<3 {
        let angle = Double(i) * .pi / 4
        let base = SIMD3<Double>(0, -0.5, -0.5)
        let position = base + SIMD3(0.4 * sin(angle), 0.15, 0.4 * cos(angle))
        // カメラが基準点を向く姿勢（−Z が前）。
        let forward = simd_normalize(base + SIMD3(0, 0.075, 0) - position)
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
        let up = simd_cross(right, forward)
        let cameraToWorld = simd_double4x4(columns: (SIMD4(right, 0), SIMD4(up, 0), SIMD4(-forward, 0), SIMD4(position, 1)))
        let jpeg = encodeImage(width: width, height: height, gray: false, type: .jpeg) { c in
            c.setFillColor(CGColor(red: 0.9, green: 0.85, blue: 0.7, alpha: 1))
            c.fill(CGRect(x: 0, y: 0, width: width, height: height))
            c.setFillColor(CGColor(red: 0.2 + 0.3 * Double(i), green: 0.3, blue: 0.6, alpha: 1))
            c.fill(CGRect(x: 110, y: 60, width: 100, height: 120))
        }
        let frame = CapturedFrameInfo(
            cameraToWorld: cameraToWorld, intrinsics: intrinsics, intrinsicsResolution: PixelSize(width: width, height: height),
            imageSize: PixelSize(width: width, height: height), timestamp: 100 + Double(i), exposureDuration: 0.01,
            exposureOffset: 0, trackingState: .normal, trackingReason: nil
        )
        let context = CaptureContext(
            trigger: i == 0 ? .manual : .auto, referenceFrameId: refId, liveQuality: .unknown,
            deviceOrientation: "landscapeLeft", displayRotationDegClockwise: 0, capturedAt: Date()
        )
        let photoId = SessionStore.newId()
        do {
            try store.addPhoto(sessionId: session.sessionId, photoId: photoId, jpegData: jpeg) { s, sequence in
                PhotoRecorder.makePhoto(in: &s, photoId: photoId, sequence: sequence, frame: frame, context: context)
            }
            if i < 2 {
                let png = encodeImage(width: width, height: height, gray: true, type: .png) { c in
                    c.setFillColor(gray: 0, alpha: 1)
                    c.fill(CGRect(x: 0, y: 0, width: width, height: height))
                    c.setFillColor(gray: 1, alpha: 1)
                    c.fill(CGRect(x: 110, y: 60, width: 100, height: 120))
                }
                try store.saveMask(sessionId: session.sessionId, photoId: photoId, pngData: png, mask: MaskInfo(
                    status: i == 0 ? .confirmed : .candidate, width: width, height: height, method: MaskInfo.visionMethod,
                    instanceCount: 1, selectedInstances: [1], selection: .auto
                ))
            } else {
                try store.updateSession(session.sessionId) { s in
                    if let index = s.photos.firstIndex(where: { $0.photoId == photoId }) { s.photos[index].mask = .failed("e2e: マスクなし") }
                }
            }
        } catch {
            fail("写真を保存できません: \(error)")
        }
    }
    do { session = try store.loadSession(session.sessionId) } catch { fail("読み直せません: \(error)") }
    return session
}

let client = TransferClient(receiverURL: receiverURL, token: token)
let uploader = SessionUploader(store: store, client: client)

func run(_ label: String, expectAlreadyComplete: Bool) async -> String {
    let outcome = await uploader.send(sessionId: sessionId) { p in
        if p.phase == .uploading || p.phase == .done {
            print("  [\(label)] \(p.phase.rawValue) \(p.sentFiles)/\(p.totalFiles) files, \(p.sentBytes)/\(p.totalBytes) bytes")
        }
    }
    switch outcome {
    case let .complete(hash, receiverId, already, path):
        print("[\(label)] complete（alreadyComplete=\(already)） manifestHash=\(hash) receiverId=\(receiverId) path=\(path ?? "-")")
        if already != expectAlreadyComplete { fail("\(label): alreadyComplete が \(expectAlreadyComplete) ではありません") }
        if store.transferDisplayStatus(sessionId) != .sent { fail("\(label): 送信済みになっていません") }
        return hash
    case let .failed(error):
        fail("\(label): \(error.userMessage)")
    }
}

let semaphore = DispatchSemaphore(value: 0)
Task {
    do {
        let info = try await client.ping()
        print("ping: \(info.name ?? "-") receiverId=\(info.receiverId)")
    } catch {
        fail("ping: \((error as? TransferError)?.userMessage ?? "\(error)")")
    }
    let first = await run("1 回目", expectAlreadyComplete: false)
    let second = await run("2 回目", expectAlreadyComplete: true)
    if first != second { fail("manifestHash が変わりました") }
    do {
        try store.updateSession(sessionId) { $0.title = "e2e テスト（変更後）" }
    } catch {
        fail("変更できません: \(error)")
    }
    if store.transferDisplayStatus(sessionId) != .modifiedSinceSent { fail("変更後に「変更あり」になっていません") }
    let third = await run("変更後", expectAlreadyComplete: false)
    if third == first { fail("変更後も manifestHash が同じです") }
    print("OK: e2e がすべて通りました（sessionId \(sessionId)）")
    semaphore.signal()
}
semaphore.wait()
if !keep { try? FileManager.default.removeItem(at: root) }
#else
print("capture-e2e は macOS だけで動きます")
#endif
