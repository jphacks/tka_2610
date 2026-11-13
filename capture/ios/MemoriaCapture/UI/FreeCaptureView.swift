import ARKit
import CaptureCore
import SwiftUI

/// ARSCNView を SwiftUI に置く（自由に撮る撮影）。
struct FreeARViewContainer: UIViewRepresentable {
    let controller: FreeCaptureController

    func makeUIView(context: Context) -> ARSCNView { controller.arView }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

/// 立体の作品を自由に撮る撮影画面：カメラの上に目安の文・撮った枚数・シャッターを重ねる（案内・自動撮影なし）。
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
        ZStack {
            FreeARViewContainer(controller: controller).ignoresSafeArea()
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
            Spacer(minLength: 0)
            bottomPanel
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.2), value: controller.banner)
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
                if let height = controller.declaredHeightM {
                    Text(String(format: "高さ %.1f cm（入力した値）", height * 100))
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.5), in: Capsule())
                        .foregroundStyle(.white)
                }
                HStack {
                    Text("\(controller.photoCount) 枚")
                        .font(.headline.monospacedDigit())
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
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}
