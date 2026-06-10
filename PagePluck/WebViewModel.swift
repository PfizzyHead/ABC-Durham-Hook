import SwiftUI
import WebKit

/// Owns the `WKWebView` and exposes browsing state plus the two operations the
/// rest of the app needs: scanning the current page for media and syncing the
/// web view's cookies so downloads/thumbnails are authenticated the same way.
///
/// Marked `@MainActor` because all `WKWebView` access must happen on the main
/// thread; this keeps `scanMedia`/`syncCookies`/`load` main-thread-safe.
@MainActor
final class WebViewModel: NSObject, ObservableObject {
    let webView: WKWebView

    @Published var urlString: String = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var pageTitle = ""

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // Present as mobile Safari so sites serve the layout we expect.
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    }

    /// The page currently shown — used as the Referer when downloading media.
    var currentURL: URL? { webView.url }

    func load(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            // Treat input with no dot and spaces as a search; otherwise assume a host.
            if text.contains(" ") || !text.contains(".") {
                let q = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
                text = "https://www.google.com/search?q=\(q)"
            } else {
                text = "https://" + text
            }
        }
        guard let url = URL(string: text) else { return }
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }

    /// Copies the web view's cookies into the shared store so that `URLSession`
    /// (used for downloading) and `AsyncImage` (used for thumbnails) send the
    /// same authenticated session the user just logged into.
    func syncCookies() async {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        for cookie in cookies {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    /// Runs the scanner JS against the live page and returns the media found.
    func scanMedia() async -> [MediaItem] {
        await syncCookies()
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(MediaScanner.script) { result, _ in
                guard let json = result as? String,
                      let data = json.data(using: .utf8),
                      let raw = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(returning: raw.compactMap { MediaItem(dict: $0) })
            }
        }
    }
}

extension WebViewModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        urlString = webView.url?.absoluteString ?? urlString
        pageTitle = webView.title ?? ""
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }
}

/// Bridges the model's `WKWebView` into SwiftUI.
struct WebViewContainer: UIViewRepresentable {
    let model: WebViewModel
    func makeUIView(context: Context) -> WKWebView { model.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
