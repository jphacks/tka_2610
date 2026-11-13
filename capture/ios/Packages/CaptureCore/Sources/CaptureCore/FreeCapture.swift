import Foundation
import simd

// 立体の作品を、案内なしで自由に何枚でも撮る撮影（`guidance: "free"`、撮る方向の一覧 `free`）。
// 平面の作品（flat1）と同じ系統：基準を作らない・マスクを作らない・向きはカメラの傾きだけ。
// 用紙の検出・補正・実寸は無い。どの写真がどの向きかは記録せず、読む側（AI）が写真を見て決める。

extension PhotoRecorder {
    /// 自由に撮った写真の記録。基準は使わない（`referenceFrameId` は null）。方向はカメラの傾きだけ（平面の作品と同じ測り方）：
    /// `elevationDeg` はカメラの光軸が水平から下へ傾いた角度（`FlatGeometry.lookDownDeg`）、`azimuthDeg`・`distanceM`・`targetId` は null。
    /// 傾きは重力から決まるので、追跡が `notAvailable` でなければ確定（`confirmed`）。マスクは作らない（`notGenerated`）。
    public static func makeFreePhoto(
        session: CaptureSession, photoId: String, sequence: Int, frame: CapturedFrameInfo, context: CaptureContext
    ) -> Photo {
        let elevation = (FlatGeometry.lookDownDeg(cameraToWorld: frame.cameraToWorld) * 1000).rounded() / 1000
        let confirmed = frame.trackingState != .notAvailable
        let direction = DirectionInfo(
            confirmed: confirmed, unconfirmedReason: confirmed ? nil : .trackingNotNormal, targetId: nil,
            azimuthDeg: nil, elevationDeg: elevation, distanceM: nil
        )
        let image = ImageInfo(
            file: Photo.imagePath(photoId: photoId), width: frame.imageSize.width, height: frame.imageSize.height,
            displayRotationDegClockwise: DisplayRotation.normalized(context.displayRotationDegClockwise),
            deviceOrientation: context.deviceOrientation
        )
        let camera = CameraInfo(
            arFrameTimestamp: frame.timestamp, cameraToWorld: Matrix4x4(frame.cameraToWorld),
            intrinsics: Matrix3x3(frame.intrinsics), intrinsicsResolution: frame.intrinsicsResolution,
            exposureDurationS: frame.exposureDuration, exposureOffsetEV: frame.exposureOffset,
            trackingState: frame.trackingState, trackingReason: frame.trackingState == .limited ? frame.trackingReason : nil
        )
        return Photo(
            photoId: photoId, sequence: sequence, capturedAt: context.capturedAt, trigger: context.trigger,
            referenceFrameId: nil, image: image, camera: camera, direction: direction,
            quality: PhotoQuality(live: context.liveQuality), mask: .notGenerated
        )
    }
}

/// 自由に撮る撮影画面の文言（1 か所）。
public enum FreeCaptureText {
    /// 撮影画面に出す目安。
    public static let hint = "作品の全体を画面に入れて撮ってください。正面・横・後ろ・真上があると、形を作りやすくなります"
}
