import ARKit
import AVFoundation
import CaptureCore
import SwiftUI

/// 撮影画面：カメラの許可と AR の対応を確かめてから、AR の撮影を出す。
/// 平面の作品（`workKind` が `flat`）は真上から 1 枚の撮影（`FlatCaptureView`）、立体で自由に撮るセッション（`guidance` が `free`）は
/// `FreeCaptureView`、向きで案内するセッション（`guidance` が `heading`）は `HeadingCaptureView`、それ以外の立体は
/// 底の中心と円柱で案内する撮影（`CaptureView`）。
struct CaptureScreen: View {
    let sessionId: String
    let preferredTargetId: String?

    @EnvironmentObject private var model: AppModel
    @State private var permission = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        Group {
            if !ARWorldTrackingConfiguration.isSupported {
                MessageScreen(
                    systemImage: "arkit",
                    title: "AR に対応していません",
                    message: "この端末（またはシミュレーター）は ARKit のワールドトラッキングに対応していないため、撮影できません。撮った写真の確認と送信はできます。"
                )
            } else if model.isLocked(sessionId) {
                MessageScreen(systemImage: "arrow.up.circle", title: "送信中です", message: "送信が終わるまで、このセッションは撮影できません。")
            } else {
                switch permission {
                case .authorized:
                    // セッションは 1 回だけ読む。消えた（「やめる」で消している途中など）ときは、別の撮影画面を作らない。
                    if let session = model.loadSession(sessionId) {
                        if session.isFlat {
                            FlatCaptureView(sessionId: sessionId, model: model)
                        } else if session.usesFreeCapture {
                            FreeCaptureView(sessionId: sessionId, model: model)
                        } else if session.usesHeadingGuidance {
                            HeadingCaptureView(sessionId: sessionId, preferredTargetId: preferredTargetId, model: model)
                        } else {
                            CaptureView(sessionId: sessionId, preferredTargetId: preferredTargetId, model: model)
                        }
                    } else {
                        MessageScreen(systemImage: "questionmark.folder", title: "撮影データがありません", message: "この撮影データは消されました。")
                    }
                case .notDetermined:
                    ProgressView("カメラの許可を確認しています")
                        .task {
                            _ = await AVCaptureDevice.requestAccess(for: .video)
                            permission = AVCaptureDevice.authorizationStatus(for: .video)
                        }
                default:
                    MessageScreen(
                        systemImage: "camera.fill",
                        title: "カメラを使えません",
                        message: "作品を撮影するには、カメラの使用を許可してください。「設定」アプリの「Memoria」で「カメラ」をオンにしてください。",
                        actionTitle: "設定を開く"
                    ) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            }
        }
        .navigationTitle("撮影")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            permission = AVCaptureDevice.authorizationStatus(for: .video)
        }
    }
}

/// 撮影画面の右上のボタン。ふだんは「確認（n）」で確認画面へ、memoria から頼まれた撮影では「これで登録」（0 枚では押せない）。
struct ReviewToolbarButton: View {
    let sessionId: String
    let photoCount: Int
    let busy: Bool
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.isEmbeddedCapture(sessionId) {
            Button {
                model.finishCapture(sessionId: sessionId)
            } label: {
                Text("これで登録").bold()
            }
            .disabled(busy || photoCount == 0)
        } else {
            Button {
                model.finishCapture(sessionId: sessionId)
            } label: {
                Label("確認（\(photoCount)）", systemImage: "square.grid.2x2")
            }
            .disabled(busy)
        }
    }
}

struct MessageScreen: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage).font(.system(size: 48)).foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text(message).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// ARSCNView を SwiftUI に置く。
struct ARViewContainer: UIViewRepresentable {
    let controller: CaptureController

    func makeUIView(context: Context) -> ARSCNView { controller.arView }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

struct CaptureView: View {
    @StateObject private var controller: CaptureController
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init(sessionId: String, preferredTargetId: String?, model: AppModel) {
        _controller = StateObject(wrappedValue: CaptureController(
            sessionId: sessionId, preferredTargetId: preferredTargetId, store: model.store,
            settings: model.settings, masks: model.masks, onSessionChanged: { [weak model] in model?.sessionChanged() }
        ))
    }

    var body: some View {
        ZStack {
            ARViewContainer(controller: controller).ignoresSafeArea()
            CaptureOverlay(controller: controller, reviewLabel: model.isEmbeddedCapture(controller.sessionId) ? "これで登録" : "確認へ") {
                model.finishCapture(sessionId: controller.sessionId)
            }
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
        .alert("基準が未設定です", isPresented: $controller.showNoReferenceDialog) {
            Button("基準を設定する") { controller.setReferenceFromDialog() }
                .keyboardShortcut(.defaultAction)
            Button("このまま撮る") { controller.captureWithoutReference() }
        } message: {
            Text("基準が未設定です。方向が記録されず、切り抜きも不正確になります")
        }
        .confirmationDialog("気になる点があります", isPresented: $controller.showWarningsSheet, titleVisibility: .visible) {
            Button("このまま撮る") { controller.captureAcknowledgingWarnings() }
            Button("やめる", role: .cancel) {}
        } message: {
            Text(controller.assessment.warnings.map { "・\($0.message)" }.joined(separator: "\n"))
        }
    }
}
