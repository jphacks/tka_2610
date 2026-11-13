import Foundation
import simd

// 向きで案内したセッションの、作品のおおよその大きさ。撮ったあとに、切り抜き（マスク）の外接長方形と、
// 求めた中心（HeadingDerivation）から測る。撮影中は大きさを知らない（円柱を合わせない）ので、撮ったあとにしか分からない。
// 切り抜きが使えなければ大きさは「分からない」（数字は入れない）。iPhone と Mac の memoria-pack の両方がこの計算を使う。
//
// 求め方（2 つの見方の間をとる。どちらも iPhone の写真と ARKit の姿勢だけから）：
// 1. 箱の当てはめ（下の目安 `lowerM`）：作品座標（原点は求めた中心、+Y 上、+Z 正面、+X 右）の軸にそろった箱を、
//    どの写真に投影してもその外接長方形が切り抜きの外接長方形に合うように決める（最小二乗。透視をそのまま扱う）。
//    角ばった物（箱）ではほぼ正しく、丸い物（粘土・マウス）では斜めから見た輪郭が箱より小さいので、小さく出る。
// 2. 中心の面での広がり（上の目安 `upperM`）：切り抜きの外接長方形の 4 隅を通る線を、中心を通り写真の向きに垂直な面に当てた
//    広がり（＝写真の中の長さを中心までの距離で実寸にしたもの）。幅は正面・後ろ、奥行きは右・左、高さは横の 4 枚の平均。
//    丸い物では近く、角ばった物では手前の面が大きく写る分と、見下ろして上の面が見える分だけ大きく出る。
// 大きさ（`widthM` など）は 2 つの幾何平均。2 つが大きく違う寸法は形しだいで当てにならないので、信頼度を低くする。
// 実物の白いマウス（6.4 × 12.5 × 4.0 cm）を前の方法で撮った写真では、箱 5.6 × 11.9 × 2.3、広がり 7.5 × 13.6 × 8.3、
// 幾何平均 6.5 × 12.7 × 4.4 cm だった（1 つの作品だけで決めた値）。
// 確かめ：向かい合う写真（正面と後ろ・右と左）で測った広がりがどれだけ違うか。

// MARK: - session.json の `referenceFrames[].heading.derivation.size`

public enum HeadingSizeReason: String, Codable, Sendable {
    /// 中心が分からない。
    case noCenter
    /// 使える切り抜きが足りない（正面か後ろ・右か左・ほかに 1 枚の、計 3 枚以上が要る）。
    case notEnoughMasks
    /// 切り抜きが写真の端に届いている（作品が写真からはみ出しているかもしれない）。
    case maskTouchesImageEdge
    /// 箱が切り抜きにうまく合わない（切り抜きの誤り・作品を十字に合わせていない写真・位置のずれ）。
    case poorFit
    /// 向かい合う写真で測った幅・奥行きが大きく違う。
    case oppositeViewsDisagree
    /// 中心の求め方の信頼度が低い。
    case centerLowConfidence
    /// 箱の当てはめと中心の面での広がりが大きく違う（作品の形しだいで大きさが変わる。見下ろす角度が大きいと高さに出やすい）。
    case shapeDependent
    /// 箱が求まらない。
    case fitFailed
}

/// 向かい合う写真で単純に測った長さ（写真の中心の距離で縮尺を合わせた、切り抜きの外接長方形の幅）。
public struct HeadingSizeCrossCheck: Codable, Equatable, Sendable {
    /// "width"（正面・後ろの横の長さ）| "depth"（右・左の横の長さ）| "height"（横の写真の縦の長さ）
    public var dimension: String
    /// 写真ごとの値（m）。名前は "front"・"right"・"back"・"left"。
    public var values: [String: Double]
    /// （最大 − 最小）÷ 平均。
    public var disagreement: Double

    public init(dimension: String, values: [String: Double], disagreement: Double) {
        self.dimension = dimension
        self.values = values
        self.disagreement = disagreement
    }
}

/// 幅・奥行き・高さ（m）。
public struct HeadingSize3: Codable, Equatable, Sendable {
    public var widthM: Double
    public var depthM: Double
    public var heightM: Double

    public init(widthM: Double, depthM: Double, heightM: Double) {
        self.widthM = widthM
        self.depthM = depthM
        self.heightM = heightM
    }
}

/// 切り抜きから求めたおおよその大きさ。
public struct HeadingSizeEstimate: Codable, Equatable, Sendable {
    public static let methodName = "maskBoundsBoxAndCenterPlane"

