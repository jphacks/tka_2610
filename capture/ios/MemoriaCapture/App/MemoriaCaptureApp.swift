import CaptureCore
import SwiftUI

@main
struct MemoriaCaptureApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .environmentObject(model)
                .environmentObject(model.settings)
                .environmentObject(model.transfer)
        }
    }
}

/// 一番下は memoria の Web。撮影（Web から頼まれたとき）と開発用の画面（撮影データの一覧・確認・Mac へ送る・設定）は、
/// それぞれ全画面のカバーで上に出す。
struct RootView: View {
    @ObservedObject private var model: AppModel
    @StateObject private var web: MemoriaWebController

    init(model: AppModel) {
        self.model = model
        _web = StateObject(wrappedValue: MemoriaWebController(model: model))
    }

    var body: some View {
        ZStack {
            MemoriaWebScreen(web: web)
                .fullScreenCover(item: $model.embeddedCapture, onDismiss: { model.embeddedCaptureDidDismiss() }) { capture in
                    EmbeddedCaptureScreen(capture: capture)
                        .modifier(CoverEnvironment(model: model, web: web))
                }
        }
        .fullScreenCover(isPresented: $model.showsDeveloperScreens) {
            DeveloperScreens()
                .modifier(CoverEnvironment(model: model, web: web))
        }
        .modifier(ModelAlert(enabled: model.embeddedCapture == nil && !model.showsDeveloperScreens))
    }
}

/// 全画面のカバーの中にも、アプリの状態と Web を渡す（お知らせもカバーの中で出す）。
private struct CoverEnvironment: ViewModifier {
    @ObservedObject var model: AppModel
    let web: MemoriaWebController

    func body(content: Content) -> some View {
        content
            .environmentObject(model)
            .environmentObject(model.settings)
            .environmentObject(model.transfer)
            .environmentObject(web)
            .modifier(ModelAlert(enabled: true))
    }
}

/// `AppModel.alertMessage` のお知らせ。カバーを出している間は、一番上のカバーの中でだけ出す。
private struct ModelAlert: ViewModifier {
    let enabled: Bool
    @EnvironmentObject private var model: AppModel

    func body(content: Content) -> some View {
        content.alert("お知らせ", isPresented: Binding(
            get: { enabled && model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}

/// memoria から頼まれた撮影の画面。左上の「やめる」で、撮った写真を消して Web に戻る（写真があれば確かめる）。
/// 「これで登録」は撮影画面の中のボタン（`AppModel.finishCapture`）。
struct EmbeddedCaptureScreen: View {
    let capture: EmbeddedCapture
    @EnvironmentObject private var model: AppModel
    @State private var confirmingCancel = false

    var body: some View {
        let photoCount = model.loadSession(capture.sessionId)?.photos.count ?? 0
        NavigationStack {
            CaptureScreen(sessionId: capture.sessionId, preferredTargetId: nil)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("やめる") {
                            if photoCount > 0 { confirmingCancel = true } else { model.cancelEmbeddedCapture() }
                        }
                    }
                }
                .confirmationDialog("撮った写真を消して、やめますか？", isPresented: $confirmingCancel, titleVisibility: .visible) {
                    Button("写真を消してやめる", role: .destructive) { model.cancelEmbeddedCapture() }
                    Button("撮影を続ける", role: .cancel) {}
                } message: {
                    Text("撮った \(photoCount) 枚の写真は、この iPhone から消えます。")
                }
        }
    }
}

/// 開発用の画面：今までの撮影データの一覧・確認・Mac へ送る・設定。
struct DeveloperScreens: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack(path: $model.path) {
            SessionListView()
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("閉じる") { model.showsDeveloperScreens = false }
                    }
                }
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case let .capture(sessionId, preferredTargetId):
                        CaptureScreen(sessionId: sessionId, preferredTargetId: preferredTargetId)
                    case let .review(sessionId):
                        ReviewView(sessionId: sessionId)
                    case let .photo(sessionId, photoId):
                        PhotoDetailView(sessionId: sessionId, photoId: photoId)
                    case let .send(sessionId):
                        SendView(sessionId: sessionId)
                    case .settings:
                        SettingsView()
                    }
                }
        }
    }
}
