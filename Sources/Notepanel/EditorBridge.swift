import WebKit

/// The editor page in a WKWebView, and the JSON messages to and from it.
@MainActor
final class EditorBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    var onMessage: (_ type: String, _ body: [String: Any]) -> Void = { _, _ in }

    private let page: URL
    private var ready = false
    private var queued: [String] = []

    override init() {
        guard let page = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web") else {
            fatalError("web/index.html is missing from the app bundle. Build the app with scripts/bundle.sh.")
        }
        self.page = page
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        super.init()
        webView.configuration.userContentController.add(self, name: "native")
        webView.navigationDelegate = self
        // Lets Safari's Web Inspector attach (Develop menu) when something goes wrong.
        webView.isInspectable = true
        webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    }

    /// Calls `receive({type, data})` in the page. Messages sent before the page is ready wait.
    func send(_ type: String, _ data: Any) {
        guard let json = try? JSONSerialization.data(withJSONObject: ["type": type, "data": data]),
            let message = String(data: json, encoding: .utf8)
        else { return }
        let script = "receive(\(message))"
        if ready {
            webView.evaluateJavaScript(script, completionHandler: nil)
        } else {
            queued.append(script)
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "ready" {
            ready = true
            for script in queued { webView.evaluateJavaScript(script, completionHandler: nil) }
            queued = []
        }
        onMessage(type, body)
    }

    // If WebKit's page process dies, the page reloads and says "ready" again, and the controller
    // reopens the note. The note's text is safe: the store already has everything the page sent.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        webView.reload()
    }

    // Only the editor page loads in the view. Links open in the browser through `openURL`,
    // and a file dropped on the view must not replace the page.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
        -> WKNavigationActionPolicy
    {
        navigationAction.request.url == page ? .allow : .cancel
    }
}
