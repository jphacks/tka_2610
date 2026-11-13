import ARKit
import CaptureCore
import SwiftUI

/// ARSCNView を SwiftUI に置く（向きで案内する撮影）。
struct HeadingARViewContainer: UIViewRepresentable {
    let controller: HeadingCaptureController

    func makeUIView(context: Context) -> ARSCNView { controller.arView }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

/// 向きで案内する立体の作品の撮影画面：画面の中央の十字・回る向きと残りの角度・高さ・シャッター。
/// 底の中心・円柱の設定は無い。作品が十字にあるかは撮る人が合わせる。
struct HeadingCaptureView: View {
    @StateObject private var controller: HeadingCaptureController
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init(sessionId: String, preferredTargetId: String?, model: AppModel) {
        _controller = StateObject(wrappedValue: HeadingCaptureController(
            sessionId: sessionId, preferredTargetId: preferredTargetId, store: model.store,
            settings: model.settings, masks: model.masks, onSessionChanged: { [weak model] in model?.sessionChanged() }
        ))
    }

    var body: some View {
        ZStack {
            HeadingARViewContainer(controller: controller).ignoresSafeArea()
            // 十字は、画面の全体（カメラの映像の中心＝写真の中心）の中央に置く。
            Crosshair(state: controller.crosshair)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            overlay
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ReviewToolbarButton(sessionId: controller.sessionId, photoCount: controller.photoCount, busy: controller.captureInFlight)
            }
        }
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: controller.didEnterBackground()
            case .active: controller.didBecomeActive()
            default: break
            }
        }
        .onChange(of: controller.autoCaptureEnabled) { _, enabled in
            model.settings.autoCaptureEnabled = enabled
        }
        .onChange(of: model.revision) { _, _ in controller.sessionDidChange() }
        .confirmationDialog("気になる点があります", isPresented: $controller.showWarningsSheet, titleVisibility: .visible) {
            Button("このまま撮る") { controller.captureAcknowledgingWarnings() }
            Button("やめる", role: .cancel) {}
        } message: {
            Text(controller.assessment.warnings.map { "・\($0.message)" }.joined(separator: "\n"))
        }
    }

    private var overlay: some View {
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
                StatusChips(assessment: controller.assessment, hidden: [.inFrame])
            }
            bottomPanel
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.2), value: controller.banner)
    }

    private var topPanel: some View {
        let heading = controller.heading
        return HStack(alignment: .center, spacing: 12) {
            DirectionMiniMap(
                plan: controller.plan, progress: controller.progress, nextId: heading?.nextTarget?.id,
                activeBandElevation: heading?.nextTarget?.elevationDeg,
                currentAzimuth: heading?.relativeHeadingDeg, currentElevation: heading?.pitchDeg, hasFront: controller.hasFront
            )
            .frame(width: 104, height: 104)
            VStack(alignment: .leading, spacing: 5) {
                Text("\(controller.progress.doneCount) / \(controller.plan.targets.count)")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(controller.hasFront ? "そろった方向" : "まず正面から 1 枚")
                    .font(.caption).foregroundStyle(.secondary)
                StepProgressLine(plan: controller.plan, progress: controller.progress, nextId: heading?.nextTarget?.id)
                if let heading, let rel = heading.relativeHeadingDeg, controller.hasFront {
                    Label("正面から \(Int(rel.rounded()))°", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.monospacedDigit())
                }
                ElevationIndicator(current: heading?.pitchDeg, target: (heading?.frontTarget ?? heading?.nextTarget)?.elevationDeg)
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

    private var completePanel: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(.green)
            Text("そろいました（\(controller.progress.doneCount)/\(controller.progress.totalCount)）— 確認して送信できます")
                .font(.subheadline.bold())
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(model.isEmbeddedCapture(controller.sessionId) ? "これで登録" : "確認へ") {
                model.finishCapture(sessionId: controller.sessionId)
            }
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
                Label(tip, systemImage: "arrow.left.and.right")
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
        case .capturing:
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $controller.autoCaptureEnabled) {
                        Text("自動撮影").font(.subheadline.bold())
                    }
                    .toggleStyle(.switch)
                    .fixedSize()
                    Button("正面からやり直す") { controller.restartFront() }
                        .font(.subheadline)
                        .buttonStyle(.bordered)
                        .disabled(!controller.hasFront || controller.captureInFlight)
                }
                Spacer()
                ShutterButton(
                    progress: controller.assessment.stabilityProgress, busy: controller.captureInFlight,
                    enabled: controller.assessment.canManualCapture && !controller.captureInFlight, size: 78
                ) {
                    controller.shutterTapped()
                }
                Spacer()
                Button {
                    model.finishCapture(sessionId: controller.sessionId)
                } label: {
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
}

/// 画面の中央の十字（作品をここに合わせる）。白＝合わせている途中、橙＝向きは合っているが歩いていない、緑＝ここで撮れる。
struct Crosshair: View {
    let state: CrosshairState

    var body: some View {
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r: CGFloat = 26, arm: CGFloat = 14, gap: CGFloat = 6
            var path = Path()
            path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
                path.move(to: CGPoint(x: c.x + dx * gap, y: c.y + dy * gap))
                path.addLine(to: CGPoint(x: c.x + dx * (r + arm), y: c.y + dy * (r + arm)))
            }
            context.stroke(path, with: .color(.black.opacity(0.5)), lineWidth: 5)
            context.stroke(path, with: .color(color), lineWidth: state == .ready ? 3.5 : 2.5)
        }
        .accessibilityLabel("十字（作品をここに合わせる）")
    }

    private var color: Color {
        switch state {
        case .aligning: return .white
        case .notWalked: return .orange
        case .ready: return .green
        }
    }
}
