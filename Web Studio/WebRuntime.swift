import AppKit
import Combine
import SwiftUI
import WebKit

@MainActor private final class ResourceReadCompletion {
    struct Value {
        let text: String
        let truncated: Bool
    }
    private var continuation: CheckedContinuation<Result<Value, Error>, Never>?
    private var completed = false
    private var pending: Result<Value, Error>?
    func install(_ continuation: CheckedContinuation<Result<Value, Error>, Never>) {
        if let pending { continuation.resume(returning: pending); self.pending = nil } else { self.continuation = continuation }
    }
    func resolve(_ result: Result<Value, Error>) {
        guard !completed else { return }; completed = true
        if let continuation { continuation.resume(returning: result); self.continuation = nil } else { pending = result }
    }
}

/// Snapshot of a tab's live WKWebView navigation state. The web view itself stays the
/// source of truth; this struct is the only thing the SwiftUI shell reads.
struct WebNavigationState: Equatable {
    var url: URL?
    var pageTitle: String?
    var isLoading = false
    var progress: Double = 0
    var canGoBack = false
    var canGoForward = false
    var failure: WebNavigationFailure?
}

struct WebNavigationFailure: Equatable {
    let url: URL?
    let message: String
}

// MARK: - Per-tab runtime

/// Owns one `WKWebView` for the lifetime of one web tab, so back/forward history and
/// scroll position survive tab switching. Created and released by `WebRuntimeStore`.
@MainActor final class WebTabRuntime: NSObject, ObservableObject {
    /// Mutating `state` republishes to the tab view and forwards to the shell toolbar.
    @Published private(set) var state = WebNavigationState() {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    /// A small, transient rendering of the current page used only behind the native
    /// toolbar. It is deliberately kept on the runtime so a view switch cannot attach
    /// an older tab's image to the active shell.
    @Published private(set) var chromeSnapshot: NSImage?

    let webView: WKWebView

    /// Called when a committed navigation moves the tab off its stored destination, so
    /// the toolbar and tab title follow the page the user actually landed on.
    var onCommit: ((URL) -> Void)?
    /// Called for `target="_blank"` and window.open, which open a sibling studio tab
    /// instead of a detached window.
    var onOpenInNewTab: ((URL) -> Void)?
    var onStateChange: ((WebNavigationState) -> Void)?

    /// The destination this runtime has been asked to show. Tracked separately from
    /// `webView.url` so re-showing a tab never re-loads a page the user navigated away from.
    let resourceID: UUID
    private var requestedURL: URL?
    private var navigationGeneration = 0
    private var chromeCaptureInFlight = false
    private var observers: Set<AnyCancellable> = []

    init(resourceID: UUID = UUID()) {
        self.resourceID = resourceID
        webView = WKWebView(frame: .zero, configuration: Self.makeConfiguration())
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        observe()
    }

    nonisolated static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        // Shared default store: cookies and local storage persist across tabs and launches.
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.upgradeKnownHostsToHTTPS = true
        // No autoplay: a workspace shell should not make noise on tab open.
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        // The engine genuinely is Safari's WebKit; the Safari token keeps site gating honest.
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15 WebStudio/1.0"
        return configuration
    }

