import Foundation
import simd
import CaptureCore

/// One photo of the session and what this run does with it.
public struct PlannedInput: Codable, Equatable, Sendable {
    public var sequence: Int
    public var photoId: String
    /// PhotogrammetrySample.id (= sequence, unique within the session).
    public var sampleId: Int
    @NullCodable public var referenceFrameId: String?
    @NullCodable public var targetId: String?
    public var directionConfirmed: Bool
    public var maskStatus: String
    @NullCodable public var maskCheckStatus: String?
    public var maskCheckReasons: [String]
    public var superseded: Bool
    public var imageFile: String
    public var included: Bool
    @NullCodable public var exclusionReason: String?
    /// Whether a mask PNG is handed to PhotogrammetrySession for this sample, and why (not).
    public var maskUsed: Bool
    public var maskReason: String
    @NullCodable public var maskFile: String?
    /// Gravity passed as PhotogrammetrySample.gravity (unit g), or null when gravity is off.
    @NullCodable public var gravity: [Double]?
    /// Gravity in the ARKit camera / stored-image axes, always recorded for reference.
    public var gravityCameraFrame: [Double]
    /// EXIF FocalLenIn35mmFilm derived from the intrinsics (diagonal field of view).
    public var focalLength35mm: Int
}

public enum InputPlanner {
    /// Mask rule of `--masks auto` (also what `--include good` calls a usable mask).
    public static func autoMaskDecision(_ photo: Photo) -> (use: Bool, reason: String) {
        switch photo.mask.status {
        case .confirmed:
            return (true, "confirmed")
        case .candidate:
            switch photo.mask.check?.status {
            case nil: return (true, "candidate, no check recorded")
            case .ok?: return (true, "candidate, check ok")
            case .suspicious?:
                return (false, "candidate, check suspicious (\(photo.mask.check!.reasons.map(\.rawValue).joined(separator: ",")))")
            case .unknown?:
                return (false, "candidate, check unknown (\(photo.mask.check!.reasons.map(\.rawValue).joined(separator: ",")))")
            }
        case .failed, .noObject, .notGenerated, .processing:
            return (false, "mask status \(photo.mask.status.rawValue)")
        }
    }

