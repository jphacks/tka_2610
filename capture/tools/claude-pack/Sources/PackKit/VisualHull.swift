import Foundation
import simd
import CaptureCore

/// One silhouette for the visual hull: a photo's pose and K, and its mask (any resolution; K is scaled to it).
public struct HullView: Sendable {
    public var id: String
    public var cameraToWorld: simd_double4x4
    /// K for an image of `intrinsicsWidth × intrinsicsHeight` (session.json `intrinsicsResolution`).
    public var intrinsics: simd_double3x3
    public var intrinsicsWidth: Double
    public var intrinsicsHeight: Double
    /// 0/1 mask (1 = object).
    public var mask: GrayImage

    public init(id: String, cameraToWorld: simd_double4x4, intrinsics: simd_double3x3,
                intrinsicsWidth: Double, intrinsicsHeight: Double, mask: GrayImage) {
        self.id = id
        self.cameraToWorld = cameraToWorld
        self.intrinsics = intrinsics
        self.intrinsicsWidth = intrinsicsWidth
        self.intrinsicsHeight = intrinsicsHeight
        self.mask = mask
    }
}

/// Settings of the carving.
public struct HullSettings: Sendable {
    /// Wanted voxel edge (m). Grown when the grid would exceed `maxVoxels`.
    public var voxelSize = 0.002
    public var maxVoxels = 160 * 160 * 160
    /// The search box is the reference cylinder (radius, height) times this.
    public var boundsScale = 1.3
    /// Mask dilation (mask pixels) before carving, to absorb small pose and mask-edge errors.
    public var maskDilation = 1
    /// A voxel must project inside at least this many images; voxels seen less are dropped (never confirmed).
    public var minSeenViews = 2
    /// A voxel is carved when it falls outside the (dilated) mask in more than
    /// max(`carveTolerance`, `carveFraction` · views that see it) views. Above 0 it tolerates a few bad masks.
    public var carveTolerance = 0
    public var carveFraction = 0.1
    /// The grid also reaches this far below the reference point (fraction of the search radius), so a reference
    /// point that is off the table does not cut the object, and the hidden wedge under the object can be measured.
    public var belowReferenceFraction = 0.5
    public init() {}
}

/// Occupancy grid in the object frame (origin = base centre, +Y up, +Z front, metres).
public struct VoxelGrid: Sendable {
    public var nx: Int, ny: Int, nz: Int
    public var voxelSize: Double
    /// Object-frame position of the corner of voxel (0, 0, 0).
    public var origin: SIMD3<Double>
    public var occupied: [Bool]

    public init(nx: Int, ny: Int, nz: Int, voxelSize: Double, origin: SIMD3<Double>, occupied: [Bool]? = nil) {
        self.nx = nx
        self.ny = ny
        self.nz = nz
        self.voxelSize = voxelSize
        self.origin = origin
        self.occupied = occupied ?? [Bool](repeating: false, count: nx * ny * nz)
    }