    private func observe() {
        webView.publisher(for: \.url)
            .sink { [weak self] value in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.state.url = value
                    self.acceptObservedURL(value, committed: false)
                }
            }
            .store(in: &observers)
        webView.publisher(for: \.title)
            .sink { [weak self] value in
                MainActor.assumeIsolated {
                    let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                    self?.state.pageTitle = (clean?.isEmpty ?? true) ? nil : clean
                }
            }
            .store(in: &observers)
        webView.publisher(for: \.isLoading)
            .sink { [weak self] value in MainActor.assumeIsolated { self?.state.isLoading = value } }
            .store(in: &observers)
        webView.publisher(for: \.estimatedProgress)
            .sink { [weak self] value in MainActor.assumeIsolated { self?.state.progress = value } }
            .store(in: &observers)
        webView.publisher(for: \.canGoBack)
            .sink { [weak self] value in MainActor.assumeIsolated { self?.state.canGoBack = value } }
            .store(in: &observers)
        webView.publisher(for: \.canGoForward)
            .sink { [weak self] value in MainActor.assumeIsolated { self?.state.canGoForward = value } }
            .store(in: &observers)
    }

    // MARK: Navigation commands

    /// Loads `url` only when it differs from what this runtime was last asked to show.
    func load(_ url: URL) {
        guard requestedURL != url else { return }
        navigationGeneration += 1
        chromeSnapshot = nil
        requestedURL = url
        state.failure = nil
        webView.load(URLRequest(url: url))
    }

    func goBack() {
        state.failure = nil
        webView.goBack()
    }

    func goForward() {
        state.failure = nil
        webView.goForward()
    }

    func reload() {
        state.failure = nil
        if webView.url == nil, let requestedURL {
            webView.load(URLRequest(url: requestedURL))
        } else {
            webView.reload()
        }
    }

    func stop() {
        webView.stopLoading()
    }

    func teardown() {
        navigationGeneration += 1
        chromeSnapshot = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        observers.removeAll()
        onCommit = nil
        onOpenInNewTab = nil
        onStateChange = nil
    }

    /// Captures only the visible top strip of the live page. The caller owns throttling
    /// and visibility; the generation check here prevents a late WebKit completion from
    /// painting a snapshot belonging to a previous navigation.
    func capturePageChromeSnapshot() async {
        guard !Task.isCancelled, state.failure == nil, !state.isLoading,
              !chromeCaptureInFlight, NSApp.isActive, webView.window?.isKeyWindow == true,
              webView.bounds.width > 0, webView.bounds.height > 0
        else { return }
        chromeCaptureInFlight = true
        defer { chromeCaptureInFlight = false }
        let generation = navigationGeneration
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        configuration.rect = CGRect(x: 0, y: 0, width: webView.bounds.width,
                                    height: min(webView.bounds.height, 120))
        configuration.snapshotWidth = 512
        let image: NSImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, _ in continuation.resume(returning: image) }
        }
        guard !Task.isCancelled, generation == navigationGeneration,
              state.failure == nil, !state.isLoading, let image
        else {
            if generation == navigationGeneration { chromeSnapshot = nil }
            return
        }
        guard NSApp.isActive, webView.window?.isKeyWindow == true else {
            chromeSnapshot = nil
            return
        }
        chromeSnapshot = image
    }

    func clearChromeSnapshot() { chromeSnapshot = nil }

    /// Reads only bounded page text from this web session. The generation guard prevents
    /// a result from an earlier navigation being presented as the current page.
    func readSnapshot(resourceID: UUID, maxCharacters: Int = 12_000) async -> ResourceSnapshot {
        let limit = min(max(0, maxCharacters), 12_000)
        let generation = navigationGeneration
        let url = webView.url ?? requestedURL
        guard let url else { return .failure(resourceID: resourceID, message: "Page is unavailable.") }
        guard state.failure == nil else { return .failure(resourceID: resourceID, message: state.failure?.message ?? "Page failed to load.", url: url) }
        let completion = ResourceReadCompletion()
        let result: Result<ResourceReadCompletion.Value, Error> = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                completion.install(continuation)
                let timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { return }
                    await MainActor.run { _ = self; completion.resolve(.failure(NSError(domain: "WebStudioRead", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out reading page."]))) }
                }
                Task { @MainActor in
                    do {
                        let value = try await self.webView.evaluateJavaScript("(() => { const text = document.body?.innerText ?? ''; const s = typeof Intl !== 'undefined' && Intl.Segmenter ? new Intl.Segmenter(undefined, {granularity:'grapheme'}).segment(text) : Array.from(text, segment => ({segment})); let out = ''; let count = 0; for (const part of s) { if (count >= \(limit + 1)) break; out += part.segment; count++; } return JSON.stringify({text: out, truncated: count > \(limit) || out.length < text.length}); })()", in: nil, contentWorld: .defaultClient)
                        guard let json = value as? String,
                              let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                              let text = object["text"] as? String,
                              let truncated = object["truncated"] as? Bool
                        else {
                            throw NSError(domain: "WebStudioRead", code: 2, userInfo: [NSLocalizedDescriptionKey: "Page returned an invalid text snapshot."])
                        }
                        timeout.cancel(); completion.resolve(.success(.init(text: text, truncated: truncated)))
                    } catch {
                        timeout.cancel(); completion.resolve(.failure(error))
                    }
                }
            }
        }, onCancel: {
            Task { @MainActor in completion.resolve(.failure(CancellationError())) }
        })
        guard generation == navigationGeneration, webView.url == url else {
            return .failure(resourceID: resourceID, message: "Page navigated while it was being read.", url: url)
        }
        switch result {
        case let .failure(error):
            let message = error is CancellationError ? "Page read was cancelled." : error.localizedDescription
            return .failure(resourceID: resourceID, message: message, url: url)
        case let .success(value):
            let text = value.text
            let bounded = String(text.prefix(limit))
            return ResourceSnapshot(resourceID: resourceID, collectedAt: Date(), text: bounded,
                isTruncated: value.truncated || bounded.count < text.count, errorMessage: nil, sourceURL: url,
                title: webView.title, range: 0..<bounded.count)
    }

    }

    private func acceptObservedURL(_ url: URL?, committed: Bool) {
        guard let url, requestedURL != url else { return }
        guard committed || (!webView.isLoading && state.failure == nil) else { return }
        requestedURL = url
        navigationGeneration += 1
        state.failure = nil
        onCommit?(url)
    }

    // MARK: Policy, testable in isolation

    enum NavigationRoute: Equatable {
        /// Render in this tab.
        case allow
        /// Refuse without surfacing an error.
        case cancel
        /// Hand to the system handler for that scheme.
        case openExternally
    }

    /// Schemes worth handing to another app, and only from a link the user clicked.
    nonisolated static let handoffSchemes: Set<String> = [
        "mailto", "tel", "sms", "facetime", "facetime-audio", "webcal",
    ]

    nonisolated static func route(for url: URL, isLinkActivation: Bool) -> NavigationRoute {
        guard let scheme = url.scheme?.lowercased() else { return .cancel }
        if ["http", "https", "about", "blob"].contains(scheme) { return .allow }
        guard isLinkActivation, handoffSchemes.contains(scheme) else { return .cancel }
        return .openExternally
    }

    /// Cancelled and interrupted loads are the normal cost of fast navigation, not failures
    /// worth putting on screen.
    nonisolated static func failure(for error: Error, url: URL?) -> WebNavigationFailure? {
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return nil }
        if error.domain == "WebKitErrorDomain", error.code == 102 { return nil }
        return WebNavigationFailure(url: url, message: error.localizedDescription)
    }
}