    public static func plan(session: CaptureSession, folder: URL, options: Options,
                            fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> [PlannedInput] {
        let superseded = Set(Readiness.make(session: session).supersededPhotoIds)
        var supersededBy: [String: String] = [:]
        for frame in session.referenceFrames {
            for t in Coverage.progress(in: session, referenceFrameId: frame.id).targets {
                for id in t.supersededPhotoIds { supersededBy[id] = t.photoId }
            }
        }
        return session.photos.sorted { $0.sequence < $1.sequence }.map { photo in
            let imageURL = folder.appendingPathComponent(photo.image.file)
            let maskFile = photo.mask.file
            let maskOnDisk = maskFile.map { fileExists(folder.appendingPathComponent($0)) } ?? false
            let auto = autoMaskDecision(photo)

            // Which mask is handed over.
            var maskUsed = false
            var maskReason: String
            switch options.masks {
            case .off:
                maskReason = "--masks off"
            case .on:
                if photo.mask.status.hasFile && maskFile != nil {
                    maskUsed = true
                    maskReason = "--masks on: \(photo.mask.status.rawValue)" + (photo.mask.check.map { ", check \($0.status.rawValue)" } ?? "")
                } else {
                    maskReason = "mask status \(photo.mask.status.rawValue)"
                }
            case .auto:
                maskUsed = auto.use
                maskReason = auto.reason
            }
            if maskUsed && !maskOnDisk {
                maskUsed = false
                maskReason += "; mask file missing on disk"
            }
            let usableMask = auto.use && maskOnDisk

            // Whether the photo is used at all.
            var exclusion: String?
            if !fileExists(imageURL) {
                exclusion = "image file missing: \(photo.image.file)"
            } else if let frames = options.frames, !frames.contains(photo.referenceFrameId ?? "none") {
                exclusion = "--frames: reference frame \(photo.referenceFrameId ?? "none") not selected"
            } else if options.include == .good {
                if !photo.direction.confirmed {
                    exclusion = "--include good: direction not confirmed (\(photo.direction.unconfirmedReason?.rawValue ?? "unknown reason"))"
                } else if !usableMask {
                    exclusion = "--include good: no usable mask (\(auto.reason)\(auto.use && !maskOnDisk ? ", file missing" : ""))"
                } else if superseded.contains(photo.photoId) {
                    let by = supersededBy[photo.photoId].flatMap { id in session.photo(id: id).map { "#\($0.sequence)" } } ?? "a later photo"
                    exclusion = "--include good: superseded by \(by) for target \(photo.direction.targetId ?? "?")"
                }
            }
            if exclusion != nil { maskUsed = false }

            let gCam = Gravity.inCameraFrame(cameraToWorld: photo.camera.cameraToWorld.simd)
            let gravity: [Double]?
            switch options.gravity {
            case .off: gravity = nil
            case .on: gravity = Gravity.deviceFrame(fromCamera: gCam).array
            case .camera: gravity = gCam.array
            }

            return PlannedInput(
                sequence: photo.sequence, photoId: photo.photoId, sampleId: photo.sequence,
                referenceFrameId: photo.referenceFrameId, targetId: photo.direction.targetId,
                directionConfirmed: photo.direction.confirmed, maskStatus: photo.mask.status.rawValue,
                maskCheckStatus: photo.mask.check?.status.rawValue, maskCheckReasons: photo.mask.check?.reasons.map(\.rawValue) ?? [],
                superseded: superseded.contains(photo.photoId), imageFile: photo.image.file,
                included: exclusion == nil, exclusionReason: exclusion,
                maskUsed: maskUsed, maskReason: exclusion == nil ? maskReason : "photo excluded",
                maskFile: maskUsed ? maskFile : nil,
                gravity: gravity, gravityCameraFrame: gCam.array,
                focalLength35mm: FocalLength.equivalent35mm(photo: photo)
            )
        }
    }
}

public enum Gravity {
    /// Unit gravity (pointing towards the earth, in g) in the ARKit camera frame of the photo:
    /// ARKit world is gravity aligned with +Y up, so world gravity is (0, −1, 0); camera = Rᵀ · world.
    /// ARKit camera axes: +X = right of the stored (sensor-landscape) image, +Y = up in that image, −Z = viewing direction.
    public static func inCameraFrame(cameraToWorld m: simd_double4x4) -> SIMD3<Double> {
        let r = simd_double3x3(m.columns.0.xyz, m.columns.1.xyz, m.columns.2.xyz)
        return simd_normalize(r.transpose * SIMD3(0, -1, 0))
    }

    /// The same vector in the iPhone's device frame as CMDeviceMotion reports it
    /// (+X towards the right edge of the portrait screen, +Y towards the top edge, +Z out of the screen).
    /// ARKit documents the camera +X axis as running along the long side from the front camera towards
    /// the bottom (Home button) and +Y as up in landscapeRight, with −Z through the back camera, so
    /// camera X = −device Y, camera Y = device X, camera Z = device Z.
    public static func deviceFrame(fromCamera g: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(g.y, -g.x, g.z)
    }
}

public enum FocalLength {
    /// 35 mm equivalent focal length from the pinhole intrinsics: f35 = f_px · 43.27 mm / image diagonal_px
    /// (the full-frame diagonal over the image diagonal; does not need the sensor size).
    public static func equivalent35mm(photo: Photo) -> Int {
        let k = photo.camera.intrinsics.simd
        let fx = k[0][0], fy = k[1][1]
        let scale = Double(photo.image.width) / Double(max(photo.camera.intrinsicsResolution.width, 1))
        let f = (fx + fy) / 2 * scale
        let diagonal = hypot(Double(photo.image.width), Double(photo.image.height))
        return Int((f * hypot(36.0, 24.0) / diagonal).rounded())
    }
}

extension SIMD4 where Scalar == Double {
    var xyz: SIMD3<Double> { SIMD3(x, y, z) }
}

extension SIMD3 where Scalar == Double {
    var array: [Double] { [x, y, z].map { ($0 * 1e6).rounded() / 1e6 } }
}
