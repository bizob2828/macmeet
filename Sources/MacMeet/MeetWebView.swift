import SwiftUI
import WebKit

/// Hosts the controller's long-lived web view so SwiftUI updates never recreate it.
struct MeetWebView: NSViewRepresentable {
  let webView: WKWebView

  func makeNSView(context: Context) -> WKWebView { webView }
  func updateNSView(_ nsView: WKWebView, context: Context) {}
}
