import Foundation
import CaptureCore

public enum PackInfo {
    public static let toolName = "memoria-pack"
    public static let toolVersion = "0.6.0"
}

public struct Size3: Codable, Equatable, Sendable {
    /// Along X (left–right seen from the front).
    public var width: Double
    /// Along Z (front–back).
    public var depth: Double
    /// Along Y (up).
    public var height: Double
}

/// `measurements.json`.
public struct Measurements: Codable, Sendable {
    public struct Uncertainty: Codable, Equatable, Sendable {
        /// ± per dimension (cm): voxel edge + median reprojection slack.
        public var plusMinusCm: Double
        public var voxelCm: Double
        @NullCodable public var reprojectionSlackCm: Double?
        /// The top can be this much too high when the object's top is flat (the photos only look down at it);
        /// rounded tops are affected less. The true height lies roughly in [height − this, height + plusMinus].
        @NullCodable public var heightOverestimateUpToCm: Double?
        public var note: String
    }

    public struct Footprint: Codable, Equatable, Sendable {
        public var lengthCm: Double
        public var widthCm: Double
        /// Direction of the long side (azimuth convention: 0 = front–back along Z, 90 = left–right along X).
        public var longAxisAzimuthDeg: Double
    }

    public struct Grid: Codable, Equatable, Sendable {
        public var nx: Int, ny: Int, nz: Int
        public var voxelSizeM: Double
        public var searchBoxMinM: [Double]
        public var searchBoxMaxM: [Double]
    }

    public struct SkippedView: Codable, Equatable, Sendable {
        public var photoId: String
        public var sequence: Int
        public var reason: String
    }

    public struct Mesh: Codable, Equatable, Sendable {
        public var file: String
        public var vertices: Int
        public var faces: Int
        public var voxelSizeM: Double
    }

    /// The flat artwork's sheet (`workKind` "flat"): the size to use, from the paper the person picked from the app's list
    /// (`declaredSize.sheet`, preferred) or, without one, the sheet measured by projecting its four corners onto an ARKit plane.
    public struct Sheet: Codable, Equatable, Sendable {
        /// "declared" (the person picked this paper from the app's list; not measured) | "measured" (ARKit plane).
        public var source: String
        /// Horizontal side of `views/artwork.jpg` (the rectified picture), metres. null when the paper was declared but its
        /// orientation is unknown (no sheet corners were found): then only `longSideM`/`shortSideM` are known.
        @NullCodable public var widthM: Double?
        /// Vertical side of `views/artwork.jpg`, metres (null as `widthM`).
        @NullCodable public var heightM: Double?
        @NullCodable public var widthCm: Double?
        @NullCodable public var heightCm: Double?
        public var longSideM: Double
        public var shortSideM: Double
        public var longSideCm: Double
        public var shortSideCm: Double
        /// "landscape" (width = long side) | "portrait" (width = short side) | null (unknown).
        @NullCodable public var orientation: String?
        /// The list id (e.g. "yatsugiri") and its Japanese name ("八つ切") when `source` is "declared"; null otherwise.
        @NullCodable public var declaredSheetId: String?
        @NullCodable public var declaredSheetName: String?
        /// "existingPlaneGeometry" | "estimatedPlane" (the ARKit plane the corners were projected onto) when `source` is "measured"; null otherwise.
        @NullCodable public var planeSource: String?
        /// The ARKit measurement whenever there is one (also next to a declared paper, for reference). null when not measured.
        @NullCodable public var measured: MeasuredSheet?
        @NullCodable public var photoId: String?

        public init(source: String, widthM: Double?, heightM: Double?, longSideM: Double, shortSideM: Double, orientation: String?,
                    declaredSheetId: String?, declaredSheetName: String?, planeSource: String?, measured: MeasuredSheet?, photoId: String?) {
            self.source = source
            self.widthM = widthM.map(round6)
            self.heightM = heightM.map(round6)
            widthCm = widthM.map { round1($0 * 100) }
            heightCm = heightM.map { round1($0 * 100) }
            self.longSideM = round6(longSideM)
            self.shortSideM = round6(shortSideM)
            longSideCm = round1(longSideM * 100)
            shortSideCm = round1(shortSideM * 100)
            self.orientation = orientation
            self.declaredSheetId = declaredSheetId
            self.declaredSheetName = declaredSheetName
            self.planeSource = planeSource
            self.measured = measured
            self.photoId = photoId
        }
    }

    /// The sheet measured on the ARKit plane (`photos[].flat.size`).
    public struct MeasuredSheet: Codable, Equatable, Sendable {
        public var widthM: Double
        public var heightM: Double
        public var widthCm: Double
        public var heightCm: Double
        public var planeSource: String

        public init(_ size: FlatSheetSize) {
            widthM = round6(size.widthM)
            heightM = round6(size.heightM)
            widthCm = round1(size.widthM * 100)
            heightCm = round1(size.heightM * 100)
            planeSource = size.planeSource
        }
    }