    /// `approximate`（求めた。おおよそ）| `unknown`（求められない。数字は null）。
    public var status: String
    /// `normal` | `low`（`reasons` を見る）。`unknown` のときは null。
    @NullCodable public var confidence: String?
    public var method: String
    public var reasons: [HeadingSizeReason]
    /// 幅（X、左右）・奥行き（Z、前後）・高さ（Y、上下）（m）。下の目安と上の目安の幾何平均。分からなければ null。
    @NullCodable public var widthM: Double?
    @NullCodable public var depthM: Double?
    @NullCodable public var heightM: Double?
    /// 下の目安（箱の当てはめ。角ばった物でほぼ正しく、丸い物で小さい）。分からなければ null。
    @NullCodable public var lowerM: HeadingSize3?
    /// 上の目安（中心の面での広がり。丸い物で近く、角ばった物で大きい）。分からなければ null。
    @NullCodable public var upperM: HeadingSize3?
    /// 大きさの箱の範囲（作品座標。原点は求めた中心 `centerWorld`、+Y 上、+Z 正面、+X 右。m）。当てはめた箱の中心に、
    /// 幅・奥行き・高さ（`widthM` など）の箱を置いたもの。分からなければ null。
    @NullCodable public var boxMinM: Vector3?
    @NullCodable public var boxMaxM: Vector3?
    /// 使った写真（切り抜きのある写真）。
    public var photoIds: [String]
    /// 箱の輪郭と切り抜きの外接長方形のずれの二乗平均（度。画面の角度）。
    @NullCodable public var fitResidualDeg: Double?
    public var crossChecks: [HeadingSizeCrossCheck]

    public init(status: String, confidence: String?, reasons: [HeadingSizeReason], widthM: Double?, depthM: Double?, heightM: Double?,
                lowerM: HeadingSize3? = nil, upperM: HeadingSize3? = nil,
                boxMinM: SIMD3<Double>?, boxMaxM: SIMD3<Double>?, photoIds: [String], fitResidualDeg: Double?, crossChecks: [HeadingSizeCrossCheck]) {
        self.status = status
        self.confidence = confidence
        method = Self.methodName
        self.reasons = reasons
        self.widthM = widthM
        self.depthM = depthM
        self.heightM = heightM
        self.lowerM = lowerM
        self.upperM = upperM
        self.boxMinM = boxMinM.map(Vector3.init)
        self.boxMaxM = boxMaxM.map(Vector3.init)
        self.photoIds = photoIds
        self.fitResidualDeg = fitResidualDeg
        self.crossChecks = crossChecks
    }

    public static func unknown(_ reasons: [HeadingSizeReason], photoIds: [String] = []) -> HeadingSizeEstimate {
        HeadingSizeEstimate(status: "unknown", confidence: nil, reasons: reasons, widthM: nil, depthM: nil, heightM: nil,
                            boxMinM: nil, boxMaxM: nil, photoIds: photoIds, fitResidualDeg: nil, crossChecks: [])
    }

    public var isKnown: Bool { status == "approximate" && widthM != nil && depthM != nil && heightM != nil }
}

// MARK: - 切り抜きの外接長方形

/// 切り抜き（マスク）の外接長方形と、写真の端に届いている辺。
public struct MaskBounds: Equatable, Sendable {
    /// 外接長方形（マスクの画像のピクセル）。
    public var box: PixelRect
    /// 左・右・上・下の辺が画像の端に届いているか。
    public var touches: [Bool]
    public var width: Int
    public var height: Int

    public init(box: PixelRect, touches: [Bool], width: Int, height: Int) {
        self.box = box
        self.touches = touches
        self.width = width
        self.height = height
    }

