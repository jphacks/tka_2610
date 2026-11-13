import CaptureCore
import SwiftUI
import UIKit
import WebKit

/// memoria の Web を開く WKWebView と、その読み込み・移動・権限の扱い。
///
/// - データは既定の保存場所（`WKWebsiteDataStore.default()`）に置く。家の Cookie はアプリを閉じても残る（Safari とは別）。
/// - メインのフレームで開くのは、設定した接続先（Info.plist の `MemoriaWebURL`）のページだけ。ほかのリンクは Safari などで開く。
/// - Web の処理が落ちたら読み込み直す（撮影の画面を出している間は、閉じてから）。
/// - 読み込めなかったときは、再試行の画面を出す。
@MainActor
final class MemoriaWebController: NSObject, ObservableObject {
    /// 設定した接続先。Info.plist の値が正しくなければ nil（何も開かない）。
    let origin: WebOrigin?
    let webView: WKWebView

    /// 読み込めなかったときの文言（再試行の画面に出す）。
    @Published private(set) var loadFailure: String?
    /// 一度でも読み込み終えたか（それまでは読み込み中の印を出す）。
    @Published private(set) var hasLoaded = false

    /// メインのフレームのページが入れ替わるたび（読み込み・Web の処理が落ちた）に増える。
    /// 撮影の結果を返すときに、頼んだページがまだあるかを見る（MemoriaBridge）。
    private(set) var pageGeneration = 0

    private weak var model: AppModel?
    private let bridge: MemoriaBridge
    private var lastRequestedURL: URL?
    /// 撮影中に Web の処理が落ちたので、撮影が終わったら読み込み直す。
    private var reloadWhenCaptureEnds = false

    init(model: AppModel, bundle: Bundle = .main) {
        self.model = model
        let configured = bundle.object(forInfoDictionaryKey: "MemoriaWebURL") as? String ?? ""
        origin = WebOrigin(string: configured)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        let content = WKUserContentController()
        // 読み込みの初めに window.MemoriaNative を入れる（メインのフレームだけ）。
        content.addUserScript(WKUserScript(
            source: NativeCaptureInfo.current.userScriptSource(), injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        configuration.userContentController = content
        webView = WKWebView(frame: .zero, configuration: configuration)
        bridge = MemoriaBridge(model: model)
        super.init()

        bridge.web = self
        content.addScriptMessageHandler(bridge, contentWorld: .page, name: WebBridgeProtocol.handlerName)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // 画面の上下の余白は Web が決める（viewport-fit=cover と env(safe-area-inset-*)）。
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsBackForwardNavigationGestures = false
        #if DEBUG
        webView.isInspectable = true  // Mac の Safari の「開発」メニューから調べられる
        #endif
        loadHome()
    }

    // MARK: 読み込み

    /// 一番上のページを開く。
    func loadHome() {
        guard let origin else { return }
        load(origin.rootURL)
    }

    func load(_ url: URL) {
        guard origin?.contains(url) == true else { return }
        lastRequestedURL = url
        loadFailure = nil
        webView.load(URLRequest(url: url))
    }

    /// 読み込み直す（読み込めなかったときは、最後に開こうとしたページを開き直す）。
    func reload() {
        if loadFailure != nil || webView.url == nil {
            if let url = lastRequestedURL { load(url) } else { loadHome() }
        } else {
            loadFailure = nil
            webView.reload()
        }
    }

    /// 「家を引き継ぐ」：`<接続先>/?house=<番号>` を開く（Web がその家の Cookie を付ける）。
    func switchHouse(id: String) {
        guard let origin, HouseLink.isValidId(id) else { return }
        load(HouseLink.switchURL(origin: origin, houseId: id))
    }

    /// 撮影の画面が閉じた（「これで登録」か「やめる」）。撮影中に Web の処理が落ちていたら、ここで読み込み直す。
    func captureEnded() {
        guard reloadWhenCaptureEnds else { return }
        reloadWhenCaptureEnds = false
        reload()
    }

    private func openExternally(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "tel", "sms"].contains(scheme) else { return }
        UIApplication.shared.open(url)
    }

    private func failureMessage(_ error: Error) -> String? {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return nil }
        // 102：移動を止めた（ほかの接続先のリンクを Safari で開いたときなど）。
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return nil }
        if ns.domain == NSURLErrorDomain && [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost].contains(ns.code) {
            return "インターネットにつながっていません。つながってから、もう一度読み込んでください。"
        }
        return "memoria を開けませんでした（\(error.localizedDescription)）"
    }

    /// 一番上に出ている画面（JS の alert などを出すため）。
    private func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