    /// 3D work: the height the person typed in the app (`declaredSize.heightM`). Not measured; prefer it over the derived or
    /// measured height. The other numbers in this file are left as derived (nothing is rescaled).
    public struct DeclaredHeight: Codable, Equatable, Sendable {
        public var heightM: Double
        public var heightCm: Double
        /// "userEntered".
        public var source: String
        public var note: String

        public init(heightM: Double) {
            self.heightM = round6(heightM)
            heightCm = round1(heightM * 100)
            source = "userEntered"
            note = "Typed in by the person who took the photos (not measured). Prefer it over sizeM.height; choose width and depth so that their ratio to this height matches the photos. sizeM is left as derived (not rescaled)."
        }
    }

    /// Heading-guided sessions (`guidance: "heading"`): how the object centre and the approximate size were derived after capture.
    public struct HeadingInfo: Codable, Equatable, Sendable {
        /// "ok" | "lowConfidence" | "unknown" (the object centre).
        public var derivationStatus: String
        public var reasons: [String]
        @NullCodable public var centerWorld: [Double]?
        @NullCodable public var residualRmsM: Double?
        @NullCodable public var residualMaxM: Double?
        public var photoIds: [String]
        public var excludedPhotoIds: [String]
        /// "base" (y = 0 is the table under the object) | "center" (table height unknown; y = 0 is the centre's height).
        @NullCodable public var origin: String?
        /// The size estimate as derived (lowerM / upperM / crossChecks …). null when not computed.
        @NullCodable public var size: HeadingSizeEstimate?
        /// "iPhone" (from session.json) | "memoria-pack" (derived here because the session had none yet).
        public var computedBy: String

        public init(derivation d: HeadingDerivation, computedBy: String) {
            derivationStatus = d.status.rawValue
            reasons = d.reasons.map(\.rawValue)
            centerWorld = d.centerWorld.map { [$0.simd.x, $0.simd.y, $0.simd.z] }
            residualRmsM = d.residualRmsM
            residualMaxM = d.residualMaxM
            photoIds = d.photoIds
            excludedPhotoIds = d.excludedPhotoIds
            origin = d.origin?.rawValue
            size = d.size
            self.computedBy = computedBy
        }
    }

    public var schema = "memoria.claude-pack.measurements"
    public var schemaVersion = 1
    public var sessionId: String
    /// "object" (3D work: hull / cylinder) | "flat" (flat artwork: `sheet`, no 3D size). Missing in packages before 0.3.0.
    public var workKind: String? = "object"
    /// Flat artwork only: the sheet size (the declared paper, else the measured one), or null when neither is known.
    /// `sizeCm`/`sizeM` stay null for flat artwork.
    @NullCodable public var sheet: Sheet?
    /// 3D work only: the height the person typed in (null when not entered). Preferred over the derived/measured height.
    @NullCodable public var declaredHeight: DeclaredHeight?
    /// "ok" (visual hull) | "approximate" (too few silhouettes: `sizeCm` is the user-fitted cylinder, see `method`) | "unavailable"
    public var status: String
    @NullCodable public var unavailableReason: String?
    /// "visualHull" | "userCylinder" (the cylinder fitted with the AR guide during capture, not a measurement)
    /// | "headingDerived" (heading-guided capture: approximate size derived after capture from masks and poses; see `heading`)
    /// | "flatSheetCorners" (flat artwork: the sheet's corners projected onto an ARKit plane; see `sheet`)
    /// | "declaredSheet" (flat artwork: the paper the person picked from the app's list; see `sheet`)
    /// | "freeCapture" (3D work shot freely: no size is derived; `status` is "unavailable", see `declaredHeight`)
    public var method = "visualHull"
    public var frame: [String: String] = [
        "units": "metres (sizeCm in centimetres)",
        "origin": "x, z: the capture's reference point (base centre); y = 0: the table plane estimated from the hull (see tablePlaneAboveReferenceM)",
        "y": "up (gravity opposite)",
        "z": "towards the front camera (views/front.jpg looks along -Z)",
        "x": "right as seen from the front (x = y × z)",
    ]
    @NullCodable public var referenceFrameId: String?
    /// The table plane estimated from the hull, measured from the capture's reference point (m, up is positive).
    /// The package's frame puts y = 0 on this plane (x and z stay as in the capture's object frame).
    @NullCodable public var tablePlaneAboveReferenceM: Double?
    @NullCodable public var sizeCm: Size3?
    @NullCodable public var sizeM: Size3?
    @NullCodable public var bboxMinM: [Double]?
    @NullCodable public var bboxMaxM: [Double]?
    @NullCodable public var footprint: Footprint?
    @NullCodable public var uncertainty: Uncertainty?
    /// "normal" | "low" (few silhouettes, silhouettes that disagree, unchecked masks): see `confidenceReasons`.
    @NullCodable public var confidence: String?
    public var confidenceReasons: [String] = []
    /// Silhouettes whose mask was never checked (`candidate` without `check`, older sessions).
    public var uncheckedMaskViews = 0
    @NullCodable public var grid: Grid?
    @NullCodable public var voxelCount: Int?
    /// voxelCount · voxel³ (an upper bound: the hull fills concavities and the hidden underside).
    @NullCodable public var volumeCm3: Double?
    /// Voxels dropped as small detached fragments (not the largest connected piece).
    @NullCodable public var removedFragmentVoxels: Int?
    /// Sides of the search box the hull reaches ("x-", "x+", "z-", "z+", "y+"): the object may be larger there.
    public var touchesSearchBox: [String] = []
    public var viewsUsed = 0
    /// Photos of the reference frame with a usable silhouette (mask). Below `PackBuilder.minimumHullViews` no hull is carved.
    public var usableSilhouettes = 0
    public var viewsUsedPhotoIds: [String] = []
    public var viewsSkipped: [SkippedView] = []
    public var perViewSlack: [VisualHull.ViewSlack] = []
    /// The cylinder the user fitted with the AR guide (the search box is this × 1.3).
    @NullCodable public var userCylinder: ObjectSize?
    @NullCodable public var baseSource: String?
    /// Heading-guided sessions only (null otherwise).
    @NullCodable public var heading: HeadingInfo?
    @NullCodable public var mesh: Mesh?
    public var caveats: [String] = []
    public var seconds: Double = 0
}

