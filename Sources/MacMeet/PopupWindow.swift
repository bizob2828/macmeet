import AppKit
import WebKit

/// A window for a page Meet opens with `window.open` and then fills in itself, such as a
/// presentation popped out into its own window. Such a page starts at `about:blank`, so it can't be
/// handed to a browser; it has to share the opener's web process, which WebKit arranges when the
/// web view is built from the configuration it passes to `createWebViewWith`.
@MainActor
final class PopupWindow: NSObject {
  private static var open: Set<PopupWindow> = []

  private let window: NSWindow
  let webView: WKWebView

  /// Opens a window for the page and returns its web view for WebKit to load into.
  static func show(configuration: WKWebViewConfiguration, features: WKWindowFeatures) -> WKWebView {
    let popup = PopupWindow(configuration: configuration, features: features)
    open.insert(popup)
    NSApp.activate()
    popup.window.makeKeyAndOrderFront(nil)
    return popup.webView
  }

  private init(configuration: WKWebViewConfiguration, features: WKWindowFeatures) {
    let size = NSSize(
      width: features.width?.doubleValue ?? 960,
      height: features.height?.doubleValue ?? 600
    )
    webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
    webView.isInspectable = true
    window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [
        .titled,
        .closable,
        .miniaturizable,
        .resizable,
      ],
      backing: .buffered,
      defer: false
    )
    super.init()

    webView.uiDelegate = self
    window.contentView = webView
    window.title = "Google Meet"
    window.tabbingMode = .disallowed
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.center()

    titleObservation = webView.observe(\.title) { [weak self] webView, _ in
      MainActor.assumeIsolated {
        guard let title = webView.title, !title.isEmpty else { return }
        self?.window.title = title
      }
    }
  }

  private var titleObservation: NSKeyValueObservation?
}

extension PopupWindow: WKUIDelegate {
  /// The page called `window.close()`, which Meet does when the presentation ends.
  func webViewDidClose(_ webView: WKWebView) {
    window.close()
  }
}

extension PopupWindow: NSWindowDelegate {
  func windowWillClose(_ notification: Notification) {
    titleObservation = nil
    Self.open.remove(self)
  }
}
