import SwiftUI

@main
struct MemoriaCaptureApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .environmentObject(model.transfer)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack(path: $model.path) {
            SessionListView()
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
        .alert("お知らせ", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}
