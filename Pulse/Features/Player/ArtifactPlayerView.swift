import SwiftUI
import WebKit

struct ArtifactPlayerView: View {
    let url: URL
    let accessibilityIdentifier: String

    @State private var loadState: ArtifactPlayerLoadState = .loading
    @State private var reloadToken = UUID()

    var body: some View {
        ZStack {
            Color.black

            ArtifactWebView(
                url: url,
                reloadToken: reloadToken,
                loadState: $loadState,
                accessibilityIdentifier: accessibilityIdentifier
            )
            .opacity(loadState.isFailure ? 0 : 1)

            if loadState == .loading {
                ProgressView("Loading interactive app…")
                    .tint(.pulseLime)
                    .foregroundStyle(.white)
                    .padding(16)
                    .background(.black.opacity(0.72), in: Capsule())
                    .accessibilityIdentifier("artifact.player.loading")
            } else if case let .failed(message) = loadState {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.pulseCoral)
                    Text("Interactive app unavailable")
                        .font(.headline)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try again") {
                        loadState = .loading
                        reloadToken = UUID()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.pulseLime)
                    .foregroundStyle(.black)
                }
                .padding(22)
                .accessibilityIdentifier("artifact.player.error")
            }
        }
    }
}

private enum ArtifactPlayerLoadState: Equatable {
    case loading
    case ready
    case failed(String)

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

private struct ArtifactWebView: UIViewRepresentable {
    let url: URL
    let reloadToken: UUID
    @Binding var loadState: ArtifactPlayerLoadState
    let accessibilityIdentifier: String

    func makeCoordinator() -> Coordinator {
        Coordinator(loadState: $loadState)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = [.audio]
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.keyboardDismissMode = .onDrag
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.accessibilityIdentifier = accessibilityIdentifier
        context.coordinator.load(url: url, reloadToken: reloadToken, in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.loadState = $loadState
        context.coordinator.load(url: url, reloadToken: reloadToken, in: webView)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        coordinator.webView = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadState: Binding<ArtifactPlayerLoadState>
        weak var webView: WKWebView?

        private var loadedURL: URL?
        private var loadedReloadToken: UUID?
        private var allowedDirectoryURL: URL?

        init(loadState: Binding<ArtifactPlayerLoadState>) {
            self.loadState = loadState
        }

        func load(url: URL, reloadToken: UUID, in webView: WKWebView) {
            self.webView = webView
            guard loadedURL != url || loadedReloadToken != reloadToken else { return }
            loadedURL = url
            loadedReloadToken = reloadToken
            allowedDirectoryURL = url.deletingLastPathComponent().appendingPathComponent("")
            webView.load(URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 30))
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            loadState.wrappedValue = .loading
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            loadState.wrappedValue = .ready
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            fail(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
            fail(error)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let destination = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(isAllowedNavigation(destination) ? .allow : .cancel)
        }

        private func isAllowedNavigation(_ destination: URL) -> Bool {
            if destination.absoluteString == "about:blank" { return true }
            guard let allowedDirectoryURL else { return false }
            return destination.scheme == allowedDirectoryURL.scheme
                && destination.host == allowedDirectoryURL.host
                && destination.port == allowedDirectoryURL.port
                && destination.path.hasPrefix(allowedDirectoryURL.path)
        }

        private func fail(_ error: Error) {
            let nsError = error as NSError
            guard nsError.code != NSURLErrorCancelled else { return }
            loadState.wrappedValue = .failed("The generated bundle could not be loaded. Check your connection and try again.")
        }
    }
}