    @inline(__always) public func index(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * ny + j) * nx + i }
    @inline(__always) public func isOccupied(_ i: Int, _ j: Int, _ k: Int) -> Bool {
        i >= 0 && j >= 0 && k >= 0 && i < nx && j < ny && k < nz && occupied[index(i, j, k)]
    }
    public func center(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Double> {
        origin + SIMD3(Double(i) + 0.5, Double(j) + 0.5, Double(k) + 0.5) * voxelSize
    }
    public var count: Int { occupied.reduce(0) { $0 + ($1 ? 1 : 0) } }

    /// Index bounds of the occupied voxels (inclusive), or nil when empty.
    public func indexBounds() -> (min: SIMD3<Int>, max: SIMD3<Int>)? {
        var lo = SIMD3(Int.max, Int.max, Int.max), hi = SIMD3(-1, -1, -1)
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx where occupied[index(i, j, k)] {
            lo = SIMD3(min(lo.x, i), min(lo.y, j), min(lo.z, k))
            hi = SIMD3(max(hi.x, i), max(hi.y, j), max(hi.z, k))
        } } }
        return hi.x < 0 ? nil : (lo, hi)
    }

    /// Metric bounding box of the occupied voxels (voxel faces, not centres).
    public func bounds() -> (min: SIMD3<Double>, max: SIMD3<Double>)? {
        guard let b = indexBounds() else { return nil }
        let lo = origin + SIMD3(Double(b.min.x), Double(b.min.y), Double(b.min.z)) * voxelSize
        let hi = origin + SIMD3(Double(b.max.x + 1), Double(b.max.y + 1), Double(b.max.z + 1)) * voxelSize
        return (lo, hi)
    }

    /// Keeps only the largest 26-connected component. Returns how many voxels were removed.
    @discardableResult
    public mutating func keepLargestComponent() -> Int {
        var label = [Int32](repeating: 0, count: occupied.count)
        var sizes: [Int] = [0]
        var stack: [Int] = []
        for start in 0..<occupied.count where occupied[start] && label[start] == 0 {
            let id = Int32(sizes.count)
            var size = 0
            label[start] = id
            stack.append(start)
            while let v = stack.popLast() {
                size += 1
                let i = v % nx, j = (v / nx) % ny, k = v / (nx * ny)
                for dk in -1...1 { for dj in -1...1 { for di in -1...1 {
                    let a = i + di, b = j + dj, c = k + dk
                    guard a >= 0, b >= 0, c >= 0, a < nx, b < ny, c < nz else { continue }
                    let n = index(a, b, c)
                    if occupied[n] && label[n] == 0 { label[n] = id; stack.append(n) }
                } } }
            }
            sizes.append(size)
        }
        guard sizes.count > 2 else { return 0 }
        let keep = Int32(sizes.indices.dropFirst().max { sizes[$0] < sizes[$1] }!)
        var removed = 0
        for v in 0..<occupied.count where occupied[v] && label[v] != keep {
            occupied[v] = false
            removed += 1
        }
        return removed
    }

    /// Grid with `factor`-times larger voxels (a coarse voxel is occupied when any fine voxel is).
    public func coarsened(by factor: Int) -> VoxelGrid {
        guard factor > 1 else { return self }
        let cx = (nx + factor - 1) / factor, cy = (ny + factor - 1) / factor, cz = (nz + factor - 1) / factor
        var g = VoxelGrid(nx: cx, ny: cy, nz: cz, voxelSize: voxelSize * Double(factor), origin: origin)
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx where occupied[index(i, j, k)] {
            g.occupied[g.index(i / factor, j / factor, k / factor)] = true
        } } }
        return g
    }
}

/// Visual hull: carve a voxel grid with the silhouettes of posed photos.
public enum VisualHull {
    /// Search box around the base point: |x|, |z| ≤ scale·radius, 0 ≤ y ≤ scale·height (only above the table).
    /// Search box around the reference point: |x|, |z| ≤ scale·radius, −belowReferenceFraction·scale·radius ≤ y ≤ scale·height.
    public static func grid(radiusM: Double, heightM: Double, settings: HullSettings) -> VoxelGrid {
        let half = radiusM * settings.boundsScale
        let top = heightM * settings.boundsScale
        let below = half * settings.belowReferenceFraction
        var s = settings.voxelSize
        let volume = (2 * half) * (2 * half) * (top + below)
        if volume / (s * s * s) > Double(settings.maxVoxels) { s = cbrt(volume / Double(settings.maxVoxels)) }
        let nx = max(1, Int((2 * half / s).rounded(.up)))
        let nBelow = Int((below / s).rounded(.up))
        let ny = max(1, Int((top / s).rounded(.up)) + nBelow)
        return VoxelGrid(nx: nx, ny: ny, nz: nx, voxelSize: s,
                         origin: SIMD3(-Double(nx) * s / 2, -Double(nBelow) * s, -Double(nx) * s / 2))
    }

    struct PreparedView {
        var r0: SIMD4<Double>, r1: SIMD4<Double>, r2: SIMD4<Double>  // rows of objectToCamera
        var fx: Double, fy: Double, cx: Double, cy: Double
        var w: Int, h: Int
        var mask: [UInt8]
    }

    static func prepare(_ view: HullView, objectToWorld: simd_double4x4, dilation: Int) -> PreparedView {
        let m = view.cameraToWorld.inverse * objectToWorld
        let t = m.transpose
        let sx = Double(view.mask.width) / view.intrinsicsWidth
        let sy = Double(view.mask.height) / view.intrinsicsHeight
        let k = view.intrinsics
        let mask = view.mask.dilated(radius: dilation)
        return PreparedView(r0: t.columns.0, r1: t.columns.1, r2: t.columns.2,
                            fx: k[0][0] * sx, fy: k[1][1] * sy, cx: k[2][0] * sx, cy: k[2][1] * sy,
                            w: view.mask.width, h: view.mask.height, mask: mask.pixels)
    }

