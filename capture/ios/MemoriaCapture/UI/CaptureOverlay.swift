import CaptureCore
import SwiftUI

/// AR の画面の上に重ねる案内（SwiftUI。保存する写真には入らない）。
struct CaptureOverlay: View {
    @ObservedObject var controller: CaptureController
    let onReview: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if let banner = controller.banner {
                BannerView(message: banner.message, isError: banner.isError)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if controller.phase == .capturing {
                topPanel
            }
            if controller.isComplete {
                completePanel
            }
            guidance
            Spacer(minLength: 0)
            if controller.phase == .capturing {
                StatusChips(assessment: controller.assessment)
            }
            bottomPanel
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.2), value: controller.banner)
    }

    // MARK: 上：方向の地図・進み具合

    private var topPanel: some View {
        HStack(alignment: .center, spacing: 12) {
            DirectionMiniMap(
                plan: controller.plan, progress: controller.progress,
                nextId: controller.direction?.nextTarget?.id,
                activeBandElevation: controller.direction?.nextTarget?.elevationDeg,
                currentAzimuth: controller.direction?.azimuthDeg,
                hasFront: controller.referenceState == .ready
            )
            .frame(width: 104, height: 104)
            VStack(alignment: .leading, spacing: 5) {
                Text("\(controller.progress.doneCount) / \(controller.plan.targets.count)")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(controller.referenceState == .ready ? "そろった方向" : "まず正面から 1 枚")
                    .font(.caption).foregroundStyle(.secondary)
                BandProgressLine(bands: controller.progress.bands, activeElevation: controller.direction?.nextTarget?.elevationDeg)
                progressDetail
                ElevationIndicator(
                    current: controller.direction?.elevationDeg,
                    target: (controller.direction?.frontTarget ?? controller.direction?.nextTarget)?.elevationDeg
                )
                if let notice = controller.maskBacklogNotice {
                    Label(notice, systemImage: "hourglass")
                        .font(.caption.bold()).foregroundStyle(.yellow)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    /// 確認中・撮り直しの数。
    @ViewBuilder
    private var progressDetail: some View {
        let checking = controller.progress.checkingIds.count, retake = controller.progress.retakeIds.count
        if checking > 0 || retake > 0 {
            HStack(spacing: 8) {
                if checking > 0 { Text("確認中 \(checking)").foregroundStyle(.yellow) }
                if retake > 0 { Text("撮り直し \(retake)").foregroundStyle(.orange) }
            }
            .font(.caption.bold())
        }
    }

    /// すべての方向がそろったとき。
    private var completePanel: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(.green)
            Text("そろいました（\(controller.progress.doneCount)/\(controller.progress.totalCount)）— 確認して送信できます")
                .font(.subheadline.bold())
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("確認へ", action: onReview)
                .buttonStyle(.borderedProminent)
                .disabled(controller.captureInFlight)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var guidance: some View {
        VStack(spacing: 6) {
            Text(controller.guidanceText)
                .font(.headline)
            if let tip = controller.guidanceTip {
                Label(tip, systemImage: "lightbulb.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.white)
    }

    // MARK: 下：操作

    @ViewBuilder
    private var bottomPanel: some View {
        switch controller.phase {
        case .starting:
            ProgressView().padding()
        case .unsupported:
            EmptyView()
        case .failed:
            Button("もう一度試す") { controller.retryAfterFailure() }
                .buttonStyle(.borderedProminent)
        case .placingBase:
            VStack(spacing: 10) {
                if let method = controller.methodText {
                    MethodLabel(text: method, source: controller.reticleSource)
                }
                if controller.showFallbacks {
                    fallbackPanel
                }
                Button {
                    controller.confirmBasePoint()
                } label: {
                    Label("ここが底の中心", systemImage: "scope").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!controller.hasPlaneHit)
                HStack {
                    fallbackMenu
                    Spacer(minLength: 0)
                }
                shutterRow(compact: true)
            }
        case .measuringEdge:
            edgePanel
        case .adjustingSize:
            VStack(spacing: 10) {
                SizeSlider(title: "高さ", value: $controller.heightCm, range: CaptureController.heightRangeCm)
                SizeSlider(title: "半径", value: $controller.radiusCm, range: CaptureController.radiusRangeCm)
                HeightNudgeRow(controller: controller)
                if let method = controller.methodText {
                    Text(method).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("位置を合わせ直す") { controller.reaimBase() }
                        .buttonStyle(.bordered)
                    Button {
                        controller.confirmReference()
                    } label: {
                        Text("基準を確定").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        case .capturing:
            shutterRow(compact: false)
        }
    }

    /// 照準が当たらないまま時間がたったとき：机の高さの推定の様子と、iPhone の下端で測る方法。
    private var fallbackPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("机の高さを推定中…").font(.subheadline.bold())
                Spacer()
                Text("\(Int((controller.surfaceProgress * 100).rounded()))%").font(.caption.monospacedDigit())
            }
            ProgressView(value: controller.surfaceProgress).tint(.cyan)
            Button {
                controller.beginEdgeMeasurement()
            } label: {
                Label("iPhone の下端を机に当てて測る", systemImage: "iphone.gen3").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.purple)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    /// いつでも選べる代わりの方法。
    private var fallbackMenu: some View {
        Menu {
            Button {
                controller.beginEdgeMeasurement()
            } label: {
                Label("iPhone の下端を机に当てて測る", systemImage: "iphone.gen3")
            }
            if controller.hasPinnedHeight {
                Button {
                    controller.clearPinnedHeight()
                } label: {
                    Label("測った高さをやめて自動に戻す", systemImage: "arrow.uturn.backward")
                }
            }
            Button {
                controller.restartSurfaceEstimate()
            } label: {
                Label("机の高さを推定し直す", systemImage: "arrow.clockwise")
            }
        } label: {
            Label("平面が見つからないとき", systemImage: "questionmark.circle")
                .font(.subheadline)
        }
        .buttonStyle(.bordered)
    }

    /// iPhone の下端を机に当てて測っている間。
    private var edgePanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 34))
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 6) {
                    Text(edgeStatusText).font(.subheadline.bold())
                    ProgressView(value: controller.edgeLowered ? controller.edgeStillProgress : 0).tint(.purple)
                }
            }
            HStack {
                Button("やめる") { controller.cancelEdgeMeasurement() }
                    .buttonStyle(.bordered)
                Button {
                    controller.measureEdgeNow()
                } label: {
                    Text("測る").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.purple)
                .disabled(!controller.canMeasureEdgeNow)
            }
            .controlSize(.large)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var edgeStatusText: String {
        switch controller.edgeStatus {
        case .tracking: return "位置を確かめています"
        case .notUpright: return "iPhone を縦に立ててください"
        case .holding: return controller.edgeLowered ? "そのまま 1 秒…" : "机に当てたら「測る」"
        }
    }

    private func shutterRow(compact: Bool) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 8) {
                if controller.phase == .capturing {
                    Toggle(isOn: $controller.autoCaptureEnabled) {
                        Text("自動撮影").font(.subheadline.bold())
                    }
                    .toggleStyle(.switch)
                    .fixedSize()
                    Button("基準をやり直す") { controller.resetReference() }
                        .font(.subheadline)
                        .buttonStyle(.bordered)
                } else {
                    Text("先に基準を設定してください（基準なしだと方向が記録されません）")
                        .font(.caption).foregroundStyle(.white)
                }
            }
            Spacer()
            ShutterButton(
                progress: controller.assessment.stabilityProgress,
                busy: controller.captureInFlight,
                enabled: controller.assessment.canManualCapture && !controller.captureInFlight,
                size: compact ? 60 : 78
            ) {
                controller.shutterTapped()
            }
            Spacer()
            Button(action: onReview) {
                VStack(spacing: 2) {
                    Image(systemName: "photo.stack").font(.title2)
                    Text("\(controller.photoCount) 枚").font(.caption)
                }
                .frame(width: 72)
            }
            .buttonStyle(.bordered)
            .disabled(controller.captureInFlight)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct BannerView: View {
    let message: String
    let isError: Bool

    var body: some View {
        Label(message, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.subheadline.bold())
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isError ? Color.red.opacity(0.9) : Color.green.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(.white)
    }
}

/// 今使っている方法（照準の色と同じ印を付ける）。
struct MethodLabel: View {
    let text: String
    let source: BasePointSource?

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.55), in: Capsule())
    }

    private var icon: String {
        switch source {
        case .featurePoints?: return "sparkles"
        case .deviceEdge?: return "iphone.gen3"
        default: return "square.grid.3x3"
        }
    }

    private var color: Color {
        switch source {
        case .featurePoints?: return .cyan
        case .deviceEdge?: return .purple
        default: return .yellow
        }
    }
}

/// 底の高さを手で合わせる（▼▲ で 0.5 cm ずつ。押し続けると続けて動く）。
struct HeightNudgeRow: View {
    @ObservedObject var controller: CaptureController

    var body: some View {
        HStack {
            Text("底の高さ").frame(width: 72, alignment: .leading)
            Button {
                controller.nudgeHeight(steps: -1)
            } label: {
                Image(systemName: "arrowtriangle.down.fill").frame(width: 36, height: 24)
            }
            .buttonRepeatBehavior(.enabled)
            .buttonStyle(.bordered)
            .accessibilityLabel("底を下げる")
            Text(controller.heightOffsetText)
                .monospacedDigit()
                .frame(maxWidth: .infinity)
            Button {
                controller.nudgeHeight(steps: 1)
            } label: {
                Image(systemName: "arrowtriangle.up.fill").frame(width: 36, height: 24)
            }
            .buttonRepeatBehavior(.enabled)
            .buttonStyle(.bordered)
            .accessibilityLabel("底を上げる")
            Button("0") { controller.resetHeightOffset() }
                .buttonStyle(.bordered)
                .disabled(controller.heightOffsetCm == 0)
        }
        .font(.subheadline)
    }
}

struct SizeSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack {
            Text(title).frame(width: 40, alignment: .leading)
            Slider(value: $value, in: range, step: 0.5)
            Text(String(format: "%.1f cm", value)).monospacedDigit().frame(width: 72, alignment: .trailing)
        }
        .font(.subheadline)
    }
}

