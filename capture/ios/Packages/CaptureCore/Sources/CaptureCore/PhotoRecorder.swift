import Foundation
import simd

/// captureHighResolutionFrame が返した ARFrame から写したもの（ARFrame は持たない）。
public struct CapturedFrameInfo: Equatable, Sendable {
    public var cameraToWorld: simd_double4x4
    public var intrinsics: simd_double3x3
    /// K が対象とする画像の大きさ（ARCamera.imageResolution）。
    public var intrinsicsResolution: PixelSize
    /// 実際に保存した画像の大きさ（ピクセルバッファの大きさ）。
    public var imageSize: PixelSize
    public var timestamp: Double
    public var exposureDuration: Double?
    public var exposureOffset: Double?
    public var trackingState: TrackingState
    public var trackingReason: TrackingReason?

    public init(
        cameraToWorld: simd_double4x4, intrinsics: simd_double3x3, intrinsicsResolution: PixelSize, imageSize: PixelSize,
        timestamp: Double, exposureDuration: Double?, exposureOffset: Double?, trackingState: TrackingState, trackingReason: TrackingReason?
    ) {
        self.cameraToWorld = cameraToWorld
        self.intrinsics = intrinsics
        self.intrinsicsResolution = intrinsicsResolution
        self.imageSize = imageSize
        self.timestamp = timestamp
        self.exposureDuration = exposureDuration
        self.exposureOffset = exposureOffset
        self.trackingState = trackingState
        self.trackingReason = trackingReason
    }

    /// K の画像と保存した画像の大きさが同じか（違っても黙って K を直さない）。
    public var intrinsicsMatchImage: Bool { intrinsicsResolution == imageSize }
}

/// シャッターを押したときの状態。
public struct CaptureContext: Equatable, Sendable {
    public var trigger: CaptureTrigger
    /// シャッターを押したときに有効だった基準の id（無ければ nil）。
    public var referenceFrameId: String?
    public var liveQuality: LiveQualityRecord
    public var deviceOrientation: String
    public var displayRotationDegClockwise: Int
    public var capturedAt: Date

    public init(
        trigger: CaptureTrigger, referenceFrameId: String?, liveQuality: LiveQualityRecord,
        deviceOrientation: String, displayRotationDegClockwise: Int, capturedAt: Date
    ) {
        self.trigger = trigger
        self.referenceFrameId = referenceFrameId
        self.liveQuality = liveQuality
        self.deviceOrientation = deviceOrientation
        self.displayRotationDegClockwise = displayRotationDegClockwise
        self.capturedAt = capturedAt
    }
}

/// 写真 1 枚の記録を作る（方向の計算と、最初の写真で正面を決めることを含む）。
public enum PhotoRecorder {
    /// `session` の基準の正面を（必要なら）決めて、写真の記録を返す。写真を `photos` に足すのは呼ぶ側。
    public static func makePhoto(
        in session: inout CaptureSession, photoId: String, sequence: Int,
        frame: CapturedFrameInfo, context: CaptureContext
    ) -> Photo {
        let cameraPosition = frame.cameraToWorld.translation
        var confirmed = false
        var reason: UnconfirmedReason?
        var azimuth: Double?
        var elevation: Double?
        var distance: Double?

        if let refId = context.referenceFrameId,
           let index = session.referenceFrames.firstIndex(where: { $0.id == refId }) {
            let reference = session.referenceFrames[index]
            let base = reference.basePointWorld.simd
            let height = session.objectSize(referenceFrameId: refId)?.heightM ?? 0
            let ed = Geometry.elevationAndDistance(cameraPosition: cameraPosition, basePoint: base, heightM: height)
            elevation = ed.elevationDeg
            distance = ed.distanceM

            if !reference.isValid {
                reason = .referenceInvalidated
            } else if frame.trackingState != .normal {
                reason = .trackingNotNormal
            }

            if let objectToWorld = reference.objectToWorld?.simd {
                azimuth = Geometry.azimuth(cameraPosition: cameraPosition, objectToWorld: objectToWorld)
                confirmed = reason == nil
            } else if reason == nil {
                // この基準の最初の確定した写真：この写真のカメラの方向が正面になる。
                if let objectToWorld = Geometry.objectToWorld(basePoint: base, frontCameraPosition: cameraPosition) {
                    session.referenceFrames[index].objectToWorld = Matrix4x4(objectToWorld)
                    session.referenceFrames[index].frontPhotoId = photoId
                    azimuth = Geometry.azimuth(cameraPosition: cameraPosition, objectToWorld: objectToWorld)
                    confirmed = true
                } else {
                    // 真上から撮ったので正面の向きが決まらない（作品座標が無い）。
                    reason = .noReference
                }
            }
        } else {
            reason = .noReference
        }

        let target = Coverage.match(azimuthDeg: azimuth, elevationDeg: elevation, plan: session.directionPlan)
        let direction = DirectionInfo(
            confirmed: confirmed, unconfirmedReason: confirmed ? nil : reason, targetId: target?.id,
            azimuthDeg: azimuth.map { Geometry.normalizeDegrees(round3($0)) }, elevationDeg: elevation.map(round3), distanceM: distance.map(round4)
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
            referenceFrameId: context.referenceFrameId, image: image, camera: camera, direction: direction,
            quality: PhotoQuality(live: context.liveQuality), mask: .notGenerated
        )
    }

    private static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
    private static func round4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
}
