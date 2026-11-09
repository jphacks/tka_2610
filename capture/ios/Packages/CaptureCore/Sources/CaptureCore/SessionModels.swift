import Foundation

// session.json（schemaVersion 1）の型。キー名・列挙の値は docs/data-format.md と同じ。
// 取れない値は推測で埋めず null（`@NullCodable`）にする。

public enum SessionSchema {
    public static let name = "memoria.capture.session"
    public static let version = 1
}

// MARK: - 列挙

public enum InvalidationReason: String, Codable, Sendable, CaseIterable {
    case sessionInterrupted, trackingLost, userReset, anchorDrift
}

public enum CaptureTrigger: String, Codable, Sendable {
    case auto, manual
}

public enum TrackingState: String, Codable, Sendable {
    case normal, limited, notAvailable
}

public enum TrackingReason: String, Codable, Sendable {
    case initializing, relocalizing, excessiveMotion, insufficientFeatures
}

public enum UnconfirmedReason: String, Codable, Sendable {
    case trackingNotNormal, noReference, referenceInvalidated
}

/// 撮影前の確認項目の状態。
public enum CheckStatus: String, Codable, Sendable {
    case ok, warning, blocked, unknown
}

public enum MaskStatus: String, Codable, Sendable {
    case notGenerated, processing, candidate, confirmed, failed, noObject

    /// マスクのファイルがある（転送する）状態。
    public var hasFile: Bool { self == .candidate || self == .confirmed }
}

public enum MaskSelectionKind: String, Codable, Sendable {
    case auto, user
}

public enum ObjectSizeSource: String, Codable, Sendable {
    case userAdjusted
}

// MARK: - セッション

public struct CaptureSession: Codable, Equatable, Sendable {
    public var schema: String
    public var schemaVersion: Int
    public var sessionId: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var conventions: [String: String]
    public var device: DeviceInfo
    /// 作品の大きさ（最後に設定した基準の大きさ。前の版との互換のために残す）。基準を確定するまでは null
    /// （ユーザーが合わせていない値を推測で入れない）。写真に使う大きさは `objectSize(referenceFrameId:)`。
    @NullCodable public var object: ObjectSize?
    public var referenceFrames: [ReferenceFrame]
    public var directionPlan: DirectionPlan
    public var photos: [Photo]

    public init(
        sessionId: String,
        title: String,
        createdAt: Date,
        device: DeviceInfo,
        directionPlan: DirectionPlan
    ) {
        schema = SessionSchema.name
        schemaVersion = SessionSchema.version
        self.sessionId = sessionId
        self.title = title
        self.createdAt = createdAt
        updatedAt = createdAt
        conventions = Conventions.text
        self.device = device
        object = nil
        referenceFrames = []
        self.directionPlan = directionPlan
        photos = []
    }

    /// 今使える基準（最後に作られ、まだ無効になっていないもの）。
    public var activeReferenceFrame: ReferenceFrame? {
        guard let last = referenceFrames.last, last.isValid else { return nil }
        return last
    }

    public func referenceFrame(id: String?) -> ReferenceFrame? {
        guard let id else { return nil }
        return referenceFrames.first { $0.id == id }
    }

    /// その基準で撮った写真に使う作品の大きさ。基準ごとの大きさ（`referenceFrames[].object`）が無い
    /// （この項目より前に作った基準）ときは、セッションの `object`（最後に設定した大きさ）。基準が無ければ nil。
    public func objectSize(referenceFrameId: String?) -> ObjectSize? {
        guard let reference = referenceFrame(id: referenceFrameId) else { return nil }
        return reference.object ?? object
    }

    public func photo(id: String) -> Photo? {
        photos.first { $0.photoId == id }
    }

    public var nextReferenceFrameId: String {
        "ref-\(referenceFrames.count + 1)"
    }
}

public struct DeviceInfo: Codable, Equatable, Sendable {
    public var model: String
    public var systemName: String
    public var systemVersion: String
    public var appVersion: String
    public var appBuild: String