struct ShutterButton: View {
    let progress: Double
    let busy: Bool
    let enabled: Bool
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.9), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Circle().fill(enabled ? Color.white : Color.gray.opacity(0.6)).padding(8)
                if busy { ProgressView() }
            }
            .frame(width: size, height: size)
        }
        .disabled(!enabled)
        .accessibilityLabel("シャッター")
    }
}

/// 6 つの確認項目（トラッキング・収まり・方向・動き・暗さ・ブレ）。
struct StatusChips: View {
    let assessment: QualityAssessment

    var body: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(CheckKind.allCases, id: \.self) { kind in
                let check = assessment.check(kind)
                HStack(spacing: 4) {
                    Image(systemName: Self.icon(check.status))
                    Text(kind.label).lineLimit(1)
                }
                .font(.caption.bold())
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(Self.color(check.status).opacity(0.85), in: Capsule())
                .foregroundStyle(.white)
            }
        }
    }

    static func icon(_ status: CheckStatus) -> String {
        switch status {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .blocked: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    static func color(_ status: CheckStatus) -> Color {
        switch status {
        case .ok: return .green
        case .warning: return .orange
        case .blocked: return .red
        case .unknown: return .gray
        }
    }
}

/// 段ごとの進み具合（例：「20°: 18/24 · 45°: 0/16 · 70°: 0/8」）。今の段を明るく、ほかを薄く。段が 1 つなら出さない。
struct BandProgressLine: View {
    let bands: [BandProgress]
    let activeElevation: Double?

    var body: some View {
        if bands.count > 1 {
            bands.enumerated().reduce(Text("")) { text, item in
                let (i, band) = item
                let active = activeElevation.map { abs($0 - band.elevationDeg) < 0.5 } ?? false
                let part = Text(band.text)
                    .fontWeight(active ? .bold : .regular)
                    .foregroundColor(band.isComplete ? .green : (active ? .primary : .secondary))
                return i == 0 ? part : text + Text(" · ").foregroundColor(.secondary) + part
            }
            .font(.caption.monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
    }
}

/// 上から見た撮影方向の地図（正面が下。そろった＝緑、確認中＝黄、撮り直し＝オレンジ、次＝水色、今のカメラ＝青）。
/// 段（仰角）ごとに同心の輪（低い段が外側）。今の段（次に撮る方向の段）の点を大きく、ほかの段は小さく薄く描く。
/// 48 方向でも軽いように Canvas で描く（点ごとに View を作らない）。
struct DirectionMiniMap: View {
    let plan: DirectionPlan
    let progress: CoverageProgress
    let nextId: String?
    var activeBandElevation: Double?
    let currentAzimuth: Double?
    let hasFront: Bool

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let radius = side / 2 - 10
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let bands = plan.bands
            let states = Dictionary(uniqueKeysWithValues: progress.targets.map { ($0.target.id, $0.state) })
            for (i, band) in bands.enumerated() {
                let r = ringRadius(index: i, count: bands.count, radius: radius)
                let active = isActive(band.elevationDeg)
                context.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                               with: .color(.white.opacity(active ? 0.6 : 0.25)), lineWidth: active ? 2 : 1)
            }
            var cube = context.resolve(Image(systemName: "cube.fill"))
            cube.shading = .color(.white.opacity(0.8))
            context.draw(cube, at: center)
            guard hasFront else {
                context.draw(Text("正面").font(.caption2.bold()).foregroundColor(.orange), at: CGPoint(x: center.x, y: center.y + radius - 2))
                return
            }
            for (i, band) in bands.enumerated() {
                let r = ringRadius(index: i, count: bands.count, radius: radius)
                let active = isActive(band.elevationDeg)
                // 点の大きさ：輪の長さを点の数で割った間隔の 7 割（10 まで）。
                let spacing = 2 * .pi * r / CGFloat(max(1, band.targets.count))
                let dot = min(10, max(4, spacing * 0.7)) * (active ? 1 : 0.7)
                for target in band.targets {
                    let state = states[target.id] ?? .notShot
                    let isNext = target.id == nextId
                    let p = point(azimuth: target.azimuthDeg, radius: r, center: center)
                    let d = isNext ? dot + 4 : (state == .retake ? dot + 2 : dot)
                    let rect = CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)
                    let opacity: Double = active ? 1 : (state == .notShot ? 0.25 : 0.45)
                    context.fill(Path(ellipseIn: rect), with: .color(Self.color(state, isNext: isNext).opacity(opacity)))
                }
            }
            if let currentAzimuth {
                let p = point(azimuth: currentAzimuth, radius: radius + 6, center: center)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)), with: .color(.white))
                var camera = context.resolve(Image(systemName: "camera.fill"))
                camera.shading = .color(.blue)
                context.draw(camera, in: CGRect(x: p.x - 6, y: p.y - 5, width: 12, height: 10))
            }
        }
        .accessibilityLabel("撮影方向の地図（\(progress.doneCount) / \(progress.totalCount)）")
    }

    private func isActive(_ elevation: Double) -> Bool {
        activeBandElevation.map { abs($0 - elevation) < 0.5 } ?? true
    }

    /// 段の輪の半径（低い段が外側）。
    private func ringRadius(index: Int, count: Int, radius: CGFloat) -> CGFloat {
        count <= 1 ? radius : radius * (1 - 0.32 * CGFloat(index))
    }

    static func color(_ state: TargetState, isNext: Bool) -> Color {
        switch state {
        case .done: return .green
        case .checking: return .yellow
        case .retake: return .orange
        case .notShot: return isNext ? .cyan : .white
        }
    }

    private func point(azimuth: Double, radius: CGFloat, center: CGPoint) -> CGPoint {
        let a = Geometry.radians(azimuth)
        // 地図は上から見る：作品の +Z（正面）を画面の下、+X（正面から見て右）を画面の右に描く。
        return CGPoint(x: center.x + radius * CGFloat(sin(a)), y: center.y + radius * CGFloat(cos(a)))
    }
}

/// 仰角の表示（今の高さと、次に撮る高さ）。
struct ElevationIndicator: View {
    let current: Double?
    let target: Double?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.and.down")
            if let current {
                Text("高さ \(Int(current.rounded()))°").monospacedDigit()
            } else {
                Text("高さ —")
            }
            if let target {
                Text("（目標 \(Int(target.rounded()))°）").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}
