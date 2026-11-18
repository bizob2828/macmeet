import AppKit
import Combine
import WebKit

/// Owns the single Meet web view and exposes app-level actions for menus and the toolbar.
@MainActor
final class MeetController: NSObject, ObservableObject {
  static let shared = MeetController()

  static let homeURL = URL(string: "https://meet.google.com/")!

  // Google refuses sign-in from user agents it identifies as embedded web views,
  // so present as desktop Safari.
  private static let userAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

  private static let meetingCodePattern = /^[a-z]{3}-[a-z]{4}-[a-z]{3}$/

  let webView: WKWebView

  @Published private(set) var title = "Google Meet"
  @Published private(set) var meetingCode: String?

  var isInCall: Bool { meetingCode != nil }

  var meetingLink: URL? {
    meetingCode.flatMap { URL(string: "https://meet.google.com/\($0)") }
  }

  private var observers: Set<AnyCancellable> = []
  private var lastShortcutTime: TimeInterval = 0

  override init() {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .default()
    config.mediaTypesRequiringUserActionForPlayback = []
    config.preferences.isElementFullscreenEnabled = true
    config.userContentController.addUserScript(NotificationBridge.userScript)
    config.userContentController.addUserScript(ScreenShareController.userScript)

    webView = WKWebView(frame: .zero, configuration: config)
    webView.customUserAgent = Self.userAgent
    webView.isInspectable = true

    super.init()

    webView.navigationDelegate = self
    webView.uiDelegate = self
    config.userContentController.add(NotificationBridge.shared, name: NotificationBridge.handlerName)
    config.userContentController.add(ScreenShareController.shared, name: ScreenShareController.handlerName)
    ScreenShareController.shared.webView = webView

    webView.publisher(for: \.title)
      .map { title in
        guard let title, !title.isEmpty else { return "Google Meet" }
        return title
      }
      .assign(to: &$title)

    webView.publisher(for: \.url)
      .map { url in Self.meetingCode(in: url) }
      .assign(to: &$meetingCode)

    webView.load(URLRequest(url: Self.homeURL))
  }

  // MARK: - Navigation

  func goHome() { webView.load(URLRequest(url: Self.homeURL)) }
  func newMeeting() { webView.load(URLRequest(url: URL(string: "https://meet.google.com/new")!)) }
  func reload() { webView.reload() }

  /// Navigating away from the meeting page disconnects the call and releases the camera and mic.
  func leaveMeeting() {
    if isInCall { goHome() }
  }

  /// Handles a URL handed to the app by another application: a Meet link
  /// (`https://meet.google.com/abc-defg-hij`), `macmeet://abc-defg-hij`, or `macmeet://new`.
  func open(_ url: URL) {
    if url.scheme == "macmeet" {
      if url.host() == "new" {
        newMeeting()
      } else {
        join(url.host() ?? "")
      }
      return
    }

    if Self.isMeetURL(url) {
      webView.load(URLRequest(url: url))
      return
    }

    // A link router may misroute a non-Meet link here. Hand it to the default browser unless
    // that's us, which would bounce it straight back.
    if let handler = NSWorkspace.shared.urlForApplication(toOpen: url),
       handler.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL {
      NSWorkspace.shared.open(url)
    } else {
      NSSound.beep()
    }
  }

  /// Joins a meeting from a bare code ("abc-defg-hij", "abcdefghij") or a full Meet link.
  func join(_ input: String) {
    guard let url = Self.meetingURL(from: input) else {
      NSSound.beep()
      return
    }
    webView.load(URLRequest(url: url))
  }

