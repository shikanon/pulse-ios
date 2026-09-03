import Foundation
import SwiftUI
import WebKit

struct ArtifactPlayerView: View {
    let url: URL
    let isActive: Bool
    let title: String
    let interactionSummary: String
    let accessibilityIdentifier: String
    let telemetryScreen: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(PulseTelemetry.self) private var telemetry
    @State private var loadState: ArtifactPlayerLoadState = .loading
    @State private var reloadToken = UUID()

    init(
        url: URL,
        isActive: Bool,
        title: String,
        interactionSummary: String,
        accessibilityIdentifier: String,
        telemetryScreen: String = "unknown"
    ) {
        self.url = url
        self.isActive = isActive
        self.title = title
        self.interactionSummary = interactionSummary
        self.accessibilityIdentifier = accessibilityIdentifier
        self.telemetryScreen = telemetryScreen
    }

    var body: some View {
        ZStack {
            ArtifactStaticPreview(title: title, theme: interactionSummary)

            ArtifactWebView(
                url: url,
                isActive: isActive,
                reduceMotion: reduceMotion,
                title: title,
                interactionSummary: interactionSummary,
                reloadToken: reloadToken,
                loadState: $loadState,
                accessibilityIdentifier: accessibilityIdentifier
            )
            .opacity(loadState == .ready ? 1 : 0)

            if reduceMotion, loadState == .ready {
                Label("Motion paused", systemImage: "figure.walk.motion")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.82), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(14)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Motion paused. This interactive app honors Reduce Motion. Available controls remain usable.")
                    .accessibilitySortPriority(3)
            }

            if loadState == .loading {
                ProgressView("Loading interactive app…")
                    .tint(.pulseLime)
                    .foregroundStyle(.white)
                    .padding(16)
                    .background(.black.opacity(0.72), in: Capsule())
                    .accessibilityIdentifier("artifact.player.loading")
            } else if case let .failed(unavailable) = loadState {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.pulseCoral)
                    Text(unavailable.title)
                        .font(.headline)
                    Text(unavailable.detail)
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
                    Text("A static preview is shown while the interactive version is unavailable. You can keep browsing other works.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(22)
                .accessibilityIdentifier("artifact.player.error")
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(unavailable.title). \(unavailable.detail)")
            }
        }
        .onChange(of: loadState) { _, currentState in
            guard case let .failed(unavailable) = currentState else { return }
            telemetry.record(.artifactLoadFailed, attributes: ["screen_id": telemetryScreen, "error_category": unavailable.telemetryCategory])
        }
    }
}

private struct ArtifactStaticPreview: View {
    let title: String
    let theme: String

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.pulseViolet.opacity(0.78), Color.black, Color.pulseLime.opacity(0.20)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(Color.pulseLime.opacity(0.18))
                .frame(width: 260, height: 260)
                .blur(radius: 28)
                .offset(x: 105, y: -180)
            Circle()
                .fill(Color.pulseCoral.opacity(0.16))
                .frame(width: 220, height: 220)
                .blur(radius: 32)
                .offset(x: -110, y: 195)
            VStack(spacing: 11) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Color.pulseLime)
                Text(title)
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Text(theme)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .padding(28)
        }
        .background(.black)
        .accessibilityHidden(true)
    }
}

private enum ArtifactPlayerLoadState: Equatable {
    case loading
    case ready
    case failed(ArtifactUnavailable)
}

private struct ArtifactWebView: UIViewRepresentable {
    let url: URL
    let isActive: Bool
    let reduceMotion: Bool
    let title: String
    let interactionSummary: String
    let reloadToken: UUID
    @Binding var loadState: ArtifactPlayerLoadState
    let accessibilityIdentifier: String