/// `pack.json`: the package's index and provenance.
public struct PackIndex: Codable, Sendable {
    public struct Provenance: Codable, Equatable, Sendable {
        public var sessionId: String
        @NullCodable public var manifestHash: String?
        @NullCodable public var receivedAt: String?
        public var generatedAt: String
        public var tool: String
        public var toolVersion: String
        public var sourceFolder: String
        /// Whether `views/*_cutout.png` were written (`--cutouts`). Missing in packages from before the option (they had grey JPG cutouts).
        public var cutouts: Bool?
    }

    public struct Coverage: Codable, Equatable, Sendable {
        @NullCodable public var referenceFrameId: String?
        public var referenceFrameIds: [String]
        public var photoCount: Int
        public var photosInReferenceFrame: Int
        @NullCodable public var minElevationDeg: Double?
        @NullCodable public var maxElevationDeg: Double?
        public var directionPlanId: String
        public var bands: [Band]
        public var bottomCaptured = false
        public var missingViews: [String]
        public var weakViews: [String]
    }

    public struct Band: Codable, Equatable, Sendable {
        public var elevationDeg: Double
        /// Directions of the plan at this elevation.
        public var targets: Int
        /// Directions with at least one photo (direction confirmed, this reference frame).
        public var shot: Int
        /// Directions whose best photo has a checked, usable mask (the app's "done").
        public var done: Int
    }

    public struct MaskIssue: Codable, Equatable, Sendable {
        public var sequence: Int
        public var photoId: String
        @NullCodable public var targetId: String?
        @NullCodable public var referenceFrameId: String?
        public var status: String
        @NullCodable public var check: String?
        public var reasons: [String]
    }

    /// Flat artwork: where the picture came from (the photo, its corners, the rectified image in the session folder).
    public struct FlatSource: Codable, Equatable, Sendable {
        @NullCodable public var photoId: String?
        @NullCodable public var sequence: Int?
        /// The sheet's corners in the stored photo (pixels; topLeft… as seen upright). null when no sheet was found.
        @NullCodable public var corners: FlatQuad?
        @NullCodable public var sheetAtFrameEdge: Bool?
        /// The full-resolution rectified image in the session folder (`rectified/<photoId>.jpg`), if the app made one.
        @NullCodable public var rectifiedInSession: String?
        /// "rectified" (views/artwork.jpg is the perspective-corrected sheet) | "uprightPhoto" (no rectified image: the photo turned upright) | "none".
        public var artworkSource: String
        /// Lean of the camera from straight down: `90 − elevationDeg` (degrees). null without a photo.
        @NullCodable public var cameraTiltFromVerticalDeg: Double?
    }

    /// Free capture (`guidance` "free"): how many photos the session has and how the views were picked.
    public struct FreeSource: Codable, Equatable, Sendable {
        public var photoCount: Int
        /// Photos written to `views/photo-NN.jpg`.
        public var viewCount: Int
        /// "all" (every photo, in shooting order) | "evenlySpaced" (more than `PackBuilder.maxFreeViews`: spread evenly over the shooting order).
        public var selection: String

        public init(photoCount: Int, viewCount: Int, selection: String) {
            self.photoCount = photoCount
            self.viewCount = viewCount
            self.selection = selection
        }
    }

    public var schema = "memoria.claude-pack"
    public var schemaVersion = 1
    /// "object" | "flat". Missing in packages before 0.3.0 (they are all "object").
    public var workKind: String?
    /// "free" | "heading" | "baseCylinder" for 3D work (how the capture was guided; session.json `guidance`), null for flat artwork.
    /// Missing in packages before 0.4.0.
    public var guidance: String?
    public var provenance: Provenance
    public var title: String
    public var views: [ViewChoice]
    public var coverage: Coverage
    public var maskIssues: [MaskIssue]
    public var files: [String]
    public var timingsS: [String: Double]
    /// Flat artwork only.
    public var flat: FlatSource?
    /// Free capture only (missing in packages before 0.6.0).
    public var free: FreeSource?
}