  func copyMeetingLink() {
    guard let meetingLink else {
      NSSound.beep()
      return
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(meetingLink.absoluteString, forType: .string)
  }

  // MARK: - In-call controls

  func toggleMicrophone() { sendMeetShortcut("d", keyCode: 2) }
  func toggleCamera() { sendMeetShortcut("e", keyCode: 14) }

  /// Replays Meet's own ⌘-shortcut into the web view as a native key event. When the web view
  /// doesn't consume a ⌘-key event, WebKit hands it back to the main menu, which would call us
  /// again; the debounce breaks that loop.
  private func sendMeetShortcut(_ characters: String, keyCode: UInt16) {
    let now = ProcessInfo.processInfo.systemUptime
    guard isInCall, now - lastShortcutTime > 0.5, let window = webView.window else { return }
    lastShortcutTime = now

    window.makeFirstResponder(webView)
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      guard let event = NSEvent.keyEvent(
        with: type,
        location: .zero,
        modifierFlags: .command,
        timestamp: now,
        windowNumber: window.windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
      ) else { continue }
      type == .keyDown ? webView.keyDown(with: event) : webView.keyUp(with: event)
    }
  }

  // MARK: - URL helpers

  static func isMeetURL(_ url: URL?) -> Bool {
    url?.host() == "meet.google.com"
  }

  static func isGoogleURL(_ url: URL?) -> Bool {
    guard let host = url?.host() else { return false }
    return [
      "google.com",
      "gstatic.com",
      "googleusercontent.com",
    ].contains { host == $0 || host.hasSuffix(".\($0)") }
  }

  private static func meetingCode(in url: URL?) -> String? {
    guard isMeetURL(url), let path = url?.path() else { return nil }
    let code = String(path.dropFirst())
    return code.wholeMatch(of: meetingCodePattern) != nil ? code : nil
  }

  static func meetingURL(from input: String) -> URL? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if let url = URL(string: trimmed), isMeetURL(url) { return url }
    if let url = URL(string: "https://\(trimmed)"), isMeetURL(url) { return url }

    var code = trimmed.lowercased().filter { $0.isLetter }
    guard code.count == 10 else { return nil }
    code.insert("-", at: code.index(code.startIndex, offsetBy: 3))
    code.insert("-", at: code.index(code.startIndex, offsetBy: 8))
    return URL(string: "https://meet.google.com/\(code)")
  }
}

// MARK: - WKNavigationDelegate

extension MeetController: WKNavigationDelegate {
  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
  ) {
    // Only user-clicked links leave the app. Redirects (e.g. a company SSO provider during
    // sign-in) must stay in the web view or the login flow breaks.
    let url = navigationAction.request.url
    if navigationAction.navigationType == .linkActivated,
       navigationAction.targetFrame?.isMainFrame ?? true,
       !Self.isGoogleURL(url),
       let url {
      NSWorkspace.shared.open(url)
      decisionHandler(.cancel)
      return
    }
    decisionHandler(.allow)
  }

  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    ScreenShareController.shared.pageDidNavigate()
  }
}

// MARK: - WKUIDelegate

extension MeetController: WKUIDelegate {
  func webView(
    _ webView: WKWebView,
    requestMediaCapturePermissionFor origin: WKSecurityOrigin,
    initiatedByFrame frame: WKFrameInfo,
    type: WKMediaCaptureType,
    decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
  ) {
    // macOS still gates the camera and mic behind its own system permission prompt.
    decisionHandler(origin.host == "meet.google.com" ? .grant : .prompt)
  }

  /// Handles `window.open` and `target="_blank"`: Meet links stay here, everything else goes to
  /// the default browser.
  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if let url = navigationAction.request.url {
      if Self.isMeetURL(url) {
        webView.load(navigationAction.request)
      } else {
        NSWorkspace.shared.open(url)
      }
    }
    return nil
  }

  func webView(
    _ webView: WKWebView,
    runJavaScriptAlertPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping @MainActor () -> Void
  ) {
    let alert = NSAlert()
    alert.messageText = message
    alert.runModal()
    completionHandler()
  }

  func webView(
    _ webView: WKWebView,
    runJavaScriptConfirmPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping @MainActor (Bool) -> Void
  ) {
    let alert = NSAlert()
    alert.messageText = message
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    completionHandler(alert.runModal() == .alertFirstButtonReturn)
  }

  func webView(
    _ webView: WKWebView,
    runOpenPanelWith parameters: WKOpenPanelParameters,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping @MainActor ([URL]?) -> Void
  ) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = parameters.allowsMultipleSelection
    panel.canChooseDirectories = parameters.allowsDirectories
    completionHandler(panel.runModal() == .OK ? panel.urls : nil)
  }
}
