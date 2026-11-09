import ARKit
import CaptureCore
import SceneKit
import UIKit

/// AR の画面に重ねる 3D の印（基準の輪・作品を囲む円柱・撮る方向の印）。
/// ARSCNView の描画にだけ出る。captureHighResolutionFrame の写真（カメラの生の画像）には入らない。
@MainActor
final class SceneOverlay {
    let root = SCNNode()
    private let reticle = SCNNode()
    private let reticleRing = SCNNode()
    private let reticleDot = SCNNode()
    /// 照準のまわりの薄い円盤（推定した机の高さ・iPhone の下端で測った高さのとき。机に載って見えるかで高さを確かめる）。
    private let reticleDisc = SCNNode()
    private var reticleStyle: ReticleStyle?
    private let objectNode = SCNNode()
    private let baseRing = SCNNode()
    private let cylinder = SCNNode()
    private let markers = SCNNode()
    private var markerNodes: [String: SCNNode] = [:]
    /// 見つかった水平の平面（底の中心を探している間だけ出す）。
    private let planes = SCNNode()
    private var planeNodes: [UUID: SCNNode] = [:]
    private let planeMaterials = SceneOverlay.planeMaterials(.white)
    private let activePlaneMaterials = SceneOverlay.planeMaterials(.systemYellow)

    static let coveredColor = UIColor.systemGreen
    static let checkingColor = UIColor.systemYellow
    static let retakeColor = UIColor.systemOrange
    static let nextColor = UIColor.systemCyan
    static let pendingColor = UIColor.white

    /// 照準の見た目（求め方ごとに色を変える）。
    enum ReticleStyle: Equatable {
        /// ARKit の平面（黄色）。
        case plane
        /// 特徴点から推定した机の高さ（水色。信頼度が低いほど薄く）。
        case estimatedHeight(confidence: Double)
        /// iPhone の下端で測った机の高さ（紫）。
        case deviceEdge

        static let estimatedColor = UIColor.systemCyan
        static let deviceEdgeColor = UIColor.systemPurple
    }

    init() {
        reticleRing.geometry = SCNTube(innerRadius: 0.035, outerRadius: 0.042, height: 0.001)
        reticleRing.geometry?.firstMaterial = Self.material(.systemYellow)
        reticleDot.geometry = SCNCylinder(radius: 0.004, height: 0.001)
        reticleDot.geometry?.firstMaterial = Self.material(.systemYellow)
        let disc = SCNCylinder(radius: 0.09, height: 0.0005)
        disc.radialSegmentCount = 48
        reticleDisc.geometry = disc
        reticleDisc.geometry?.firstMaterial = Self.material(UIColor.systemCyan.withAlphaComponent(0.18), writesDepth: false)
        reticleDisc.renderingOrder = -5
        reticleDisc.isHidden = true
        reticle.addChildNode(reticleDisc)
        reticle.addChildNode(reticleRing)
        reticle.addChildNode(reticleDot)
        reticle.isHidden = true

        baseRing.geometry = SCNTube(innerRadius: 0.077, outerRadius: 0.083, height: 0.002)
        baseRing.geometry?.firstMaterial = Self.material(.systemOrange)
        cylinder.geometry = SCNCylinder(radius: 0.08, height: 0.15)
        cylinder.geometry?.firstMaterial = Self.material(UIColor.systemOrange.withAlphaComponent(0.22), writesDepth: false)
        objectNode.addChildNode(baseRing)
        objectNode.addChildNode(cylinder)
        objectNode.isHidden = true
        markers.isHidden = true

        root.addChildNode(planes)
        root.addChildNode(reticle)
        root.addChildNode(objectNode)
        root.addChildNode(markers)
    }

    func attach(to view: ARSCNView) {
        view.scene.rootNode.addChildNode(root)
    }

