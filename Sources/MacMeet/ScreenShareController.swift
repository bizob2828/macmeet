import AppKit
import ScreenCaptureKit
import WebKit

/// Screen sharing for Meet.
///
/// WKWebView's own `getDisplayMedia` never completes in a third-party app: WebKit accepts the
/// request but neither its ScreenCaptureKit picker nor its older prompt ever appears. Instead, a
/// page script replaces `getDisplayMedia`, MacMeet shows its own picker, captures with
/// ScreenCaptureKit, and streams JPEG frames into a canvas whose video track goes to Meet.
@MainActor
final class ScreenShareController: NSObject, ObservableObject, WKScriptMessageHandler {
  static let shared = ScreenShareController()
  static let handlerName = "macmeetScreenShare"

  struct Source: Identifiable {
    enum Content {
      case display(SCDisplay)
      case window(SCWindow)
    }

    let id: String
    let title: String
    let subtitle: String
    let icon: NSImage?
    let content: Content
  }

  struct PickerRequest: Identifiable {
    let id = UUID()
    let displays: [Source]
    let windows: [Source]
    let frameRate: Int
  }

  @Published private(set) var pickerRequest: PickerRequest?

  weak var webView: WKWebView?
  private var session: ScreenCaptureSession?

  // MARK: - Page script