    func makeCoordinator() -> Coordinator {
        Coordinator(loadState: $loadState)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(context.coordinator.schemeHandler, forURLScheme: ArtifactRuntimeSource.scheme)
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
        webView.accessibilityLabel = PulseAccessibility.interactiveSummary(title: title, theme: interactionSummary)
        webView.accessibilityHint = "Use the interactive controls provided by this app. Reduce Motion pauses non-essential animation."
        context.coordinator.load(url: url, reloadToken: reloadToken, in: webView)
        context.coordinator.setRuntimeMotion(isActive: isActive, reduceMotion: reduceMotion, in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.loadState = $loadState
        context.coordinator.load(url: url, reloadToken: reloadToken, in: webView)
        webView.accessibilityLabel = PulseAccessibility.interactiveSummary(title: title, theme: interactionSummary)
        context.coordinator.setRuntimeMotion(isActive: isActive, reduceMotion: reduceMotion, in: webView)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stopRuntime(in: webView)
        webView.navigationDelegate = nil
        coordinator.webView = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadState: Binding<ArtifactPlayerLoadState>
        weak var webView: WKWebView?
        let schemeHandler = ArtifactSchemeHandler()

        private var loadedURL: URL?
        private var loadedReloadToken: UUID?
        private var runtimeSource: ArtifactRuntimeSource?
        private var motionState: PulseRuntimeMotionState = .pausedForInactiveSurface

        init(loadState: Binding<ArtifactPlayerLoadState>) {
            self.loadState = loadState
        }

        func load(url: URL, reloadToken: UUID, in webView: WKWebView) {
            self.webView = webView
            guard loadedURL != url || loadedReloadToken != reloadToken else { return }
            loadedURL = url
            loadedReloadToken = reloadToken
            guard let source = ArtifactRuntimeSource(apiEntryURL: url) else {
                loadState.wrappedValue = .failed(.unavailable)
                return
            }
            runtimeSource = source
            schemeHandler.configure(source)
            webView.load(URLRequest(url: source.entryURL, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 30))
        }

        func setRuntimeMotion(isActive: Bool, reduceMotion: Bool, in webView: WKWebView) {
            let nextState = PulseAccessibility.runtimeMotionState(isActive: isActive, reduceMotion: reduceMotion)
            guard motionState != nextState else { return }
            motionState = nextState
            applyRuntimeMotion(in: webView)
        }

        private func applyRuntimeMotion(in webView: WKWebView) {
            webView.evaluateJavaScript(PulseAccessibility.runtimeScript(for: motionState))
        }

        func stopRuntime(in webView: WKWebView) {
            motionState = .pausedForInactiveSurface
            applyRuntimeMotion(in: webView)
            webView.stopLoading()
            schemeHandler.cancelRequests()
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            loadState.wrappedValue = .loading
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            loadState.wrappedValue = .ready
            applyRuntimeMotion(in: webView)
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
            guard let runtimeSource else { return false }
            return runtimeSource.allows(destination)
        }

        private func fail(_ error: Error) {
            let nsError = error as NSError
            guard nsError.code != NSURLErrorCancelled else { return }
            loadState.wrappedValue = .failed(ArtifactUnavailable(error: error))
        }
    }
}

// Generated bundles are untrusted. Loading them through a private custom URL
// scheme lets native code attach a bearer token for a draft artifact without
// placing that token in the document URL, Cookie jar, window object, or bridge.
// The handler accepts only files beneath the one artifact supplied by Pulse.
struct ArtifactRuntimeSource: Sendable {
    static let scheme = "pulse-artifact"

    let artifactID: String
    let apiOrigin: URL
    let filePathPrefix: String
    let entryURL: URL

    init?(apiEntryURL: URL) {
        let components = apiEntryURL.path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 5,
              components[0] == "v1",
              components[1] == "artifacts",
              components[3] == "files",
              (apiEntryURL.scheme?.lowercased() == "https" || ((apiEntryURL.scheme?.lowercased() == "http") && (apiEntryURL.host == "localhost" || apiEntryURL.host == "127.0.0.1")))
        else { return nil }
        let id = String(components[2])
        let entryPath = components.dropFirst(4).joined(separator: "/")
        guard !id.isEmpty, !entryPath.isEmpty else { return nil }

        var origin = URLComponents(url: apiEntryURL, resolvingAgainstBaseURL: false)
        origin?.path = "/"
        origin?.query = nil
        origin?.fragment = nil
        guard let apiOrigin = origin?.url,
              let entryURL = URL(string: "\(Self.scheme)://\(id)/\(entryPath)")
        else { return nil }

        artifactID = id
        self.apiOrigin = apiOrigin
        filePathPrefix = "/v1/artifacts/\(id)/files/"
        self.entryURL = entryURL
    }

