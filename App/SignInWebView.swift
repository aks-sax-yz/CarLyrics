import SwiftUI
import WebKit

/// A service's own sign-in page inside the app, for lyrics that need its web player's login
/// (Apple Music, Spotify). Uses the shared persistent web data store, so the login (cookies)
/// survives relaunches and the off-screen token refresh can reuse it.
///
/// Popups (Apple ID's `window.open`, "Continue with Google / Apple / Facebook") open as child
/// web views on top, so the opener still gets its reply. Passkeys can't work here: iOS only allows
/// them in browsers (or for the app's own website), so the page offers password / code instead.
struct SignInWebView: UIViewRepresentable {
    let url: URL
    var userAgent: String? = nil
    /// Injected at document start in every frame; it can `webkit.messageHandlers.carlyrics.postMessage(…)`.
    var script: String? = nil
    var onMessage: @MainActor (Any) -> Void = { _ in }

    static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    func makeCoordinator() -> Coordinator { Coordinator(onMessage: onMessage) }

    func makeUIView(context: Context) -> WKWebView {
        let web = Self.makeWebView(script: script, userAgent: userAgent, handler: context.coordinator)
        web.uiDelegate = context.coordinator
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "carlyrics")
    }

    /// Also used off screen for token refreshes.
    static func makeWebView(script: String?, userAgent: String?, handler: WKScriptMessageHandler) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        if let script {
            config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        config.userContentController.add(handler, name: "carlyrics")
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = userAgent
        return web
    }

    final class Coordinator: NSObject, WKUIDelegate, WKScriptMessageHandler {
        let onMessage: @MainActor (Any) -> Void
        init(onMessage: @escaping @MainActor (Any) -> Void) { self.onMessage = onMessage }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let body = message.body as? [String: String] // the scripts only post string dictionaries
            MainActor.assumeIsolated { onMessage(body as Any) }
        }

        func webView(_ web: WKWebView, createWebViewWith config: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            let popup = WKWebView(frame: web.bounds, configuration: config)
            popup.customUserAgent = web.customUserAgent
            popup.uiDelegate = self
            popup.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            web.addSubview(popup)
            return popup
        }

        func webViewDidClose(_ web: WKWebView) { web.removeFromSuperview() }
    }
}

/// The sheet around a SignInWebView: a title and a Cancel button.
struct SignInSheet: View {
    let title: String
    let web: SignInWebView
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            web.ignoresSafeArea(edges: .bottom)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

@MainActor
enum WebCookies {
    static func value(_ name: String, domain: String) async -> String? {
        await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            .first { $0.name == name && $0.domain.hasSuffix(domain) && ($0.expiresDate ?? .distantFuture) > Date() }?.value
    }

    /// Signs the web views out of one service (other services' logins stay).
    static func clear(domain: String) async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                               for: records.filter { $0.displayName.hasSuffix(domain) })
    }
}