    public init(model: String, systemName: String, systemVersion: String, appVersion: String, appBuild: String) {
        self.model = model
        self.systemName = systemName
        self.systemVersion = systemVersion
        self.appVersion = appVersion
        self.appBuild = appBuild
    }
}

public struct ObjectSize: Codable, Equatable, Sendable {
    public var heightM: Double
    public var radiusM: Double
    public var source: ObjectSizeSource

    public init(heightM: Double, radiusM: Double, source: ObjectSizeSource = .userAdjusted) {
        self.heightM = heightM
        self.radiusM = radiusM
        self.source = source
    }
}

public struct ReferenceFrame: Codable, Equatable, Sendable {
    public var id: String
    public var createdAt: Date
    public var basePointWorld: Vector3
    @NullCodable public var objectToWorld: Matrix4x4?
    @NullCodable public var frontPhotoId: String?
    @NullCodable public var invalidatedAt: Date?
    @NullCodable public var invalidationReason: InvalidationReason?
    /// この基準を設定したときの作品の大きさ。この項目より前に作った基準は null（セッションの `object` を使う）。
    @NullCodable public var object: ObjectSize?
    /// 基準点をどの方法で求めたか（平面・特徴点・iPhone の下端、手で合わせた高さ）。この項目より前に作った基準は null。
    @NullCodable public var base: BasePointInfo?

    public init(id: String, createdAt: Date, basePointWorld: SIMD3<Double>, object: ObjectSize? = nil, base: BasePointInfo? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.basePointWorld = Vector3(basePointWorld)
        objectToWorld = nil
        frontPhotoId = nil
        invalidatedAt = nil
        invalidationReason = nil
        self.object = object
        self.base = base
    }

    public var isValid: Bool { invalidatedAt == nil }
}

// MARK: - 写真

public struct Photo: Codable, Equatable, Sendable, Identifiable {
    public var photoId: String
    public var sequence: Int
    public var capturedAt: Date
    public var trigger: CaptureTrigger
    @NullCodable public var referenceFrameId: String?
    public var image: ImageInfo
    public var camera: CameraInfo
    public var direction: DirectionInfo
    public var quality: PhotoQuality
    public var mask: MaskInfo

    public var id: String { photoId }

    public init(
        photoId: String, sequence: Int, capturedAt: Date, trigger: CaptureTrigger, referenceFrameId: String?,
        image: ImageInfo, camera: CameraInfo, direction: DirectionInfo, quality: PhotoQuality, mask: MaskInfo
    ) {
        self.photoId = photoId
        self.sequence = sequence
        self.capturedAt = capturedAt
        self.trigger = trigger
        self.referenceFrameId = referenceFrameId
        self.image = image
        self.camera = camera
        self.direction = direction
        self.quality = quality
        self.mask = mask
    }

    public static func imagePath(photoId: String) -> String { "photos/\(photoId).jpg" }
    public static func maskPath(photoId: String) -> String { "masks/\(photoId).png" }
}

public struct ImageInfo: Codable, Equatable, Sendable {
    public var file: String
    public var format: String
    public var width: Int
    public var height: Int
    public var exifOrientation: Int
    public var displayRotationDegClockwise: Int
    /// UIDeviceOrientation の名前（"portrait" など）。
    public var deviceOrientation: String

    public init(file: String, width: Int, height: Int, displayRotationDegClockwise: Int, deviceOrientation: String) {
        self.file = file
        format = "jpeg"
        self.width = width
        self.height = height
        exifOrientation = 1
        self.displayRotationDegClockwise = displayRotationDegClockwise
        self.deviceOrientation = deviceOrientation
    }
}

public struct PixelSize: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct CameraInfo: Codable, Equatable, Sendable {
    public var source: String
    public var arFrameTimestamp: Double
    public var cameraToWorld: Matrix4x4
    public var intrinsics: Matrix3x3
    public var intrinsicsResolution: PixelSize
    @NullCodable public var exposureDurationS: Double?
    @NullCodable public var exposureOffsetEV: Double?
    public var trackingState: TrackingState
    @NullCodable public var trackingReason: TrackingReason?

