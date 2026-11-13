import ARKit
import CaptureCore
import SwiftUI

/// 立体の作品を自由に撮る撮影画面：写真と同じ範囲の映像（`CameraPreviewContainer`）の上の帯に目安の文、下の帯に撮った枚数・シャッター
/// （案内・自動撮影なし）。
struct FreeCaptureView: View {
    @StateObject private var controller: FreeCaptureController
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init(sessionId: String, model: AppModel) {
        _controller = StateObject(wrappedValue: FreeCaptureController(
            sessionId: sessionId, store: model.store, masks: model.masks,
            onSessionChanged: { [weak model] in model?.sessionChanged() }
        ))
    }

    var body: some View {
        CameraPreviewContainer(arView: controller.arView, imageAspect: controller.previewAspect) {
            EmptyView()
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
    }

    /// 映像の上に浮かべるもの：撮ったときの知らせ（映像の上の端）。
    private var panels: some View {
        VStack(spacing: 8) {
            if let banner = controller.banner {
                BannerView(message: banner.message, isError: banner.isError)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.2), value: controller.banner)
    }

    /// 上の帯：目安の文と、入力した高さ。
    private var topBar: some View {
        VStack(spacing: 6) {
            CaptureGuidanceText(text: controller.guidanceText)
            if controller.phase == .capturing, let height = controller.declaredHeightM {
                CaptureInfoChip(text: String(format: "高さ %.1f cm（入力した値）", height * 100))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// 下の帯：枚数・シャッター・「これで登録」（「確認へ」）。
    @ViewBuilder
    private var bottomBar: some View {
        switch controller.phase {
        case .starting:
            ProgressView().padding()
        case .unsupported, .failed:
            EmptyView()
        case .capturing:
            HStack {
                Text("\(controller.photoCount) 枚")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 90)
                Spacer()
                ShutterButton(progress: 0, busy: controller.captureInFlight,
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