    /// Projects an object-frame point into a prepared view (mask pixels), or nil behind the camera.
    @inline(__always) static func project(_ p: SIMD4<Double>, _ v: PreparedView) -> (u: Double, v: Double, depth: Double)? {
        let x = simd_dot(v.r0, p), y = simd_dot(v.r1, p), z = simd_dot(v.r2, p)
        let depth = -z
        guard depth > 0.01 else { return nil }
        // ARKit camera: +X image right, +Y image up, −Z forward; pixel y grows downwards.
        return (v.fx * x / depth + v.cx, v.fy * (-y) / depth + v.cy, depth)
    }

    /// Carves `grid` (all voxels start occupied). A voxel survives when it projects inside at least
    /// `minSeenViews` images and lands outside the dilated mask in at most `carveTolerance` of them.
    /// Projections outside an image (or behind the camera) are "unknown" and never carve.
    public static func carve(grid: VoxelGrid, views: [HullView], objectToWorld: simd_double4x4, settings: HullSettings) -> VoxelGrid {
        let prepared = views.map { prepare($0, objectToWorld: objectToWorld, dilation: settings.maskDilation) }
        var out = grid
        let nx = grid.nx, ny = grid.ny, nz = grid.nz
        var occ = [Bool](repeating: false, count: nx * ny * nz)
        let slices = DispatchQueue.concurrentPerform
        occ.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!
            slices(nz) { k in
                for j in 0..<ny {
                    for i in 0..<nx {
                        let c = grid.center(i, j, k)
                        let p = SIMD4(c, 1)
                        var seen = 0, carved = 0
                        let early = settings.carveFraction <= 0
                        for v in prepared {
                            guard let q = project(p, v) else { continue }
                            let u = Int(q.u.rounded(.down)), w = Int(q.v.rounded(.down))
                            guard u >= 0, w >= 0, u < v.w, w < v.h else { continue }
                            seen += 1
                            if v.mask[w * v.w + u] == 0 {
                                carved += 1
                                if early && carved > settings.carveTolerance { break }
                            }
                        }
                        let tolerance = max(settings.carveTolerance, Int(settings.carveFraction * Double(seen)))
                        base[grid.index(i, j, k)] = carved <= tolerance && seen >= settings.minSeenViews
                    }
                }
            }
        }
        out.occupied = occ
        return out
    }

    /// Height of the table plane (object frame y) estimated from the hull itself.
    ///
    /// Below the table, under the object, there is a wedge no photo can see (the object hides it), so the hull keeps it:
    /// a column at horizontal distance d from the footprint edge (along the direction to a camera at elevation e) stays
    /// filled down to d · tan(e) below the table, the smallest over all cameras. For each column of the footprint,
    /// table ≈ (lowest hull voxel) + that hidden depth; the median over the columns is the estimate. A few rounds refine
    /// the footprint (the hull's slice at the estimate). `cameraPositions` are in the object frame.
    /// Returns nil when the hull reaches the bottom of the grid (the wedge is cut off) or is empty.
    public static func estimateTable(grid: VoxelGrid, cameraPositions: [SIMD3<Double>], rounds: Int = 3) -> Double? {
        guard !cameraPositions.isEmpty, let ib = grid.indexBounds(), ib.min.y > 0 else { return nil }
        let nx = grid.nx, nz = grid.nz, s = grid.voxelSize
        var bottom = [Int](repeating: -1, count: nx * nz)  // lowest occupied j per column
        for k in 0..<nz { for i in 0..<nx {
            for j in 0..<grid.ny where grid.occupied[grid.index(i, j, k)] { bottom[k * nx + i] = j; break }
        } }
        func footprint(atY y: Double?) -> [Bool] {
            guard let y else { return bottom.map { $0 >= 0 } }
            let j = Int(((y - grid.origin.y) / s).rounded(.down))
            guard j >= 0, j < grid.ny else { return bottom.map { $0 >= 0 } }
            var f = [Bool](repeating: false, count: nx * nz)
            for k in 0..<nz { for i in 0..<nx { f[k * nx + i] = grid.occupied[grid.index(i, j, k)] } }
            return f.contains(true) ? f : bottom.map { $0 >= 0 }
        }
        var table: Double? = nil
        for _ in 0..<rounds {
            let f = footprint(atY: table)
            let planeY = table ?? grid.origin.y + Double(ib.min.y) * s
            var estimates: [Double] = []
            for k in 0..<nz { for i in 0..<nx where f[k * nx + i] && bottom[k * nx + i] >= 0 {
                let c = SIMD2(grid.origin.x + (Double(i) + 0.5) * s, grid.origin.z + (Double(k) + 0.5) * s)
                var hidden = Double.infinity
                for cam in cameraPositions {
                    var dir = SIMD2(cam.x, cam.z) - c
                    let horizontal = simd_length(dir)
                    guard horizontal > 1e-6, cam.y > planeY else { continue }
                    dir /= horizontal
                    // march to the footprint edge
                    var d = 0.0
                    while true {
                        let p = c + dir * (d + s / 2)
                        let ii = Int(((p.x - grid.origin.x) / s).rounded(.down)), kk = Int(((p.y - grid.origin.z) / s).rounded(.down))
                        if ii < 0 || kk < 0 || ii >= nx || kk >= nz || !f[kk * nx + ii] { break }
                        d += s / 2
                    }
                    hidden = min(hidden, d * (cam.y - planeY) / horizontal)
                }
                guard hidden.isFinite else { continue }
                estimates.append(grid.origin.y + Double(bottom[k * nx + i]) * s + hidden)
            } }
            guard let m = estimates.middle else { return table }
            table = m
        }
        return table
    }

    /// How much higher than the object the hull's top can be when the top is flat: the photos look down, so a point just
    /// above a flat top hides behind the top in every photo. For each camera, (half the footprint's extent along the
    /// direction to the camera) · tan(its elevation seen from the top); the smallest over the cameras. Domed tops come
    /// out lower than this. `cameraPositions` in the grid's frame.
    public static func flatTopBias(grid: VoxelGrid, cameraPositions: [SIMD3<Double>]) -> Double? {
        guard let b = grid.bounds() else { return nil }
        var pts: [SIMD2<Double>] = []
        for k in 0..<grid.nz { for i in 0..<grid.nx where (0..<grid.ny).contains(where: { grid.occupied[grid.index(i, $0, k)] }) {
            let c = grid.center(i, 0, k)
            pts.append(SIMD2(c.x, c.z))
        } }
        guard !pts.isEmpty else { return nil }
        let hull = Polygon.convexHull(pts)
        let mid = SIMD2((b.min.x + b.max.x) / 2, (b.min.z + b.max.z) / 2)
        var best = Double.infinity
        for cam in cameraPositions {
            var dir = SIMD2(cam.x, cam.z) - mid
            let horizontal = simd_length(dir)
            guard horizontal > 1e-6, cam.y > b.max.y else { continue }
            dir /= horizontal
            let proj = (hull.isEmpty ? pts : hull).map { simd_dot($0, dir) }
            let half = (proj.max()! - proj.min()!) / 2 + grid.voxelSize / 2
            best = min(best, half * (cam.y - b.max.y) / horizontal)
        }
        return best.isFinite ? best : nil
    }

    /// Removes the voxels whose centre is below `y`.
    public static func clip(_ grid: VoxelGrid, belowY y: Double) -> VoxelGrid {
        var g = grid
        for j in 0..<grid.ny where grid.origin.y + (Double(j) + 0.5) * grid.voxelSize < y {
            for k in 0..<grid.nz { for i in 0..<grid.nx { g.occupied[g.index(i, j, k)] = false } }
        }
        return g
    }

    /// How far each view's mask reaches beyond the hull's projection: the mean absolute gap of the four bounding-box
    /// edges, in mask pixels and in metres at the object (gap · depth / f). Large values mean the silhouettes do not
    /// agree (pose drift, a mask that includes or misses something).
    public struct ViewSlack: Codable, Equatable, Sendable {
        public var id: String
        public var slackPx: Double
        public var slackM: Double
    }

    public static func slack(grid: VoxelGrid, views: [HullView], objectToWorld: simd_double4x4) -> [ViewSlack] {
        var centers: [SIMD4<Double>] = []
        for k in 0..<grid.nz { for j in 0..<grid.ny { for i in 0..<grid.nx where grid.occupied[grid.index(i, j, k)] {
            centers.append(SIMD4(grid.center(i, j, k), 1))
        } } }
        guard !centers.isEmpty else { return [] }
        return views.compactMap { view in
            let v = prepare(view, objectToWorld: objectToWorld, dilation: 0)
            guard let maskBox = view.mask.boundingBox(threshold: 1) else { return nil }
            var minU = Double.infinity, minV = Double.infinity, maxU = -Double.infinity, maxV = -Double.infinity
            var depthSum = 0.0, n = 0.0
            for p in centers {
                guard let q = project(p, v) else { continue }
                let r = grid.voxelSize / 2 * v.fx / q.depth
                minU = min(minU, q.u - r); maxU = max(maxU, q.u + r)
                minV = min(minV, q.v - r); maxV = max(maxV, q.v + r)
                depthSum += q.depth; n += 1
            }
            guard n > 0 else { return nil }
            // Only edges inside the image say something (a mask cut by the image border is not slack).
            var gaps: [Double] = []
            if maskBox.minX > 0 { gaps.append(abs(maskBox.minX - minU)) }
            if maskBox.maxX < Double(v.w) { gaps.append(abs(maskBox.maxX - maxU)) }
            if maskBox.minY > 0 { gaps.append(abs(maskBox.minY - minV)) }
            if maskBox.maxY < Double(v.h) { gaps.append(abs(maskBox.maxY - maxV)) }
            guard !gaps.isEmpty else { return nil }
            let px = gaps.reduce(0, +) / Double(gaps.count)
            return ViewSlack(id: view.id, slackPx: px, slackM: px * (depthSum / n) / v.fx)
        }
    }

    /// Smallest-area rectangle around the occupied columns seen from above (1° steps).
    /// `longAxisAzimuthDeg` uses the azimuth convention: 0 = front–back (along Z), 90 = left–right (along X).
    public struct Footprint: Codable, Equatable, Sendable {
        public var lengthM: Double
        public var widthM: Double
        public var longAxisAzimuthDeg: Double
    }

    public static func footprint(grid: VoxelGrid) -> Footprint? {
        var pts: [SIMD2<Double>] = []
        for k in 0..<grid.nz { for i in 0..<grid.nx {
            if (0..<grid.ny).contains(where: { grid.occupied[grid.index(i, $0, k)] }) {
                let c = grid.center(i, 0, k)
                pts.append(SIMD2(c.x, c.z))
            }
        } }
        guard !pts.isEmpty else { return nil }
        let hull = Polygon.convexHull(pts)
        var best: (area: Double, a: Double, b: Double, deg: Double)?
        for step in 0..<180 {
            let t = Double(step) * .pi / 180
            let d = SIMD2(cos(t), sin(t)), e = SIMD2(-sin(t), cos(t))
            let pa = hull.map { simd_dot($0, d) }, pb = hull.map { simd_dot($0, e) }
            let a = pa.max()! - pa.min()! + grid.voxelSize, b = pb.max()! - pb.min()! + grid.voxelSize
            if best == nil || a * b < best!.area - 1e-12 { best = (a * b, a, b, Double(step)) }
        }
        guard let best else { return nil }
        // axis d = (cos t, sin t) in (x, z); its azimuth atan2(x, z).
        let longIsD = best.a >= best.b
        let t = best.deg * .pi / 180
        let axis = longIsD ? SIMD2(cos(t), sin(t)) : SIMD2(-sin(t), cos(t))
        var az = Geometry.degrees(atan2(axis.x, axis.y))
        az = Geometry.normalizeDegrees(az).rounded()
        if az >= 180 { az -= 180 }
        return Footprint(lengthM: max(best.a, best.b), widthM: min(best.a, best.b), longAxisAzimuthDeg: az == 0 ? 0 : az)
    }

    /// Exposed voxel faces as a Wavefront OBJ (object frame, metres, Y up), with shared vertices.
    public static func obj(grid: VoxelGrid, header: [String]) -> (text: String, vertices: Int, faces: Int) {
        var vertexIndex: [SIMD3<Int>: Int] = [:]
        var vertexLines: [String] = []
        var faceLines: [String] = []
        func vertex(_ p: SIMD3<Int>) -> Int {
            if let i = vertexIndex[p] { return i }
            let c = grid.origin + SIMD3(Double(p.x), Double(p.y), Double(p.z)) * grid.voxelSize
            vertexLines.append(String(format: "v %.4f %.4f %.4f", c.x, c.y, c.z))
            vertexIndex[p] = vertexLines.count
            return vertexLines.count
        }
        let axes = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
        for k in 0..<grid.nz { for j in 0..<grid.ny { for i in 0..<grid.nx where grid.occupied[grid.index(i, j, k)] {
            let cell = SIMD3(i, j, k)
            for a in 0..<3 {
                let ea = axes[a], eb = axes[(a + 1) % 3], ec = axes[(a + 2) % 3]
                for positive in [true, false] {
                    let n = positive ? cell &+ ea : cell &- ea
                    if grid.isOccupied(n.x, n.y, n.z) { continue }
                    let v0 = positive ? cell &+ ea : cell
                    var quad = [v0, v0 &+ eb, v0 &+ eb &+ ec, v0 &+ ec].map(vertex)
                    if !positive { quad.reverse() }  // counter-clockwise seen from outside
                    faceLines.append("f \(quad[0]) \(quad[1]) \(quad[2]) \(quad[3])")
                }
            }
        } } }
        let text = (header.map { "# " + $0 } + vertexLines + faceLines).joined(separator: "\n") + "\n"
        return (text, vertexLines.count, faceLines.count)
    }
}