    public init(
        arFrameTimestamp: Double, cameraToWorld: Matrix4x4, intrinsics: Matrix3x3, intrinsicsResolution: PixelSize,
        exposureDurationS: Double?, exposureOffsetEV: Double?, trackingState: TrackingState, trackingReason: TrackingReason?
    ) {
        source = "captureHighResolutionFrame"
        self.arFrameTimestamp = arFrameTimestamp
        self.cameraToWorld = cameraToWorld
        self.intrinsics = intrinsics
        self.intrinsicsResolution = intrinsicsResolution
        self.exposureDurationS = exposureDurationS
        self.exposureOffsetEV = exposureOffsetEV
        self.trackingState = trackingState
        self.trackingReason = trackingReason
    }
}

public struct DirectionInfo: Codable, Equatable, Sendable {
    public var confirmed: Bool
    @NullCodable public var unconfirmedReason: UnconfirmedReason?
    @NullCodable public var targetId: String?
    @NullCodable public var azimuthDeg: Double?
    @NullCodable public var elevationDeg: Double?
    @NullCodable public var distanceM: Double?

    public init(
        confirmed: Bool, unconfirmedReason: UnconfirmedReason?, targetId: String?,
        azimuthDeg: Double?, elevationDeg: Double?, distanceM: Double?
    ) {
        self.confirmed = confirmed
        self.unconfirmedReason = unconfirmedReason
        self.targetId = targetId
        self.azimuthDeg = azimuthDeg
        self.elevationDeg = elevationDeg
        self.distanceM = distanceM
    }
}

public struct PhotoQuality: Codable, Equatable, Sendable {
    public var live: LiveQualityRecord
    /// 保存した写真の解析。まだ解析していないときは null。
    @NullCodable public var saved: SavedQuality?

    public init(live: LiveQualityRecord, saved: SavedQuality? = nil) {
        self.live = live
        self.saved = saved
    }
}

public struct LiveQualityRecord: Codable, Equatable, Sendable {
    public var tracking: CheckStatus
    public var inFrame: CheckStatus
    public var direction: CheckStatus
    public var motion: CheckStatus
    public var brightness: CheckStatus
    public var sharpness: CheckStatus
    public var warningsAcknowledged: Bool

    public init(
        tracking: CheckStatus, inFrame: CheckStatus, direction: CheckStatus, motion: CheckStatus,
        brightness: CheckStatus, sharpness: CheckStatus, warningsAcknowledged: Bool
    ) {
        self.tracking = tracking
        self.inFrame = inFrame
        self.direction = direction
        self.motion = motion
        self.brightness = brightness
        self.sharpness = sharpness
        self.warningsAcknowledged = warningsAcknowledged
    }

    public static let unknown = LiveQualityRecord(
        tracking: .unknown, inFrame: .unknown, direction: .unknown, motion: .unknown,
        brightness: .unknown, sharpness: .unknown, warningsAcknowledged: false
    )

    public var hasWarnings: Bool {
        [tracking, inFrame, direction, motion, brightness, sharpness].contains { $0 == .warning || $0 == .blocked }
    }
}

public struct SavedQuality: Codable, Equatable, Sendable {
    public var meanLuma: Double
    public var sharpness: Double
    public var brightness: CheckStatus
    public var blur: CheckStatus

    public init(meanLuma: Double, sharpness: Double, brightness: CheckStatus, blur: CheckStatus) {
        self.meanLuma = meanLuma
        self.sharpness = sharpness
        self.brightness = brightness
        self.blur = blur
    }
}

public struct MaskInfo: Codable, Equatable, Sendable {
    public static let visionMethod = "VNGenerateForegroundInstanceMaskRequest"