    /// 8 bit のマスク（1 行 `width` バイト、`threshold` 以上が作品）の外接長方形。ごく小さい飛び地に引っ張られないよう、
    /// 行・列ごとの作品のピクセル数が `minimumRun` 未満の行・列は数えない。作品が無ければ nil。
    public static func of(pixels: [UInt8], width: Int, height: Int, threshold: UInt8 = 128, minimumRun: Int = 2) -> MaskBounds? {
        guard width > 0, height > 0, pixels.count >= width * height else { return nil }
        var columns = [Int](repeating: 0, count: width)
        var rows = [Int](repeating: 0, count: height)
        pixels.withUnsafeBufferPointer { p in
            for y in 0..<height {
                let row = y * width
                var n = 0
                for x in 0..<width where p[row + x] >= threshold {
                    columns[x] += 1
                    n += 1
                }
                rows[y] = n
            }
        }
        guard let x0 = columns.firstIndex(where: { $0 >= minimumRun }), let x1 = columns.lastIndex(where: { $0 >= minimumRun }),
              let y0 = rows.firstIndex(where: { $0 >= minimumRun }), let y1 = rows.lastIndex(where: { $0 >= minimumRun }) else { return nil }
        let box = PixelRect(minX: Double(x0), minY: Double(y0), maxX: Double(x1 + 1), maxY: Double(y1 + 1))
        return MaskBounds(box: box, touches: [x0 == 0, x1 == width - 1, y0 == 0, y1 == height - 1], width: width, height: height)
    }

    /// 写真（`imageWidth × imageHeight`）のピクセルにした外接長方形。
    public func scaled(toImageWidth imageWidth: Int, imageHeight: Int) -> PixelRect {
        box.scaled(x: Double(imageWidth) / Double(max(1, width)), y: Double(imageHeight) / Double(max(1, height)))
    }
}

/// 大きさを求めるのに使う写真 1 枚。
public struct HeadingSizeView: Equatable, Sendable {
    public var photoId: String
    /// "front" | "right" | "back" | "left" | "top"（方向の名前）。分からなければ nil。
    public var role: String?
    /// カメラ（K は `imageWidth × imageHeight` の画像のもの）。
    public var camera: CameraModel
    /// 切り抜きの外接長方形（`camera` の画像のピクセル）。
    public var maskBox: PixelRect
    /// 左・右・上・下の辺が写真の端に届いているか（届いている辺は、作品がもっと大きいかもしれないので使わない）。
    public var touches: [Bool]

    public init(photoId: String, role: String?, camera: CameraModel, maskBox: PixelRect, touches: [Bool]) {
        self.photoId = photoId
        self.role = role
        self.camera = camera
        self.maskBox = maskBox
        self.touches = touches
    }

    /// 写真の記録とマスクの外接長方形から作る（K の画像の大きさに合わせる）。
    public init(photo: Photo, role: String?, bounds: MaskBounds) {
        let k = photo.camera.intrinsicsResolution
        let camera = CameraModel(cameraToWorld: photo.camera.cameraToWorld.simd, intrinsics: photo.camera.intrinsics.simd,
                                 imageWidth: Double(k.width), imageHeight: Double(k.height))
        self.init(photoId: photo.photoId, role: role, camera: camera, maskBox: bounds.scaled(toImageWidth: k.width, imageHeight: k.height), touches: bounds.touches)
    }
}

// MARK: - 求める

public enum HeadingSizer {
    /// 箱の輪郭と切り抜きのずれ（二乗平均、度）がこれより大きいと信頼度は低い。
    public static let maximumFitResidualDeg = 1.5
    /// 向かい合う写真の長さの違い（（最大 − 最小）÷ 平均）がこれより大きいと信頼度は低い。
    public static let maximumDisagreement = 0.25
    /// 上の目安が下の目安のこの倍より大きい寸法があると、信頼度は低い（形しだい）。
    public static let maximumBoundsRatio = 1.6

    /// 方向の名前（大きさの計算と確かめに使う）：正面・右・後ろ・左は "front"…、真上は "top"。
    public static func role(of target: DirectionTarget?) -> String? {
        guard let target else { return nil }
        if target.anyAzimuth { return "top" }
        for (deg, name) in [(0.0, "front"), (90, "right"), (180, "back"), (270, "left")] where Geometry.angleDistance(target.azimuthDeg, deg) < 0.5 {
            return name
        }
        return nil
    }

