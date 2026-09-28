import SwiftUI
import WebKit

/// Minimal WKWebView wrapper for HTML/SVG previews and port previews.
///
/// For port previews it attaches the Open WebUI bearer token (and custom
/// headers) to every top-level request that targets the terminal proxy, the
/// same way the web UI's iframe is authenticated by its session cookie.
struct TerminalWebView: UIViewRepresentable {
    enum Content: Equatable {
        case html(String, baseURL: URL?)
        case url(URL)
    }

    let content: Content
    var authorizedPrefix: String? = nil
    var headers: [String: String] = [:]
    var reloadToken: Int = 0
    @Binding var isLoading: Bool
    var onNavigate: ((URL) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.contentInsetAdjustmentBehavior = .automatic
        context.coordinator.load(content, into: view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.lastContent != content || coordinator.lastReload != reloadToken {
            coordinator.load(content, into: view)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: TerminalWebView
        var lastContent: Content?
        var lastReload = 0

        init(parent: TerminalWebView) { self.parent = parent }

        func load(_ content: Content, into view: WKWebView) {
            lastContent = content
            lastReload = parent.reloadToken
            switch content {
            case .html(let html, let baseURL):
                view.loadHTMLString(html, baseURL: baseURL)
            case .url(let url):
                view.load(authorized(URLRequest(url: url)))
            }
        }

        private func authorized(_ request: URLRequest) -> URLRequest {
            var request = request
            guard let prefix = parent.authorizedPrefix, request.url?.absoluteString.hasPrefix(prefix) == true else { return request }
            for (key, value) in parent.headers { request.setValue(value, forHTTPHeaderField: key) }
            return request
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            // Re-issue top-level proxy navigations with auth headers attached.
            if action.targetFrame?.isMainFrame == true,
               let prefix = parent.authorizedPrefix,
               let url = action.request.url, url.absoluteString.hasPrefix(prefix),
               action.request.value(forHTTPHeaderField: "Authorization") == nil,
               !parent.headers.isEmpty {
                decisionHandler(.cancel)
                webView.load(authorized(action.request))
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            if let url = webView.url { parent.onNavigate?(url) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }
    }
}

/// In-app preview of a port served inside the terminal (web `PortPreview`).
struct TerminalPortPreviewView: View {
    let viewModel: TerminalBrowserViewModel
    let port: TerminalListeningPort

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var path = ""
    @State private var address = ""
    @State private var reload = 0
    @State private var loading = false

    var body: some View {
        NavigationStack {
            Group {
                if let url = viewModel.portURL(port.port, path: path) {
                    TerminalWebView(content: .url(url), authorizedPrefix: viewModel.portURL(port.port)?.absoluteString,
                                    headers: authHeaders, reloadToken: reload, isLoading: $loading) { url in
                        address = displayAddress(for: url)
                    }
                } else {
                    ContentUnavailableView("Can't open port", systemImage: "network.slash")
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly).tint(.secondary)
                }
                ToolbarItem(placement: .principal) {
                    TextField("localhost:\(port.port)", text: $address)
                        .scaledFont(size: 13, design: .monospaced)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL).submitLabel(.go)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(theme.surfaceContainer, in: Capsule())
                        .frame(maxWidth: 260)
                        .onSubmit { navigateToAddress() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if loading { ProgressView().controlSize(.small) } else {
                        Button { reload += 1 } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel("Reload")
                    }
                    Button {
                        if let url = viewModel.portURL(port.port, path: path) { UIApplication.shared.open(url) }
                    } label: { Image(systemName: "safari") }
                    .accessibilityLabel("Open in Safari")
                }
            }
        }
        .onAppear { address = "localhost:\(port.port)" }
    }

    private var authHeaders: [String: String] {
        guard let network = viewModel.apiClient?.network else { return [:] }
        var headers = network.serverConfig.customHeaders
        if let token = network.authToken { headers["Authorization"] = "Bearer \(token)" }
        return headers
    }

    private func displayAddress(for url: URL) -> String {
        guard let base = viewModel.portURL(port.port)?.absoluteString, url.absoluteString.hasPrefix(base) else { return url.absoluteString }
        let rest = String(url.absoluteString.dropFirst(base.count))
        return "localhost:\(port.port)" + (rest.isEmpty ? "" : "/" + rest)
    }

    private func navigateToAddress() {
        var text = address.trimmingCharacters(in: .whitespaces)
        for prefix in ["http://", "https://"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        let local = "localhost:\(port.port)"
        if text.hasPrefix(local) { text.removeFirst(local.count) }
        path = text.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        reload += 1
    }
}