// MARK: - 移動・読み込み

extension MemoriaWebController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        // iframe の中の移動はそのまま（メインのフレームだけを決まった接続先に絞る）。
        if let frame = navigationAction.targetFrame, !frame.isMainFrame { return .allow }
        if origin?.contains(url) == true { return .allow }
        if url.scheme == "about" { return .allow }
        openExternally(url)
        return .cancel
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        pageGeneration += 1
        loadFailure = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hasLoaded = true
        loadFailure = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if let message = failureMessage(error) { loadFailure = message }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if let message = failureMessage(error) { loadFailure = message }
    }

    /// Web の処理が落ちた（3D の家と撮影でメモリが足りないときなど）。ページは入れ替わったものとして扱う。
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pageGeneration += 1
        if model?.embeddedCapture != nil {
            reloadWhenCaptureEnds = true
        } else {
            reload()
        }
    }
}

// MARK: - 新しい窓・権限・JS のダイアログ

extension MemoriaWebController: WKUIDelegate {
    /// `target="_blank"`・`window.open`：同じ接続先ならこの画面で開き、ほかは外で開く（新しい窓は作らない）。
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if origin?.contains(url) == true { load(url) } else { openExternally(url) }
        }
        return nil
    }

    /// カメラ・マイク（Web の写真・動画・声の記録）。設定した接続先のときだけ許す（iOS の許可は別に聞かれる）。
    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        guard let configured = self.origin,
              configured.matches(scheme: origin.protocol, host: origin.host, port: origin.port) else { return .deny }
        return .grant
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in continuation.resume() })
            guard let top = topViewController() else { return continuation.resume() }
            top.present(alert, animated: true)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel) { _ in continuation.resume(returning: false) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in continuation.resume(returning: true) })
            guard let top = topViewController() else { return continuation.resume(returning: false) }
            top.present(alert, animated: true)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel) { _ in continuation.resume(returning: nil) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
                continuation.resume(returning: alert?.textFields?.first?.text ?? "")
            })
            guard let top = topViewController() else { return continuation.resume(returning: nil) }
            top.present(alert, animated: true)
        }
    }
}

// MARK: - SwiftUI

/// WKWebView を SwiftUI に置く。
struct MemoriaWebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// アプリの一番下の画面：memoria の Web。読み込めないときは再試行の画面。
struct MemoriaWebScreen: View {
    @ObservedObject var web: MemoriaWebController
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            if web.origin == nil {
                MessageScreen(
                    systemImage: "gearshape.2",
                    title: "接続先が設定されていません",
                    message: "アプリの MemoriaWebURL（capture/ios/Config の MEMORIA_WEB_SCHEME・MEMORIA_WEB_HOST）を確かめてください。",
                    actionTitle: "撮影データ（開発用）"
                ) { model.showsDeveloperScreens = true }
            } else {
                MemoriaWebViewContainer(webView: web.webView)
                    .ignoresSafeArea()
                if let failure = web.loadFailure {
                    LoadFailureView(message: failure) {
                        web.reload()
                    } openSessions: {
                        model.showsDeveloperScreens = true
                    }
                } else if !web.hasLoaded {
                    ProgressView("memoria を読み込んでいます")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }
}

/// 読み込めなかったときの画面（もう一度読み込む・開発用の画面）。
struct LoadFailureView: View {
    let message: String
    let retry: () -> Void
    let openSessions: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("memoria を開けませんでした").font(.title3.bold())
            Text(message).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("もう一度読み込む", action: retry)
                .buttonStyle(.borderedProminent)
            Button("撮影データ（開発用）", action: openSessions)
                .buttonStyle(.bordered)
                .font(.footnote)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}