    /// 中心 `center`・正面の向き `frontHeadingDeg` の作品座標で、切り抜きに合う箱を求める。
    /// - Parameter centerConfident: 中心の求め方の信頼度が ok か（低ければ大きさの信頼度も低い）。
    public static func estimate(center: SIMD3<Double>, frontHeadingDeg: Double, views: [HeadingSizeView], centerConfident: Bool = true) -> HeadingSizeEstimate {
        let ids = views.map(\.photoId)
        let roles = Set(views.compactMap(\.role))
        let hasWidthView = roles.contains("front") || roles.contains("back")
        let hasDepthView = roles.contains("right") || roles.contains("left")
        guard views.count >= 3, hasWidthView, hasDepthView else { return .unknown([.notEnoughMasks], photoIds: ids) }

        let m = HeadingDeriver.objectToWorld(center: center, frontHeadingDeg: frontHeadingDeg, originY: center.y)
        let axes = (x: SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z), y: SIMD3<Double>(0, 1, 0), z: SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        func world(_ p: SIMD3<Double>) -> SIMD3<Double> { center + p.x * axes.x + p.y * axes.y + p.z * axes.z }

        // 残差：写真ごとに、箱の 8 隅を投影した外接長方形と、切り抜きの外接長方形の 4 辺の差（焦点距離で割った角度）。
        func residuals(_ q: [Double]) -> [Double]? {
            let lo = SIMD3(min(q[0], q[1]), min(q[2], q[3]), min(q[4], q[5]))
            let hi = SIMD3(max(q[0], q[1]), max(q[2], q[3]), max(q[4], q[5]))
            var r: [Double] = []
            for v in views {
                var xs: [Double] = [], ys: [Double] = []
                for i in 0..<8 {
                    let p = SIMD3(i & 1 == 0 ? lo.x : hi.x, i & 2 == 0 ? lo.y : hi.y, i & 4 == 0 ? lo.z : hi.z)
                    guard let px = v.camera.project(world(p)) else { return nil }
                    xs.append(px.x)
                    ys.append(px.y)
                }
                let fx = v.camera.intrinsics[0][0], fy = v.camera.intrinsics[1][1]
                let sides = [(xs.min()! - v.maskBox.minX) / fx, (xs.max()! - v.maskBox.maxX) / fx,
                             (ys.min()! - v.maskBox.minY) / fy, (ys.max()! - v.maskBox.maxY) / fy]
                for k in 0..<4 where !v.touches[k] { r.append(sides[k]) }
            }
            return r
        }

        // はじめの箱：単純に測った長さ（向かい合う写真の平均）の半分。
        let simple = simpleExtents(views: views, center: center, axes: axes)
        let hw = (simple.width ?? 0.08) / 2, hd = (simple.depth ?? 0.08) / 2, hh = (simple.height ?? 0.08) / 2
        var q = [-hw, hw, -hh, hh, -hd, hd]
        guard var r = residuals(q), r.count >= 6 else { return .unknown([.fitFailed], photoIds: ids) }
        var cost = r.map { $0 * $0 }.reduce(0, +)
        var lambda = 1e-3
        for _ in 0..<60 {
            // ヤコビアン（差分）。
            let h = 1e-5
            var jt = [[Double]](repeating: [], count: 6)
            var ok = true
            for k in 0..<6 {
                var qp = q
                qp[k] += h
                guard let rp = residuals(qp), rp.count == r.count else { ok = false; break }
                jt[k] = zip(rp, r).map { ($0 - $1) / h }
            }
            guard ok else { break }
            var a = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 6)
            var g = [Double](repeating: 0, count: 6)
            for i in 0..<6 {
                for j in 0..<6 { a[i][j] = zip(jt[i], jt[j]).map(*).reduce(0, +) }
                g[i] = -zip(jt[i], r).map(*).reduce(0, +)
            }
            var improved = false
            for _ in 0..<8 {
                var damped = a
                for i in 0..<6 { damped[i][i] += lambda * max(a[i][i], 1e-9) }
                guard let step = solveLinear(damped, g) else { lambda *= 10; continue }
                let candidate = zip(q, step).map(+)
                if let rc = residuals(candidate), rc.count == r.count {
                    let c = rc.map { $0 * $0 }.reduce(0, +)
                    if c < cost {
                        let moved = step.map(abs).max() ?? 0
                        q = candidate
                        r = rc
                        cost = c
                        lambda = max(lambda / 10, 1e-9)
                        improved = moved > 1e-7
                        break
                    }
                }
                lambda *= 10
            }
            if !improved { break }
        }
        let lo = SIMD3(min(q[0], q[1]), min(q[2], q[3]), min(q[4], q[5]))
        let hi = SIMD3(max(q[0], q[1]), max(q[2], q[3]), max(q[4], q[5]))
        let ext = hi - lo
        guard ext.x > 0.002, ext.y > 0.002, ext.z > 0.002, ext.x < 3, ext.y < 3, ext.z < 3 else {
            return .unknown([.fitFailed], photoIds: ids)
        }
        let fitDeg = Geometry.degrees((cost / Double(max(1, r.count))).squareRoot())
        // 上の目安：中心の面での広がり（無い寸法は箱のまま）。
        let upper = SIMD3(max(ext.x, simple.width ?? ext.x), max(ext.y, simple.height ?? ext.y), max(ext.z, simple.depth ?? ext.z))
        let central = SIMD3((ext.x * upper.x).squareRoot(), (ext.y * upper.y).squareRoot(), (ext.z * upper.z).squareRoot())
        let mid = (lo + hi) / 2

