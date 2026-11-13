import Foundation
import simd

// 向きで案内したセッションの写真の記録（撮ったときの向き・位置の確かめ・方向の当てはめ）。

/// 向きで案内する基準の、撮影前の解析に使う写し（正面と、撮った写真の画面の中心の線）。
public struct HeadingLiveReference: Equatable, Sendable {
    /// 正面の写真の水平の向き（度）。正面がまだ無ければ nil。
    public var frontHeadingDeg: Double?
    /// 正面の写真の画面の中心の線。
    public var frontRay: Ray?
    /// ほかに撮った写真（方向に当てはまった正面・横・後ろ。真上は除く）の画面の中心の線（作品の位置の推定に使う）。
    public var shotRays: [Ray]

    public init(frontHeadingDeg: Double? = nil, frontRay: Ray? = nil, shotRays: [Ray] = []) {
        self.frontHeadingDeg = frontHeadingDeg
        self.frontRay = frontRay
        self.shotRays = shotRays
    }

    public var hasFront: Bool { frontHeadingDeg != nil && frontRay != nil }

    /// session.json の基準 `frameId` から作る。
    public static func make(session: CaptureSession, frameId: String?) -> HeadingLiveReference {
        guard let frameId, let frame = session.referenceFrame(id: frameId), let heading = frame.heading else { return HeadingLiveReference() }
        let photos = session.photos.filter { $0.referenceFrameId == frameId }
        let front = frame.frontPhotoId.flatMap { id in photos.first { $0.photoId == id } }
        let shots = photos.filter { p in
            p.photoId != frame.frontPhotoId && p.direction.confirmed && p.direction.targetId != nil
                && !(session.directionPlan.target(id: p.direction.targetId)?.anyAzimuth ?? true)
        }
        return HeadingLiveReference(
            frontHeadingDeg: heading.frontHeadingDeg, frontRay: front.map(HeadingMath.centerRay(of:)),
            shotRays: shots.map(HeadingMath.centerRay(of:))
        )
    }

    /// 今のカメラの線の、向きの差と位置の確かめ。
    public func evaluate(ray: Ray) -> (relativeHeadingDeg: Double?, pitchDeg: Double, position: HeadingPositionCheck) {
        let pitch = HeadingMath.pitchDeg(direction: ray.direction)
        guard let front = frontHeadingDeg, let frontRay else { return (nil, pitch, .notChecked) }
        let relative = HeadingMath.headingDeg(direction: ray.direction).map { Geometry.normalizeDegrees($0 - front) }
        let position = HeadingPosition.evaluate(current: ray, relativeHeadingDeg: relative ?? (pitch >= HeadingPosition.topPitchDeg ? 0 : nil),
                                                pitchDeg: pitch, front: frontRay, shots: shotRays)
        return (relative, pitch, position)
    }
}

extension PhotoRecorder {
    /// 向きで案内したセッションの写真の記録。写真を `photos` に足すのは呼ぶ側。
    /// - 基準：`context.referenceFrameId` の基準。無ければ（`startNewFrame` が true なら）新しい基準を作る（底の中心・円柱は無い）。
    /// - 正面：その基準の最初の確定した写真（追跡が normal で、見下ろす角度が `HeadingPosition.topPitchDeg` 未満）。
    ///   その写真の水平の向きを覚え、正面からの向きの差 0° とする。
    /// - 方向：正面からの向きの差を方位、見下ろす角度を仰角として当てはめる。横・後ろ・真上は、位置の確かめ
    ///   （その場で回しただけではないか）が ok のときだけ `targetId` を付ける（外れた写真も保存し、確認画面で知らせる）。
    /// - `direction` の方位・仰角は撮ったときの向きの差・見下ろす角度、距離は推定した水平の距離（無ければ null）。
    ///   撮ったあとに中心を求めると、中心から測った値に置き換わる（`HeadingDeriver.update`）。撮ったときの値は `heading` に残る。
    public static func makeHeadingPhoto(
        in session: inout CaptureSession, photoId: String, sequence: Int, frame: CapturedFrameInfo, context: CaptureContext,
        startNewFrame: Bool = true
    ) -> Photo {
        var frameIndex = context.referenceFrameId.flatMap { id in session.referenceFrames.firstIndex { $0.id == id && $0.isHeading } }
        if frameIndex == nil, startNewFrame {
            for i in session.referenceFrames.indices where session.referenceFrames[i].isValid {
                session.referenceFrames[i].invalidatedAt = context.capturedAt
                session.referenceFrames[i].invalidationReason = .userReset
            }
            session.referenceFrames.append(.headingFrame(id: session.nextReferenceFrameId, createdAt: context.capturedAt))
            frameIndex = session.referenceFrames.count - 1
        }
        let ray = HeadingMath.centerRay(of: frame)
        let pitch = HeadingMath.pitchDeg(direction: ray.direction)
        let absolute = HeadingMath.headingDeg(direction: ray.direction)
        var reason: UnconfirmedReason?
        var relative: Double?
        var position = HeadingPositionCheck.notChecked
        var isFront = false
        var frameId: String?

        if let index = frameIndex {
            let reference = session.referenceFrames[index]
            frameId = reference.id
            if !reference.isValid { reason = .referenceInvalidated } else if frame.trackingState != .normal { reason = .trackingNotNormal }
            if let front = reference.heading?.frontHeadingDeg {
                relative = absolute.map { Geometry.normalizeDegrees($0 - front) }
                if reason == nil {
                    let live = HeadingLiveReference.make(session: session, frameId: reference.id)
                    position = live.evaluate(ray: ray).position
                }
            } else if reason == nil, let absolute, pitch < HeadingPosition.topPitchDeg {
                // この基準の最初の確定した写真：この写真の向きが正面になる。
                session.referenceFrames[index].heading?.frontHeadingDeg = round3(absolute)
                session.referenceFrames[index].heading?.frontPitchDeg = round3(pitch)
                session.referenceFrames[index].frontPhotoId = photoId
                relative = 0
                isFront = true
            } else if reason == nil {
                // 真上から撮ったので正面の向きが決まらない。
                reason = .noReference
            }
        } else {
            reason = .noReference
        }

        let confirmed = reason == nil && (relative != nil || (frameIndex.flatMap { session.referenceFrames[$0].heading?.frontHeadingDeg } != nil))
        var target: DirectionTarget?
        if confirmed {
            let matched = Coverage.match(azimuthDeg: relative ?? 0, elevationDeg: pitch, plan: session.directionPlan)
                .flatMap { relative != nil || $0.anyAzimuth ? $0 : nil }
            // 正面そのもの以外は、作品のまわりを歩いた位置から撮ったときだけ方向に数える。
            target = isFront || position.isOK ? matched : nil
        }
        let direction = DirectionInfo(
            confirmed: confirmed, unconfirmedReason: confirmed ? nil : (reason ?? .noReference), targetId: target?.id,
            azimuthDeg: relative.map(round3), elevationDeg: round3(pitch), distanceM: position.distanceM.map(round4)
        )
        let heading = PhotoHeadingInfo(relativeHeadingDeg: relative.map(round3), pitchDeg: round3(pitch),
                                       position: isFront ? .notChecked : position.status, estimatedDistanceM: position.distanceM.map(round4))
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
            referenceFrameId: frameId, image: image, camera: camera, direction: direction,
            quality: PhotoQuality(live: context.liveQuality), mask: .notGenerated, heading: heading
        )
    }

    private static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
    private static func round4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
}