    func allows(_ url: URL) -> Bool {
        url.scheme == Self.scheme && url.host == artifactID && apiURL(for: url) != nil
    }

    func apiURL(for runtimeURL: URL) -> URL? {
        guard runtimeURL.scheme == Self.scheme, runtimeURL.host == artifactID,
              runtimeURL.query == nil, runtimeURL.fragment == nil
        else { return nil }
        let segments = runtimeURL.path.split(separator: "/", omittingEmptySubsequences: true)
        guard !segments.isEmpty,
              segments.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("\\") })
        else { return nil }
        var components = URLComponents(url: apiOrigin, resolvingAgainstBaseURL: false)
        components?.path = filePathPrefix + segments.joined(separator: "/")
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }
}

private final class ArtifactSchemeHandler: NSObject, WKURLSchemeHandler {
    private var source: ArtifactRuntimeSource?
    private let requestLock = NSLock()
    private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]

    func configure(_ source: ArtifactRuntimeSource) {
        cancelRequests()
        self.source = source
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let source,
              let runtimeURL = urlSchemeTask.request.url,
              let apiURL = source.apiURL(for: runtimeURL)
        else {
            urlSchemeTask.didFailWithError(NSError(domain: "Pulse.Artifact", code: 1))
            return
        }

        let identifier = ObjectIdentifier(urlSchemeTask as AnyObject)
        let requestTask = Task { @MainActor [weak self] in
            defer { self?.removeRequest(identifier) }
            do {
                guard !Task.isCancelled else { return }
                var request = URLRequest(url: apiURL, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 30)
                request.httpMethod = "GET"
                request.setValue("*/*", forHTTPHeaderField: "Accept")
                PulseClientRuntimeDeclaration.apply(to: &request)
                PulseLocalTestIdentity.apply(to: &request, apiURL: apiURL)
                if let session = PulseCredentialStore.load() {
                    request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
                }
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    let serverCode = try? JSONDecoder().decode(ArtifactErrorEnvelope.self, from: data).error.code
                    throw PulseAPIError(serverCode: serverCode, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
                }
                let proxiedResponse = HTTPURLResponse(
                    url: runtimeURL,
                    statusCode: http.statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: http.allHeaderFields.reduce(into: [String: String]()) { result, item in
                        if let key = item.key as? String, let value = item.value as? String {
                            result[key] = value
                        }
                    }
                ) ?? response
                guard !Task.isCancelled else { return }
                urlSchemeTask.didReceive(proxiedResponse)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch {
                guard !Task.isCancelled else { return }
                urlSchemeTask.didFailWithError(error)
            }
        }
        requestLock.lock()
        requests[identifier] = requestTask
        requestLock.unlock()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        cancelRequest(ObjectIdentifier(urlSchemeTask as AnyObject))
    }

    func cancelRequests() {
        requestLock.lock()
        let activeRequests = requests.values
        requests.removeAll()
        requestLock.unlock()
        activeRequests.forEach { $0.cancel() }
    }

    private func cancelRequest(_ identifier: ObjectIdentifier) {
        requestLock.lock()
        let task = requests.removeValue(forKey: identifier)
        requestLock.unlock()
        task?.cancel()
    }

    private func removeRequest(_ identifier: ObjectIdentifier) {
        requestLock.lock()
        requests.removeValue(forKey: identifier)
        requestLock.unlock()
    }

}

private struct ArtifactErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let code: String
    }

    let error: APIError
}
