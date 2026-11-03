import SwiftUI
import WebKit

/// The World Manager, in a web view.
///
/// admin.py is already a complete game editor -- give items and candy, set XP
/// and level, place stops and gyms, edit loot tables, run raids, manage
/// accounts. It just never started inside the launcher, because run.py was the
/// only thing that called admin.start(). ws_boot starts it now on
/// prefs.gameEditorPort and this wraps it, rather than reimplementing any of it
/// in SwiftUI and then having two versions to keep in step.
struct GameEditorView: View {
    let port: UInt16
    @Environment(\.dismiss) private var dismiss
    @State private var reloadToken = 0

    var body: some View {
        NavigationStack {
            WebView(url: url, reloadToken: reloadToken)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Game Editor")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            reloadToken += 1
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
        }
    }

    private var url: URL {
        URL(string: "http://127.0.0.1:\(port)/")!
    }
}

private struct WebView: UIViewRepresentable {
    let url: URL
    let reloadToken: Int

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // The editor posts JSON to its own origin; nothing here needs to
        // persist between sessions.
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        // Only act on an explicit tap of the reload button -- SwiftUI calls
        // this for unrelated state changes too, and reloading on each one
        // would throw away whatever the user had typed into a field.
        guard context.coordinator.lastToken != reloadToken else { return }
        context.coordinator.lastToken = reloadToken
        view.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator { Coordinator(token: reloadToken) }

    final class Coordinator {
        var lastToken: Int
        init(token: Int) { lastToken = token }
    }
}
