import ARKit
import CaptureCore
import SwiftUI

/// ARSCNView を SwiftUI に置く（平面の作品の撮影）。
struct FlatARViewContainer: UIViewRepresentable {
    let controller: FlatCaptureController

    func makeUIView(context: Context) -> ARSCNView { controller.arView }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

/// 平面の作品の撮影画面：カメラの上に用紙の輪郭・短い案内・シャッターを重ねる。
struct FlatCaptureView: View {
    @StateObject private var controller: FlatCaptureController
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init(sessionId: String, model: AppModel) {
        _controller = StateObject(wrappedValue: FlatCaptureController(
            sessionId: sessionId, store: model.store, settings: model.settings, masks: model.masks,
            onSessionChanged: { [weak model] in model?.sessionChanged() }
        ))
    }

    var body: some View {
        ZStack {
            FlatARViewContainer(controller: controller).ignoresSafeArea()
            SheetOutline(points: controller.outline, ready: controller.guidance == .ready)
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
    }

    private var overlay: some View {
        VStack(spacing: 8) {
            if let banner = controller.banner {
                BannerView(message: banner.message, isError: banner.isError)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Text(controller.guidanceText)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
            if let shot = controller.lastShot {
                lastShotPanel(shot)
            }
            Spacer(minLength: 0)
            bottomPanel
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.2), value: controller.banner)
    }

    private func lastShotPanel(_ shot: FlatCaptureController.LastShot) -> some View {
        HStack(spacing: 10) {
            Image(systemName: shot.sheetFound && !shot.sheetAtEdge && shot.overhead ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(shot.sheetFound && !shot.sheetAtEdge && shot.overhead ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("1 / 1 撮りました").font(.subheadline.bold())
                Text(shotDetail(shot)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(model.isEmbeddedCapture(controller.sessionId) ? "これで登録" : "確認へ") {
                model.finishCapture(sessionId: controller.sessionId)
            }
                .buttonStyle(.borderedProminent)
                .disabled(controller.captureInFlight || controller.photoCount == 0)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func shotDetail(_ shot: FlatCaptureController.LastShot) -> String {
        var parts: [String] = []
        if !shot.sheetFound { parts.append("紙は見つからず（写真全体）") }
        if shot.sheetAtEdge { parts.append("紙が端で切れているかも") }
        if !shot.overhead { parts.append("真上ではない") }
        if let sheet = controller.declaredSheet {
            parts.append("紙 \(sheet.displayName)（選んだ大きさ）")
        } else if shot.sheetFound {
            parts.append(shot.sizeText.map { "大きさ \($0)" } ?? "大きさは測れず")
        }
        return parts.joined(separator: "・")
    }

    @ViewBuilder
    private var bottomPanel: some View {
        switch controller.phase {
        case .starting:
            ProgressView().padding()
        case .unsupported, .failed:
            EmptyView()
        case .capturing:
            VStack(spacing: 10) {
                if let sheet = controller.declaredSheet {
                    Text("紙：\(sheet.isCustom ? sheet.labelWithSize : sheet.displayName)（選んだ大きさ）")
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.5), in: Capsule())
                        .foregroundStyle(.white)
                }
                if let tilt = controller.lookDownDeg {
                    Text("傾き \(Int(tilt.rounded()))°（\(Int(DirectionPlanPreset.flatTopElevation - DirectionPlanPreset.flatTopElevationTolerance))° 以上で真上）")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.5), in: Capsule())
                        .foregroundStyle(.white)
                }
                HStack {
                    Toggle("自動", isOn: $controller.autoCaptureEnabled)
                        .toggleStyle(.button)
                        .tint(.green)
                        .frame(width: 90)
                    Spacer()
                    ShutterButton(progress: controller.holdProgress, busy: controller.captureInFlight,
                                  enabled: !controller.captureInFlight, size: 76) {
                        controller.shutterTapped()
                    }
                    Spacer()
                    Color.clear.frame(width: 90, height: 1)
                }
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

/// 見つかった用紙の輪郭（撮れる状態なら緑、ほかは黄色）。
struct SheetOutline: View {
    let points: [CGPoint]?
    let ready: Bool

    var body: some View {
        Canvas { context, _ in
            guard let points, points.count == 4 else { return }
            var path = Path()
            path.addLines(points)
            path.closeSubpath()
            let color: Color = ready ? .green : .yellow
            context.fill(path, with: .color(color.opacity(0.12)))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 4, lineJoin: .round))
        }
    }
}