    private static func material(_ color: UIColor, writesDepth: Bool = true) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.writesToDepthBuffer = writesDepth
        m.blendMode = .alpha
        return m
    }

    /// 平面に当たった位置に照準を出す（nil なら隠す）。
    func showReticle(at transform: simd_float4x4?, style: ReticleStyle = .plane) {
        guard let transform else {
            reticle.isHidden = true
            return
        }
        if style != reticleStyle {
            reticleStyle = style
            let color: UIColor
            switch style {
            case .plane: color = .systemYellow
            case .estimatedHeight(let confidence):
                color = ReticleStyle.estimatedColor.withAlphaComponent(CGFloat(0.55 + 0.45 * min(1, max(0, confidence))))
            case .deviceEdge: color = ReticleStyle.deviceEdgeColor
            }
            reticleRing.geometry?.firstMaterial?.diffuse.contents = color
            reticleDot.geometry?.firstMaterial?.diffuse.contents = color
            reticleDisc.geometry?.firstMaterial?.diffuse.contents = color.withAlphaComponent(0.18)
            reticleDisc.isHidden = style == .plane
        }
        reticle.simdTransform = transform
        reticle.isHidden = false
    }

    /// 基準点に輪と円柱を出す（nil なら隠す）。
    func showObject(base: SIMD3<Double>?, radiusM: Double, heightM: Double) {
        guard let base else {
            objectNode.isHidden = true
            return
        }
        objectNode.simdPosition = SIMD3(Float(base.x), Float(base.y), Float(base.z))
        if let tube = baseRing.geometry as? SCNTube {
            tube.innerRadius = CGFloat(max(0.005, radiusM - 0.003))
            tube.outerRadius = CGFloat(radiusM + 0.003)
        }
        if let cyl = cylinder.geometry as? SCNCylinder {
            cyl.radius = CGFloat(radiusM)
            cyl.height = CGFloat(heightM)
        }
        cylinder.simdPosition = SIMD3(0, Float(heightM / 2), 0)
        objectNode.isHidden = false
    }

    /// 撮る方向の印。正面が決まるまでは出さない。
    /// 色：そろった＝緑、確認中＝黄、撮り直し＝オレンジ、次に撮る方向＝水色（大きく）、未撮影＝白。
    /// 段が 2 つ以上あるときは、今の段（`activeBandElevation`）の印だけをふつうに出し、ほかの段は撮った・撮り直しの印だけを
    /// 小さく薄く出す（48 方向をすべて出すと見づらく、描く数も増えるため）。方向の多い一覧では印を小さくする。
    func showMarkers(
        plan: DirectionPlan, objectToWorld: simd_double4x4?, heightM: Double, radiusM: Double,
        states: [String: TargetState], nextId: String?, activeBandElevation: Double?
    ) {
        guard let objectToWorld else {
            markers.isHidden = true
            return
        }
        let wanted = Set(plan.targets.map(\.id))
        for (id, node) in markerNodes where !wanted.contains(id) {
            node.removeFromParentNode()
            markerNodes[id] = nil
        }
        let center = SIMD3(0, heightM / 2, 0)
        let distance = radiusM + 0.1
        let baseScale: Float = plan.isDense ? 0.6 : 1
        for target in plan.targets {
            let state = states[target.id] ?? .notShot
            let inActiveBand = activeBandElevation.map { abs($0 - target.elevationDeg) < 0.5 } ?? true
            let node = markerNodes[target.id] ?? {
                let sphere = SCNSphere(radius: 0.012)
                sphere.segmentCount = 12
                let n = SCNNode(geometry: sphere)
                n.geometry?.firstMaterial = Self.material(Self.pendingColor)
                markers.addChildNode(n)
                markerNodes[target.id] = n
                return n
            }()
            // ほかの段の未撮影の印は出さない。
            guard inActiveBand || state != .notShot else {
                node.isHidden = true
                continue
            }
            node.isHidden = false
            let az = Geometry.radians(target.azimuthDeg), el = Geometry.radians(target.elevationDeg)
            let local = center + distance * SIMD3(sin(az) * cos(el), sin(el), cos(az) * cos(el))
            let world = objectToWorld * SIMD4(local, 1)
            node.simdPosition = SIMD3(Float(world.x), Float(world.y), Float(world.z))
            let color: UIColor
            switch state {
            case .done: color = Self.coveredColor
            case .checking: color = Self.checkingColor
            case .retake: color = Self.retakeColor
            case .notShot: color = target.id == nextId ? Self.nextColor : Self.pendingColor
            }
            node.geometry?.firstMaterial?.diffuse.contents = inActiveBand ? color : color.withAlphaComponent(0.35)
            let scale = baseScale * (target.id == nextId ? 1.5 : (inActiveBand ? 1 : 0.6))
            node.simdScale = SIMD3(repeating: scale)
        }
        markers.isHidden = false
    }

    func hideObject() {
        objectNode.isHidden = true
        markers.isHidden = true
    }

    // MARK: 見つかった平面

    /// 見つかった水平の平面に、薄い格子と縁を出す。照準が当たっている平面（`highlightedId`）は黄色にする。
    /// 形は `refreshGeometry` のときだけ作り直す（毎回作ると重いため）。無くなった平面の印は消す。
    func showPlanes(_ anchors: [ARPlaneAnchor], highlightedId: UUID?, refreshGeometry: Bool) {
        let ids = Set(anchors.map(\.identifier))
        for (id, node) in planeNodes where !ids.contains(id) {
            node.removeFromParentNode()
            planeNodes[id] = nil
        }
        for anchor in anchors {
            let node: SCNNode
            if let existing = planeNodes[anchor.identifier] {
                node = existing
                if refreshGeometry { node.geometry = Self.planeGeometry(anchor.geometry) }
            } else {
                node = SCNNode(geometry: Self.planeGeometry(anchor.geometry))
                // 照準より先に描き、深度は書かない（照準と同じ高さでちらつかないように）。
                node.renderingOrder = -10
                planes.addChildNode(node)
                planeNodes[anchor.identifier] = node
            }
            node.simdTransform = anchor.transform
            node.geometry?.materials = anchor.identifier == highlightedId ? activePlaneMaterials : planeMaterials
        }
    }

    func hidePlanes() {
        for node in planeNodes.values { node.removeFromParentNode() }
        planeNodes = [:]
    }

    /// 格子の間隔（m）。
    private static let gridSpacing: Float = 0.1

    /// 平面の形（アンカーの座標）。面（格子）と縁の線の 2 つ。
    private static func planeGeometry(_ plane: ARPlaneGeometry) -> SCNGeometry {
        let points = plane.vertices + plane.boundaryVertices
        let vertices = SCNGeometrySource(vertices: points.map { SCNVector3($0) })
        let uv = SCNGeometrySource(textureCoordinates: points.map {
            CGPoint(x: CGFloat($0.x / gridSpacing), y: CGFloat($0.z / gridSpacing))
        })
        let fill = SCNGeometryElement(indices: plane.triangleIndices.map { Int32($0) }, primitiveType: .triangles)
        let offset = Int32(plane.vertices.count), count = Int32(plane.boundaryVertices.count)
        var lineIndices: [Int32] = []
        if count >= 2 {
            for i in 0..<count { lineIndices += [offset + i, offset + (i + 1) % count] }
        }
        let outline = SCNGeometryElement(indices: lineIndices, primitiveType: .line)
        return SCNGeometry(sources: [vertices, uv], elements: [fill, outline])
    }

    /// 面（格子）と縁の材質。
    private static func planeMaterials(_ color: UIColor) -> [SCNMaterial] {
        let size = CGSize(width: 64, height: 64)
        let grid = UIGraphicsImageRenderer(size: size).image { context in
            color.withAlphaComponent(0.08).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            color.withAlphaComponent(0.45).setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: 2))
            context.fill(CGRect(x: 0, y: 0, width: 2, height: size.height))
        }
        let fill = material(.white, writesDepth: false)
        fill.diffuse.contents = grid
        fill.diffuse.wrapS = .repeat
        fill.diffuse.wrapT = .repeat
        fill.diffuse.mipFilter = .linear
        let outline = material(color.withAlphaComponent(0.8), writesDepth: false)
        return [fill, outline]
    }
}
