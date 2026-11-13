import CaptureCore
import Foundation
import simd

enum Fixtures {
    static let device = DeviceInfo(model: "iPhone15,4", systemName: "iOS", systemVersion: "26.6", appVersion: "0.1.0", appBuild: "1")

    static func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureCoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `position` から `target` を見るカメラ（ARKit の決まり：−Z が前、+Y が上）。
    static func lookAt(from position: SIMD3<Double>, to target: SIMD3<Double>) -> simd_double4x4 {
        let forward = simd_normalize(target - position)
        var right = simd_cross(forward, SIMD3(0, 1, 0))
        if simd_length(right) < 1e-6 { right = SIMD3(1, 0, 0) }
        right = simd_normalize(right)
        let up = simd_cross(right, forward)
        return simd_double4x4(columns: (SIMD4(right, 0), SIMD4(up, 0), SIMD4(-forward, 0), SIMD4(position, 1)))
    }

    static let intrinsics = simd_double3x3(rows: [SIMD3(1500, 0, 960), SIMD3(0, 1500, 720), SIMD3(0, 0, 1)])

    static func camera(from position: SIMD3<Double>, to target: SIMD3<Double>) -> CameraModel {
        CameraModel(cameraToWorld: lookAt(from: position, to: target), intrinsics: intrinsics, imageWidth: 1920, imageHeight: 1440)
    }

    static func frame(cameraToWorld: simd_double4x4, tracking: TrackingState = .normal, reason: TrackingReason? = nil) -> CapturedFrameInfo {
        CapturedFrameInfo(
            cameraToWorld: cameraToWorld, intrinsics: intrinsics, intrinsicsResolution: PixelSize(width: 1920, height: 1440),
            imageSize: PixelSize(width: 1920, height: 1440), timestamp: 12345.678, exposureDuration: 0.01, exposureOffset: 0,
            trackingState: tracking, trackingReason: reason
        )
    }

    static func context(ref: String?, trigger: CaptureTrigger = .manual) -> CaptureContext {
        CaptureContext(
            trigger: trigger, referenceFrameId: ref, liveQuality: .unknown, deviceOrientation: "portrait",
            displayRotationDegClockwise: 90, capturedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    /// 基準点 base、高さ 0.15、半径 0.08 の基準を 1 つ持つセッション。
    static func session(base: SIMD3<Double> = SIMD3(0.1, -0.7, -0.4)) -> CaptureSession {
        var s = CaptureSession(sessionId: SessionStore.newId(), title: "ねこの貯金箱", createdAt: Date(timeIntervalSince1970: 1_800_000_000), device: device, directionPlan: DirectionPlanPreset.ring8.plan)
        s.object = ObjectSize(heightM: 0.15, radiusM: 0.08)
        s.referenceFrames.append(ReferenceFrame(id: "ref-1", createdAt: s.createdAt, basePointWorld: base))
        return s
    }

    /// 作品座標の方位・仰角・距離にあるカメラの世界の位置（object frame が単位行列で base に原点があるとき）。
    static func position(base: SIMD3<Double>, height: Double, azimuth: Double, elevation: Double, distance: Double) -> SIMD3<Double> {
        let az = azimuth * .pi / 180, el = elevation * .pi / 180
        let center = base + SIMD3(0, height / 2, 0)
        return center + distance * SIMD3(sin(az) * cos(el), sin(el), cos(az) * cos(el))
    }
}
