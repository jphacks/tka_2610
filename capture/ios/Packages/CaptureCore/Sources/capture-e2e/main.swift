// capture-e2e：小さな合成セッションを作って、受信側（receiver/memoria_receiver.py）へ送る確認ツール（macOS）。
//
//   swift run capture-e2e http://127.0.0.1:8765 123456 [--keep]
//
// 1. 一時フォルダに SessionStore で合成セッション（写真 3 枚・マスク 2 枚）を作る
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
guard args.count >= 2, let receiverURL = TransferClient.receiverURL(fromUserInput: args[args.startIndex]) else {
    print("使い方: capture-e2e <受信側の URL（http://IP:port）> <ペアリングコード> [--keep]")
    exit(2)
}
let token = args[args.startIndex + 1]

let root = FileManager.default.temporaryDirectory.appendingPathComponent("capture-e2e-\(UUID().uuidString)")
let store = SessionStore(rootDirectory: root)
print("一時フォルダ: \(root.path)")

let device = DeviceInfo(model: "Mac-e2e", systemName: "macOS", systemVersion: ProcessInfo.processInfo.operatingSystemVersionString, appVersion: "0.1.0", appBuild: "1")
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
let sessionId = session.sessionId
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
        try store.addPhoto(sessionId: sessionId, photoId: photoId, jpegData: jpeg) { s, sequence in
            PhotoRecorder.makePhoto(in: &s, photoId: photoId, sequence: sequence, frame: frame, context: context)
        }
        if i < 2 {
            let png = encodeImage(width: width, height: height, gray: true, type: .png) { c in
                c.setFillColor(gray: 0, alpha: 1)
                c.fill(CGRect(x: 0, y: 0, width: width, height: height))
                c.setFillColor(gray: 1, alpha: 1)
                c.fill(CGRect(x: 110, y: 60, width: 100, height: 120))
            }
            try store.saveMask(sessionId: sessionId, photoId: photoId, pngData: png, mask: MaskInfo(
                status: i == 0 ? .confirmed : .candidate, width: width, height: height, method: MaskInfo.visionMethod,
                instanceCount: 1, selectedInstances: [1], selection: .auto
            ))
        } else {
            try store.updateSession(sessionId) { s in
                if let index = s.photos.firstIndex(where: { $0.photoId == photoId }) { s.photos[index].mask = .failed("e2e: マスクなし") }
            }
        }
    } catch {
        fail("写真を保存できません: \(error)")
    }
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
