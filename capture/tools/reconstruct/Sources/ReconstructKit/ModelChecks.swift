import Foundation
import ModelIO
import simd
import CaptureCore

public struct MeshStats: Codable, Equatable, Sendable {
    public var meshCount: Int
    public var vertexCount: Int
    public var triangleCount: Int
    public var boundsMin: [Double]
    public var boundsMax: [Double]
    /// boundsMax − boundsMin, in the model's units (metres when the session could recover scale).
    public var extent: [Double]

    /// Reads the USDZ with ModelIO and counts vertices / triangles of every mesh.
    public static func read(_ url: URL) -> MeshStats? {
        guard MDLAsset.canImportFileExtension(url.pathExtension) else { return nil }
        let asset = MDLAsset(url: url)
        var meshes = 0, vertices = 0, triangles = 0
        func visit(_ object: MDLObject) {
            if let mesh = object as? MDLMesh {
                meshes += 1
                vertices += mesh.vertexCount
                for case let sub as MDLSubmesh in mesh.submeshes ?? [] {
                    switch sub.geometryType {
                    case .triangles: triangles += sub.indexCount / 3
                    case .quads: triangles += sub.indexCount / 4 * 2
                    case .triangleStrips: triangles += max(sub.indexCount - 2, 0)
                    default: break
                    }
                }
            }
            for child in object.children.objects { visit(child) }
        }
        for i in 0..<asset.count { visit(asset.object(at: i)) }
        guard meshes > 0 else { return nil }
        let box = asset.boundingBox
        let lo = SIMD3<Double>(box.minBounds), hi = SIMD3<Double>(box.maxBounds)
        let round = { (v: SIMD3<Double>) in [v.x, v.y, v.z].map { ($0 * 1e5).rounded() / 1e5 } }
        return MeshStats(meshCount: meshes, vertexCount: vertices, triangleCount: triangles,
                         boundsMin: round(lo), boundsMax: round(hi), extent: round(hi - lo))
    }
}

/// Compares the camera centres PhotogrammetrySession estimated with the ARKit ones from session.json.
/// Pairwise distances are invariant to the unknown rotation/translation between the two frames, so the
/// ratio ARKit distance / estimated distance should be the same for every pair if the reconstruction
/// agrees with ARKit. Only pairs within one reference frame are compared (ARKit worlds differ between frames).
public struct ScaleCheck: Codable, Equatable, Sendable {
    public var referenceFrameId: String
    public var posedSamples: Int
    public var pairs: Int
    /// Median of ARKit metres per model unit (≈ 1 if the model is already metric).
    @NullCodable public var medianScale: Double?
    /// (p90 − p10) / median of the per-pair ratios; small (< 0.1) means the poses agree with ARKit.
    @NullCodable public var relativeSpread: Double?

    /// - Parameters: `samples` = (referenceFrameId, ARKit camera centre, estimated translation).
    public static func compute(_ samples: [(String, SIMD3<Double>, SIMD3<Double>)]) -> [ScaleCheck] {
        let byFrame = Dictionary(grouping: samples, by: { $0.0 })
        return byFrame.keys.sorted().map { frame in
            let s = byFrame[frame]!
            var ratios: [Double] = []
            for i in 0..<s.count {
                for j in (i + 1)..<s.count {
                    let a = simd_distance(s[i].1, s[j].1)
                    let e = simd_distance(s[i].2, s[j].2)
                    if a > 0.02 && e > 1e-9 { ratios.append(a / e) }
                }
            }
            ratios.sort()
            guard !ratios.isEmpty else {
                return ScaleCheck(referenceFrameId: frame, posedSamples: s.count, pairs: 0, medianScale: nil, relativeSpread: nil)
            }
            func q(_ p: Double) -> Double { ratios[min(ratios.count - 1, max(0, Int((Double(ratios.count - 1) * p).rounded())))] }
            let median = q(0.5)
            return ScaleCheck(referenceFrameId: frame, posedSamples: s.count, pairs: ratios.count,
                              medianScale: (median * 1e5).rounded() / 1e5,
                              relativeSpread: ((q(0.9) - q(0.1)) / median * 1e4).rounded() / 1e4)
        }
    }
}