        var reasons: [HeadingSizeReason] = []
        if !centerConfident { reasons.append(.centerLowConfidence) }
        if fitDeg > maximumFitResidualDeg { reasons.append(.poorFit) }
        if views.contains(where: { $0.touches.contains(true) }) { reasons.append(.maskTouchesImageEdge) }
        if simple.checks.contains(where: { $0.dimension != "height" && $0.disagreement > maximumDisagreement }) { reasons.append(.oppositeViewsDisagree) }
        if upper.x > maximumBoundsRatio * ext.x || upper.y > maximumBoundsRatio * ext.y || upper.z > maximumBoundsRatio * ext.z {
            reasons.append(.shapeDependent)
        }
        func size3(_ v: SIMD3<Double>) -> HeadingSize3 { HeadingSize3(widthM: round4(v.x), depthM: round4(v.z), heightM: round4(v.y)) }
        let boxLo = mid - central / 2, boxHi = mid + central / 2
        return HeadingSizeEstimate(
            status: "approximate", confidence: reasons.isEmpty ? "normal" : "low", reasons: reasons,
            widthM: round4(central.x), depthM: round4(central.z), heightM: round4(central.y), lowerM: size3(ext), upperM: size3(upper),
            boxMinM: SIMD3(round4(boxLo.x), round4(boxLo.y), round4(boxLo.z)), boxMaxM: SIMD3(round4(boxHi.x), round4(boxHi.y), round4(boxHi.z)),
            photoIds: ids, fitResidualDeg: (fitDeg * 100).rounded() / 100, crossChecks: simple.checks
        )
    }

    /// 単純に測った長さ：切り抜きの外接長方形の 4 隅を通る線を、中心を通り写真の水平の向きに垂直な面に当て、
    /// その横（作品座標の X か Z）と縦（Y）の広がりを測る（画像の向き・回転によらない）。向かい合う写真で比べる。
    static func simpleExtents(views: [HeadingSizeView], center: SIMD3<Double>, axes: (x: SIMD3<Double>, y: SIMD3<Double>, z: SIMD3<Double>))
        -> (width: Double?, depth: Double?, height: Double?, checks: [HeadingSizeCrossCheck]) {
        var widths: [String: Double] = [:], depths: [String: Double] = [:], heights: [String: Double] = [:]
        for v in views {
            guard let role = v.role, role != "top" else { continue }
            let horizontalAxis = role == "front" || role == "back" ? axes.x : axes.z
            let normal = role == "front" || role == "back" ? axes.z : axes.x
            let size = PixelSize(width: Int(v.camera.imageWidth), height: Int(v.camera.imageHeight))
            let corners = [SIMD2(v.maskBox.minX, v.maskBox.minY), SIMD2(v.maskBox.maxX, v.maskBox.minY),
                           SIMD2(v.maskBox.maxX, v.maskBox.maxY), SIMD2(v.maskBox.minX, v.maskBox.maxY)]
            let hits = corners.compactMap { FlatGeometry.intersect(FlatGeometry.ray(throughPixel: $0, camera: v.camera, imageSize: size), planePoint: center, planeNormal: normal) }
            guard hits.count == 4 else { continue }
            let hs = hits.map { simd_dot($0 - center, horizontalAxis) }, vs = hits.map { $0.y - center.y }
            let h = hs.max()! - hs.min()!, vert = vs.max()! - vs.min()!
            if role == "front" || role == "back" { widths[role] = round4(h) } else { depths[role] = round4(h) }
            heights[role] = round4(vert)
        }
        func check(_ name: String, _ values: [String: Double]) -> HeadingSizeCrossCheck? {
            guard values.count >= 2 else { return nil }
            let mean = values.values.reduce(0, +) / Double(values.count)
            guard mean > 0 else { return nil }
            return HeadingSizeCrossCheck(dimension: name, values: values, disagreement: round4((values.values.max()! - values.values.min()!) / mean))
        }
        func mean(_ values: [String: Double]) -> Double? { values.isEmpty ? nil : values.values.reduce(0, +) / Double(values.count) }
        return (mean(widths), mean(depths), mean(heights), [check("width", widths), check("depth", depths), check("height", heights)].compactMap { $0 })
    }

    /// 小さな連立一次方程式（ガウスの消去法、部分ピボット）。解けなければ nil。
    static func solveLinear(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        var m = a
        var v = b
        for c in 0..<n {
            guard let p = (c..<n).max(by: { abs(m[$0][c]) < abs(m[$1][c]) }), abs(m[p][c]) > 1e-18 else { return nil }
            m.swapAt(c, p)
            v.swapAt(c, p)
            for r in (c + 1)..<n {
                let f = m[r][c] / m[c][c]
                if f == 0 { continue }
                for k in c..<n { m[r][k] -= f * m[c][k] }
                v[r] -= f * v[c]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = v[r]
            for k in (r + 1)..<n { s -= m[r][k] * x[k] }
            x[r] = s / m[r][r]
        }
        return x.allSatisfy(\.isFinite) ? x : nil
    }

    static func round4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
}