    public var status: MaskStatus
    @NullCodable public var file: String?
    @NullCodable public var width: Int?
    @NullCodable public var height: Int?
    @NullCodable public var method: String?
    @NullCodable public var instanceCount: Int?
    public var selectedInstances: [Int]
    @NullCodable public var selection: MaskSelectionKind?
    @NullCodable public var error: String?
    /// Vision に渡した範囲（写真のピクセル）。写真の全体を渡したとき・まだ作っていないときは null。
    @NullCodable public var inputRegion: PixelBox?
    /// 範囲の決め方。まだ作っていないとき・この項目より前に作ったマスク（写真の全体を渡していた）は null。
    @NullCodable public var inputRegionSource: MaskInputRegionSource?
    /// マスクが作品らしいか（投影した作品の輪郭と比べた結果）。まだ確かめていない・マスクが無いときは null。
    @NullCodable public var check: MaskCheck?

    public init(
        status: MaskStatus, file: String? = nil, width: Int? = nil, height: Int? = nil, method: String? = nil,
        instanceCount: Int? = nil, selectedInstances: [Int] = [], selection: MaskSelectionKind? = nil, error: String? = nil,
        inputRegion: PixelBox? = nil, inputRegionSource: MaskInputRegionSource? = nil, check: MaskCheck? = nil
    ) {
        self.status = status
        self.file = file
        self.width = width
        self.height = height
        self.method = method
        self.instanceCount = instanceCount
        self.selectedInstances = selectedInstances
        self.selection = selection
        self.error = error
        self.inputRegion = inputRegion
        self.inputRegionSource = inputRegionSource
        self.check = check
    }

    public static let notGenerated = MaskInfo(status: .notGenerated)

    /// 失敗（写真は残す）。
    public static func failed(_ message: String, instanceCount: Int? = nil, plan: MaskCropPlan? = nil) -> MaskInfo {
        MaskInfo(status: .failed, method: visionMethod, instanceCount: instanceCount, error: message,
                 inputRegion: plan?.recordedRegion, inputRegionSource: plan?.source)
    }

    /// 切り抜きの範囲を記録する。
    public func recording(_ plan: MaskCropPlan) -> MaskInfo {
        var m = self
        m.inputRegion = plan.recordedRegion
        m.inputRegionSource = plan.source
        return m
    }
}

// MARK: - 決まり（conventions）

public enum Conventions {
    /// session.json の `conventions` に入れる文字列（docs/data-format.md の表と同じ内容）。
    public static let text: [String: String] = [
        "units": "メートル、角度は度、時刻は ISO 8601（タイムゾーン付き）、arFrameTimestamp は秒（端末の起動からの時間）",
        "worldFrame": "ARKit の world（worldAlignment = .gravity）。右手系、+Y が重力の反対（上）、原点は AR セッション開始時の端末位置。同じ referenceFrameId の中でだけ意味を持つ",
        "matrices": "入れ子の配列で行優先（m[row][col]）。点は列ベクトルで p' = M · p",
        "cameraToWorld": "ARKit の ARCamera.transform（カメラ → 世界）。カメラ座標は ARKit の決まりで、+X が保存した画像の右、+Y が画像の上、−Z が見ている方向。OpenCV 式（x 右・y 下・z 前）にするには右から diag(1, −1, −1, 1) を掛ける",
        "intrinsics": "3 × 3 の K（行優先、ピクセル単位、原点は保存した画像の左上）。intrinsicsResolution の大きさの画像に対する値",
        "imageOrientation": "保存した画像はセンサーの向き（横長）のまま。EXIF Orientation は 1。displayRotationDegClockwise は、まっすぐ見るために時計回りに回す角度（表示用の情報で、K は回さない画像のもの）",
        "objectToWorld": "原点は作品の底面中央（基準マーカー）。+Y は上、+Z は基準点から正面のカメラへ向かう水平方向、+X = Y × Z（正面から見て右）",
        "azimuthDeg": "作品座標でのカメラ位置 (x, z) について atan2(x, z) を度にして 0〜360。0 = 正面、90 = +X 側（正面から見て右へ回り込んだ位置）",
        "elevationDeg": "作品の中心（基準点から heightM / 2 上）からカメラへのベクトルの水平面からの角度。上から見下ろすと正",
        "distanceM": "作品の中心（基準点から heightM / 2 上）からカメラまでの距離",
    ]
}
