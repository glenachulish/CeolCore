import SwiftUI

// FONN-RESOURCES-2
// Links in Resources open inside Fonn, so you aren't taken away from the
// tune: Callum's request. iPhone/iPad: the in-app Safari sheet (reader view,
// your sign-ins, swipe down to come back). Mac: a window of Fonn's own, which
// can sit beside the music like an attachment window.

#if os(iOS)
import SafariServices

struct InAppSafari: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
#endif

/// A URL that can drive `.sheet(item:)`.
struct OpenedLink: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

extension View {
    /// Where a Resources link opens: in-app Safari on iOS, a Fonn window on
    /// the Mac. Anything not http(s) is handed to the system.
    func opensResourceLinks(_ opened: Binding<OpenedLink?>) -> some View {
        modifier(ResourceLinkOpening(opened: opened))
    }
}

private struct ResourceLinkOpening: ViewModifier {
    @Binding var opened: OpenedLink?
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .sheet(item: $opened) { link in
                InAppSafari(url: link.url).ignoresSafeArea()
            }
        #else
        content
            .onChange(of: opened?.id) {
                guard let link = opened else { return }
                openWindow(id: ResourceWebWindow.sceneID, value: link.url)
                opened = nil
            }
        #endif
    }
}

#if os(macOS)
import WebKit
import AppKit

/// A web page in a Fonn window (Mac). The Mac app declares the scene:
/// `WindowGroup(id: ResourceWebWindow.sceneID, for: URL.self)`.
public struct ResourceWebWindow: View {
    public static let sceneID = "resource-link"

    let url: URL
    @StateObject private var page = WebPage()

    public init(url: URL) { self.url = url }

    public var body: some View {
        WebPageView(page: page)
            .onAppear { page.load(url) }
            .navigationTitle(page.title.isEmpty ? (url.host ?? "Link") : page.title)
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button { page.view.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                        .disabled(!page.canGoBack)
                    Button { page.view.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                        .disabled(!page.canGoForward)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { page.view.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    Button {
                        NSWorkspace.shared.open(page.view.url ?? url)
                    } label: {
                        Label("Open in Browser", systemImage: "safari")
                    }
                    .help("Open in your web browser")
                }
            }
            .frame(minWidth: 520, minHeight: 420)
    }
}

/// Holds the web view so the toolbar can drive it, and publishes what the
/// toolbar shows.
@MainActor
final class WebPage: NSObject, ObservableObject, WKNavigationDelegate {
    let view: WKWebView
    @Published var title = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    private var observations: [NSKeyValueObservation] = []
    private var loaded = false

    override init() {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        view = WKWebView(frame: .zero, configuration: config)
        super.init()
        view.navigationDelegate = self
        view.allowsBackForwardNavigationGestures = true
        observations = [
            view.observe(\.title) { [weak self] v, _ in
                DispatchQueue.main.async { self?.title = v.title ?? "" }
            },
            view.observe(\.canGoBack) { [weak self] v, _ in
                DispatchQueue.main.async { self?.canGoBack = v.canGoBack }
            },
            view.observe(\.canGoForward) { [weak self] v, _ in
                DispatchQueue.main.async { self?.canGoForward = v.canGoForward }
            },
        ]
    }

    func load(_ url: URL) {
        guard !loaded else { return }
        loaded = true
        view.load(URLRequest(url: url))
    }

    /// Links that aren't web pages (mailto:, Music, Spotify) go to the system.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "blob", "data"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return .cancel
        }
        // A link that asks for a new window opens here instead of nowhere.
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
            return .cancel
        }
        return .allow
    }
}

private struct WebPageView: NSViewRepresentable {
    let page: WebPage
    func makeNSView(context: Context) -> WKWebView { page.view }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#endif
