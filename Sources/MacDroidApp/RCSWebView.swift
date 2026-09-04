import AppKit
import SwiftUI
import WebKit

struct RCSWebView: View {
    @State private var reloadID = UUID()
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let messagesURL = URL(string: "https://messages.google.com/web/authentication")!

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("RCS", systemImage: "message.badge.waveform.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.indigo)
                Text("Google Messages")
                    .foregroundStyle(.secondary)
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                }
                Button {
                    reloadID = UUID()
                } label: {
                    Label("Ladda om", systemImage: "arrow.clockwise")
                }
                Button {
                    NSWorkspace.shared.open(messagesURL)
                } label: {
                    Label("Öppna i Safari", systemImage: "safari")
                }
                Button(role: .destructive) {
                    clearWebsiteData()
                } label: {
                    Label("Rensa webbdata", systemImage: "trash")
                }
            }
            .padding(14)

            Divider()

            if let errorMessage {
                ContentUnavailableView {
                    Label("Google Messages kunde inte öppnas", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Försök igen") { reloadID = UUID() }
                    Button("Öppna i Safari") { NSWorkspace.shared.open(messagesURL) }
                }
            } else {
                RCSBrowserView(
                    url: messagesURL,
                    reloadID: reloadID,
                    isLoading: $isLoading,
                    errorMessage: $errorMessage
                )
            }
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    private func clearWebsiteData() {
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) {
            Task { @MainActor in reloadID = UUID() }
        }
    }
}

private struct RCSBrowserView: NSViewRepresentable {
    let url: URL
    let reloadID: UUID
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading, errorMessage: $errorMessage)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = true
        context.coordinator.loadedReloadID = reloadID
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedReloadID != reloadID else { return }
        context.coordinator.loadedReloadID = reloadID
        errorMessage = nil
        isLoading = true
        webView.reloadFromOrigin()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        @Binding private var isLoading: Bool
        @Binding private var errorMessage: String?
        var loadedReloadID: UUID?

        init(isLoading: Binding<Bool>, errorMessage: Binding<String?>) {
            _isLoading = isLoading
            _errorMessage = errorMessage
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            isLoading = true
            errorMessage = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            isLoading = false
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if Self.isAllowed(url) {
                decisionHandler(.allow)
            } else {
                if navigationAction.navigationType == .linkActivated {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
            }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation?,
            withError error: Error
        ) {
            if (error as NSError).code == NSURLErrorCancelled { return }
            isLoading = false
            errorMessage = error.localizedDescription
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation?,
            withError error: Error
        ) {
            if (error as NSError).code == NSURLErrorCancelled { return }
            isLoading = false
            errorMessage = error.localizedDescription
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url, Self.isAllowed(url) {
                webView.load(URLRequest(url: url))
            } else if let url = navigationAction.request.url,
                      navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
            }
            return nil
        }

        private static func isAllowed(_ url: URL) -> Bool {
            if url.scheme == "about" { return true }
            guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
            return allowedDomains.contains { host == $0 || host.hasSuffix(".\($0)") }
        }

        private static let allowedDomains = [
            "google.com",
            "gstatic.com",
            "googleusercontent.com"
        ]
    }
}
