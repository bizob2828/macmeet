import AppKit
import UserNotifications
import WebKit

/// WKWebView has no Web Notifications support, so a shim replaces `window.Notification` and
/// forwards each notification to macOS Notification Center.
@MainActor
final class NotificationBridge: NSObject, WKScriptMessageHandler {
  static let shared = NotificationBridge()
  static let handlerName = "macmeetNotify"

  static let userScript = WKUserScript(
    source: """
    (() => {
      const post = (payload) => window.webkit.messageHandlers.\(handlerName).postMessage(payload);
      class MacMeetNotification extends EventTarget {
        static get permission() { return 'granted'; }
        static requestPermission(callback) {
          if (callback) callback('granted');
          return Promise.resolve('granted');
        }
        constructor(title, options = {}) {
          super();
          this.title = String(title);
          this.body = options.body ? String(options.body) : '';
          this.tag = options.tag ? String(options.tag) : '';
          this.onclick = null;
          this.onclose = null;
          post({ title: this.title, body: this.body, tag: this.tag });
        }
        close() {}
      }
      window.Notification = MacMeetNotification;
    })();
    """,
    injectionTime: .atDocumentStart,
    forMainFrameOnly: true
  )

  static func requestAuthorization() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    // The page notifies freely; only surface it when the user isn't already looking at the app.
    guard !NSApp.isActive,
          let payload = message.body as? [String: Any],
          let title = payload["title"] as? String else { return }

    let content = UNMutableNotificationContent()
    content.title = title
    content.body = payload["body"] as? String ?? ""
    content.sound = .default

    let tag = payload["tag"] as? String ?? ""
    let request = UNNotificationRequest(
      identifier: tag.isEmpty ? UUID().uuidString : tag,
      content: content,
      trigger: nil
    )
    UNUserNotificationCenter.current().add(request)
  }
}