// MARK: - Navigation delegate

extension WebTabRuntime: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            navigationGeneration += 1
            chromeSnapshot = nil
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        MainActor.assumeIsolated {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            switch Self.route(
                for: url,
                isLinkActivation: navigationAction.navigationType == .linkActivated
            ) {
            case .allow:
                decisionHandler(.allow)
            case .cancel:
                decisionHandler(.cancel)
            case .openExternally:
                decisionHandler(.cancel)
                NSWorkspace.shared.open(url)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            state.failure = nil
            acceptObservedURL(webView.url, committed: true)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            acceptObservedURL(webView.url, committed: true)
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        MainActor.assumeIsolated { record(error) }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        MainActor.assumeIsolated { record(error) }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            chromeSnapshot = nil
            state.failure = WebNavigationFailure(
                url: requestedURL,
                message: "The page stopped responding and was closed."
            )
        }
    }

    private func record(_ error: Error) {
        chromeSnapshot = nil
        guard let failure = Self.failure(for: error, url: requestedURL) else { return }
        state.failure = failure
    }
}

// MARK: - UI delegate

extension WebTabRuntime: WKUIDelegate {
    nonisolated func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        MainActor.assumeIsolated {
            if let url = navigationAction.request.url,
               Self.route(for: url, isLinkActivation: true) == .allow
            {
                onOpenInNewTab?(url)
            }
            return nil
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        MainActor.assumeIsolated {
            let alert = Self.makeAlert(message: message, origin: frame)
            alert.addButton(withTitle: "OK")
            present(alert) { _ in completionHandler() }
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        MainActor.assumeIsolated {
            let alert = Self.makeAlert(message: message, origin: frame)
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            present(alert) { completionHandler($0 == .alertFirstButtonReturn) }
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        MainActor.assumeIsolated {
            let alert = Self.makeAlert(message: prompt, origin: frame)
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
            field.stringValue = defaultText ?? ""
            alert.accessoryView = field
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            present(alert) { response in
                completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
            }
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        MainActor.assumeIsolated {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            guard let window = webView.window else {
                completionHandler(panel.runModal() == .OK ? panel.urls : nil)
                return
            }
            panel.beginSheetModal(for: window) { response in
                completionHandler(response == .OK ? panel.urls : nil)
            }
        }
    }

    /// The requesting origin is named so a dialog cannot impersonate the app itself.
    private nonisolated static func makeAlert(message: String, origin: WKFrameInfo) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = origin.request.url?.host ?? "This page"
        alert.informativeText = message
        return alert
    }

    private func present(
        _ alert: NSAlert,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        guard let window = webView.window else {
            completion(alert.runModal())
            return
        }
        alert.beginSheetModal(for: window, completionHandler: completion)
    }
}

// MARK: - Runtime store

// MARK: - Views

/// Hosts the tab's persistent `WKWebView`. Identity is supplied by the caller via `.id`,
/// which is what keeps one web view per tab instead of one per visible slot.
private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> NativeResourceContainer {
        let container = NativeResourceContainer(); container.mount(webView); return container
    }
    func updateNSView(_ nsView: NativeResourceContainer, context: Context) {
        nsView.mount(webView)
    }
    static func dismantleNSView(_ nsView: NativeResourceContainer, coordinator: ()) { nsView.unmount() }
}

struct WebTabView: View {
    @ObservedObject var runtime: WebTabRuntime
    let url: URL

    var body: some View {
        ZStack(alignment: .top) {
            WebViewHost(webView: runtime.webView)
                .accessibilityIdentifier("web.runtime")
                .accessibilityLabel(runtime.state.pageTitle ?? url.absoluteString)
            if runtime.state.isLoading, runtime.state.progress < 1 {
                ProgressView(value: runtime.state.progress)
                    .progressViewStyle(.linear)
                    .accessibilityIdentifier("web.progress")
                    .accessibilityLabel("Loading page")
            }
            if let failure = runtime.state.failure {
                WebFailureView(failure: failure) { runtime.reload() }
            }
        }
        .onAppear { runtime.load(url) }
        .onChange(of: url) { _, newValue in runtime.load(newValue) }
    }
}

/// Load failures keep the destination in the tab and offer the one correction that helps.
private struct WebFailureView: View {
    let failure: WebNavigationFailure
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("This page did not load")
                .font(.title3.weight(.semibold))
            Text(failure.message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let url = failure.url {
                Text(url.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: 380)
            }
            Button("Reload", action: retry)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("web.reload")
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityIdentifier("web.error")
    }
}