// MARK: - セッションから

extension HeadingSizer {
    /// 大きさに使える切り抜き：確認済み、または自動で作って確かめた結果が ok（`MaskUse` の good と同じ）。
    public static func maskIsUsable(_ photo: Photo) -> Bool {
        guard photo.mask.status.hasFile, photo.mask.file != nil else { return false }
        return photo.mask.status == .confirmed || photo.mask.check?.status == .ok
    }

    /// 切り抜きをまだ作っている・確かめていない（大きさはあとで求める）。
    public static func maskIsPending(_ photo: Photo) -> Bool {
        switch photo.mask.status {
        case .notGenerated, .processing: return true
        case .candidate: return photo.mask.check == nil
        case .confirmed, .failed, .noObject: return false
        }
    }

    /// 基準 `frameId` の大きさを、方向ごとの代表の写真の切り抜きから求める（iPhone と memoria-pack が同じ計算を使う）。
    /// 中心が分からなければ `unknown`。切り抜きをまだ作っている写真があれば nil（あとで求める）。
    /// - Parameter maskBounds: 写真のマスクの外接長方形（読めなければ nil）。
    public static func estimate(session: CaptureSession, frameId: String, maskBounds: (Photo) -> MaskBounds?) -> HeadingSizeEstimate? {
        guard let frame = session.referenceFrame(id: frameId), let heading = frame.heading, let front = heading.frontHeadingDeg,
              let derivation = heading.derivation else { return nil }
        guard let center = derivation.centerWorld?.simd else { return .unknown([.noCenter]) }
        let photos = HeadingDeriver.representativePhotos(session: session, frameId: frameId)
        if photos.contains(where: maskIsPending) { return nil }
        var views: [HeadingSizeView] = []
        for photo in photos where maskIsUsable(photo) {
            guard let bounds = maskBounds(photo) else { continue }
            views.append(HeadingSizeView(photo: photo, role: role(of: session.directionPlan.target(id: photo.direction.targetId)), bounds: bounds))
        }
        return estimate(center: center, frontHeadingDeg: front, views: views, centerConfident: derivation.status == .ok)
    }

    /// 基準ごとに、中心を求め直し（机の面は前に測ったもの）、大きさがまだ無い・使える切り抜きの写真が変わったら切り抜きから求める。
    /// 中身が変わったら true。撮影画面を閉じたあと（切り抜きができたとき・写真を消したとき）に呼ぶ。
    @discardableResult
    public static func refresh(session: inout CaptureSession, maskBounds: (Photo) -> MaskBounds?) -> Bool {
        var changed = false
        for frame in session.referenceFrames where frame.heading?.frontHeadingDeg != nil {
            if HeadingDeriver.update(session: &session, frameId: frame.id) { changed = true }
            guard let derivation = session.referenceFrame(id: frame.id)?.heading?.derivation else { continue }
            if let size = derivation.size {
                let usable = HeadingDeriver.representativePhotos(session: session, frameId: frame.id).filter(maskIsUsable).map(\.photoId)
                guard size.status == "unknown" && size.reasons == [.noCenter] || Set(size.photoIds) != Set(usable) else { continue }
            }
            guard let size = estimate(session: session, frameId: frame.id, maskBounds: maskBounds) else { continue }
            if HeadingDeriver.setSize(size, session: &session, frameId: frame.id, forCenter: derivation.centerWorld) { changed = true }
        }
        return changed
    }
}
