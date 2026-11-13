import ARKit
import CaptureCore
import SwiftUI

/// 平面の作品の撮影画面：写真と同じ範囲の映像（`CameraPreviewContainer`）の上に用紙の輪郭、上の帯に短い案内と選んだ紙・傾き、
/// 下の帯に自動撮影・シャッター・「これで登録」（「確認へ」）。
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
        CameraPreviewContainer(arView: controller.arView, imageAspect: controller.previewAspect) {
            // 輪郭は ARSCNView の座標（映像の枠と同じ）。
            SheetOutline(points: controller.outline, ready: controller.guidance == .ready)
        } panels: {
            panels
        } top: {
            topBar
        } bottom: {
            bottomBar
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

    /// 映像の上に浮かべるもの：撮ったときの知らせ（上の端）と、撮った写真の結果（下の端）。
    private var panels: some View {
        VStack(spacing: 8) {
            if let banner = controller.banner {
                BannerView(message: banner.message, isError: banner.isError)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
            if let shot = controller.lastShot {
                lastShotPanel(shot)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .animation(.easeInOut(duration: 0.2), value: controller.banner)
    }

    private func lastShotPanel(_ shot: FlatCaptureController.LastShot) -> some View {
        let good = shot.sheetFound && !shot.sheetAtEdge && shot.overhead
        return HStack(spacing: 8) {
            Image(systemName: good ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(good ? .green : .orange)
            Text("1 / 1 撮りました").bold()
            Text(shotDetail(shot)).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
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

    /// 上の帯：案内の文と、選んだ紙・傾き。
    private var topBar: some View {
        VStack(spacing: 6) {
            CaptureGuidanceText(text: controller.guidanceText)
            if controller.phase == .capturing, controller.declaredSheet != nil || controller.lookDownDeg != nil {
                HStack(spacing: 6) {
                    if let sheet = controller.declaredSheet {
                        CaptureInfoChip(text: "紙：\(sheet.isCustom ? sheet.labelWithSize : sheet.displayName)（選んだ大きさ）")
                    }
                    if let tilt = controller.lookDownDeg {
                        CaptureInfoChip(text: "傾き \(Int(tilt.rounded()))°（\(Int(DirectionPlanPreset.flatTopElevation - DirectionPlanPreset.flatTopElevationTolerance))° 以上で真上）")
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// 下の帯：自動撮影・シャッター・「これで登録」（「確認へ」）。
    @ViewBuilder
    private var bottomBar: some View {
        switch controller.phase {
        case .starting:
            ProgressView().padding()
        case .unsupported, .failed:
            EmptyView()
        case .capturing:
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
                Button {
                    model.finishCapture(sessionId: controller.sessionId)
                } label: {
                    Text(model.isEmbeddedCapture(controller.sessionId) ? "これで登録" : "確認へ")
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.captureInFlight || controller.photoCount == 0)
                    .frame(width: 90)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
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