  static let userScript = WKUserScript(
    source: """
    (() => {
      const post = (message) => window.webkit.messageHandlers.\(handlerName).postMessage(message);
      let pending = null;
      let session = null;

      const requestedFrameRate = (constraints) => {
        const rate = constraints && typeof constraints.video === 'object' ? constraints.video.frameRate : null;
        if (typeof rate === 'number') return rate;
        if (rate && typeof rate === 'object') return rate.ideal || rate.max || rate.exact || 15;
        return 15;
      };

      const endSession = () => {
        if (!session) return null;
        const ended = session;
        session = null;
        ended.stopTrack();
        return ended;
      };

      MediaDevices.prototype.getDisplayMedia = function (constraints) {
        return new Promise((resolve, reject) => {
          if (pending) {
            reject(new DOMException('A screen share request is already in progress.', 'InvalidStateError'));
            return;
          }
          pending = { resolve, reject };
          post({ type: 'request', frameRate: requestedFrameRate(constraints) });
        });
      };

      window.__macmeetScreenShare = {
        started({ width, height, surface, label }) {
          if (!pending) { post({ type: 'stop' }); return; }
          endSession();

          const canvas = document.createElement('canvas');
          canvas.width = width;
          canvas.height = height;
          const context = canvas.getContext('2d');
          const stream = canvas.captureStream();
          const track = stream.getVideoTracks()[0];

          const stopTrack = track.stop.bind(track);
          const getSettings = track.getSettings.bind(track);
          track.stop = () => {
            stopTrack();
            if (session && session.track === track) {
              session = null;
              post({ type: 'stop' });
            }
          };
          track.getSettings = () => ({ ...getSettings(), displaySurface: surface, width: canvas.width, height: canvas.height });
          Object.defineProperty(track, 'label', { value: label });

          session = { canvas, context, track, stopTrack };
          pending.resolve(stream);
          pending = null;
        },

        async frame(base64) {
          const current = session;
          if (!current) return;
          const bytes = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
          const bitmap = await createImageBitmap(new Blob([bytes], { type: 'image/jpeg' }));
          if (session === current) {
            if (current.canvas.width !== bitmap.width || current.canvas.height !== bitmap.height) {
              current.canvas.width = bitmap.width;
              current.canvas.height = bitmap.height;
            }
            current.context.drawImage(bitmap, 0, 0);
          }
          bitmap.close();
        },

        failed(name, message) {
          if (!pending) return;
          pending.reject(new DOMException(message, name));
          pending = null;
        },

        ended() {
          const ended = endSession();
          if (ended) ended.track.dispatchEvent(new Event('ended'));
        },
      };
    })();
    """,
    injectionTime: .atDocumentStart,
    forMainFrameOnly: true
  )

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
    switch type {
    case "request":
      let frameRate = (body["frameRate"] as? NSNumber)?.intValue ?? 15
      Task { await showPicker(frameRate: min(max(frameRate, 1), 30)) }
    case "stop":
      stopCapture(notifyPage: false)
    default:
      break
    }
  }

  // MARK: - Picker

  private func showPicker(frameRate: Int) async {
    guard CGPreflightScreenCaptureAccess() else {
      // Adds MacMeet to the Screen Recording list in System Settings (and prompts the first time).
      CGRequestScreenCaptureAccess()
      reject("AbortError", "Screen Recording permission is required to share your screen.")
      showPermissionAlert()
      return
    }

    do {
      let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
      pickerRequest = PickerRequest(
        displays: content.displays.map(Self.source(for:)),
        windows: content.windows.filter(Self.isShareable).map(Self.source(for:))
          .sorted { ($0.subtitle, $0.title) < ($1.subtitle, $1.title) },
        frameRate: frameRate
      )
    } catch {
      reject("NotReadableError", error.localizedDescription)
    }
  }

  func share(_ source: Source) {
    guard let request = pickerRequest else { return }
    pickerRequest = nil
    stopCapture(notifyPage: false)

    let filter: SCContentFilter
    let surface: String
    switch source.content {
    case .display(let display):
      filter = SCContentFilter(display: display, excludingWindows: [])
      surface = "monitor"
    case .window(let window):
      filter = SCContentFilter(desktopIndependentWindow: window)
      surface = "window"
    }

    let session = ScreenCaptureSession(
      filter: filter,
      frameRate: request.frameRate,
      onFrame: { session, base64 in
        Task { @MainActor in ScreenShareController.shared.deliver(base64, from: session) }
      },
      onStop: { session in
        Task { @MainActor in ScreenShareController.shared.captureEnded(session) }
      }
    )
    self.session = session

    Task {
      do {
        try await session.start()
        guard self.session === session else {
          session.stop()
          return
        }
        let details: [String: Any] = [
          "width": session.size.width,
          "height": session.size.height,
          "surface": surface,
          "label": source.title,
        ]
        callPage("started", details)
      } catch {
        if self.session === session { self.session = nil }
        reject("NotReadableError", error.localizedDescription)
      }
    }
  }

  func cancelPicker() {
    guard pickerRequest != nil else { return }
    pickerRequest = nil
    reject("AbortError", "The user cancelled screen sharing.")
  }

  /// A navigation replaces the page, and with it the script's state, so drop any share.
  func pageDidNavigate() {
    pickerRequest = nil
    stopCapture(notifyPage: false)
  }

  // MARK: - Capture

  private func deliver(_ base64: String, from session: ScreenCaptureSession) {
    guard self.session === session, let webView else {
      session.frameDelivered()
      return
    }
    webView.evaluateJavaScript("window.__macmeetScreenShare.frame('\(base64)')") { _, _ in
      session.frameDelivered()
    }
  }

  private func captureEnded(_ session: ScreenCaptureSession) {
    guard self.session === session else { return }
    stopCapture(notifyPage: true)
  }

  private func stopCapture(notifyPage: Bool) {
    guard let session else { return }
    self.session = nil
    session.stop()
    if notifyPage { callPage("ended") }
  }

  // MARK: - Helpers

  /// Meet answers a `NotAllowedError` with instructions for Safari's per-site settings, which
  /// don't apply here, so refusals use `AbortError` instead.
  private func reject(_ name: String, _ message: String) {
    callPage("failed", name, message)
  }

  private func callPage(_ function: String, _ arguments: Any...) {
    guard let data = try? JSONSerialization.data(withJSONObject: arguments),
          let json = String(data: data, encoding: .utf8) else { return }
    webView?.evaluateJavaScript("window.__macmeetScreenShare.\(function)(...\(json))")
  }

  private func showPermissionAlert() {
    let alert = NSAlert()
    alert.messageText = "Allow MacMeet to record your screen"
    alert.informativeText = """
      To share your screen, turn on MacMeet in System Settings > Privacy & Security > \
      Screen & System Audio Recording, then quit and reopen MacMeet.
      """
    alert.addButton(withTitle: "Open System Settings")
    alert.addButton(withTitle: "Cancel")
    if alert.runModal() == .alertFirstButtonReturn,
       let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
      NSWorkspace.shared.open(url)
    }
  }

  private static func isShareable(_ window: SCWindow) -> Bool {
    guard let app = window.owningApplication, window.isOnScreen, window.windowLayer == 0 else { return false }
    return app.bundleIdentifier != Bundle.main.bundleIdentifier
      && window.frame.width >= 100
      && window.frame.height >= 100
  }

  private static func source(for display: SCDisplay) -> Source {
    let screen = NSScreen.screens.first {
      ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
    }
    return Source(
      id: "display-\(display.displayID)",
      title: screen?.localizedName ?? "Display",
      subtitle: "\(display.width) × \(display.height)",
      icon: nil,
      content: .display(display)
    )
  }

  private static func source(for window: SCWindow) -> Source {
    let appName = window.owningApplication?.applicationName ?? ""
    let title = window.title.flatMap { $0.isEmpty ? nil : $0 } ?? appName
    let icon = window.owningApplication
      .flatMap { NSRunningApplication(processIdentifier: $0.processID) }?.icon
    return Source(
      id: "window-\(window.windowID)",
      title: title,
      subtitle: appName,
      icon: icon,
      content: .window(window)
    )
  }
}
