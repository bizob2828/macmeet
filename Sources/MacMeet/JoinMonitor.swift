import QuartzCore
import SwiftUI
import WebKit

/// Follows a meeting page from the moment it starts loading until Meet shows something to act on.
/// Meanwhile MacMeet covers Meet's blank loading screen with a "Joining meeting…" overlay, and, when
/// debug logging is on, records how long each step takes: the page load, the camera and mic, and
/// the first Meet screen.
@MainActor
final class JoinMonitor: NSObject, ObservableObject, WKScriptMessageHandler {
  static let shared = JoinMonitor()
  static let handlerName = "macmeetJoin"

  /// True from the start of a meeting page load until Meet shows a screen or gives up.
  @Published private(set) var isJoining = false

  private var startTime: CFTimeInterval?
  private var timeout: Task<Void, Never>?

  /// The overlay never stays up longer than this, even if no Meet screen is recognized.
  private static let timeoutSeconds = 20

  // MARK: - Page script

  /// Reports page milestones, camera and mic start times, call connections, and the first Meet
  /// screen recognized on each meeting page. Times are milliseconds since the page started loading.
  static let userScript = WKUserScript(
    source: """
    (() => {
      if (location.hostname !== 'meet.google.com') return;
      const post = (event, detail = '') => window.webkit.messageHandlers.\(handlerName).postMessage({
        event, detail, time: Math.round(performance.now()),
      });
      const elapsed = (since) => `${Math.round(performance.now() - since)} ms`;

      post('page started', location.pathname);
      document.addEventListener('DOMContentLoaded', () => post('page parsed'));
      window.addEventListener('load', () => post('page loaded'));
      try {
        new PerformanceObserver((list) => {
          for (const entry of list.getEntries()) {
            if (entry.name === 'first-contentful-paint') post('first paint');
          }
        }).observe({ type: 'paint', buffered: true });
      } catch {}

      // Wrapped on the prototype, which Meet may call directly instead of through
      // navigator.mediaDevices.
      const MediaDevicesPrototype = window.MediaDevices && MediaDevices.prototype;
      if (MediaDevicesPrototype && MediaDevicesPrototype.getUserMedia) {
        const getUserMedia = MediaDevicesPrototype.getUserMedia;
        MediaDevicesPrototype.getUserMedia = async function (constraints) {
          const kinds = ['audio', 'video'].filter((kind) => constraints && constraints[kind]).join(' and ') || 'nothing';
          const since = performance.now();
          post('media requested', kinds);
          try {
            const stream = await getUserMedia.call(this, constraints);
            post('media started', `${kinds} after ${elapsed(since)}`);
            return stream;
          } catch (error) {
            post('media failed', `${kinds}: ${error.name} after ${elapsed(since)}`);
            throw error;
          }
        };
      }

      // The call's network connections. A Proxy keeps the constructor's prototype and statics.
      const NativePeerConnection = window.RTCPeerConnection;
      if (NativePeerConnection) {
        let count = 0;
        window.RTCPeerConnection = new Proxy(NativePeerConnection, {
          construct(target, args, newTarget) {
            const connection = Reflect.construct(target, args, newTarget);
            const id = ++count;
            const since = performance.now();
            post('connection created', `#${id}`);
            connection.addEventListener('connectionstatechange', () => {
              post(`connection ${connection.connectionState}`, `#${id} after ${elapsed(since)}`);
            });
            return connection;
          },
        });
      }

      // Meet's screens, recognized by their visible buttons. Each is reported once per meeting page.
      const isVisible = (element) => element.getClientRects().length > 0;
      const buttonText = () => [...document.querySelectorAll('button, [role="button"]')]
        .filter(isVisible)
        .map((button) => button.textContent.trim().toLowerCase());
      const screens = [
        ['in call', () => [...document.querySelectorAll('[aria-label^="Leave call"]')].some(isVisible)],
        ['pre-join', () => buttonText().some((text) => /^(join now|ask to join|join|switch here|join here too)$/.test(text))],
        ['message', () => buttonText().some((text) => /^(return to home screen|rejoin|try again)$/.test(text))],
      ];
      const meetingPath = /^\\/([a-z]{3}-[a-z]{4}-[a-z]{3}|new)$/;
      let path = null;
      let seen = new Set();
      setInterval(() => {
        if (location.pathname !== path) {
          path = location.pathname;
          seen = new Set();
          if (meetingPath.test(path)) post('meeting opened', path);
        }
        if (!meetingPath.test(path) || seen.has('in call')) return;
        for (const [name, isShown] of screens) {
          if (!seen.has(name) && isShown()) {
            seen.add(name);
            post('screen shown', name);
          }
        }
      }, 250);
    })();
    """,
    injectionTime: .atDocumentStart,
    forMainFrameOnly: true
  )

  // MARK: - Navigation

  /// Called for each main-frame navigation. A meeting page starts a join; any other page ends one.
  func navigationStarted(to url: URL?) {
    guard Self.isMeetingPage(url) else {
      finish("left the meeting page")
      return
    }
    guard !isJoining else { return }
    startTime = CACurrentMediaTime()
    isJoining = true
    log("loading \(url?.absoluteString ?? "")")
    timeout?.cancel()
    timeout = Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.timeoutSeconds))
      guard !Task.isCancelled else { return }
      self?.finish("no Meet screen recognized after \(Self.timeoutSeconds) s")
    }
  }

  func navigationFailed(_ error: Error) {
    finish("navigation failed: \(error.localizedDescription)")
  }

  private func finish(_ reason: String) {
    guard isJoining else { return }
    log("done, \(reason)")
    isJoining = false
    startTime = nil
    timeout?.cancel()
    timeout = nil
  }

  private func log(_ message: String) {
    let elapsed = startTime.map { " +\(Int((CACurrentMediaTime() - $0) * 1000)) ms" } ?? ""
    DebugLog.write("Join\(elapsed): \(message)")
  }

  private static func isMeetingPage(_ url: URL?) -> Bool {
    guard MeetController.isMeetURL(url), let path = url?.path() else { return false }
    return path == "/new" || path.wholeMatch(of: /\/[a-z]{3}-[a-z]{4}-[a-z]{3}/) != nil
  }

  // MARK: - WKScriptMessageHandler

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard let body = message.body as? [String: Any], let event = body["event"] as? String else { return }
    let detail = body["detail"] as? String ?? ""
    let pageTime = (body["time"] as? NSNumber)?.intValue ?? 0
    log("\(event)\(detail.isEmpty ? "" : " (\(detail))"), page +\(pageTime) ms")
    if event == "screen shown" { finish("Meet showed its \(detail) screen") }
  }
}

/// Covers Meet's blank screen while a meeting page loads. It ignores clicks, so it never stands
/// between the user and the page.
struct JoiningOverlay: View {
  var body: some View {
    ZStack {
      Color(red: 0.125, green: 0.129, blue: 0.141)
      VStack(spacing: 14) {
        ProgressView()
          .controlSize(.large)
          .tint(.white)
        Text("Joining meeting…")
          .font(.title3)
          .foregroundStyle(.white.opacity(0.85))
      }
    }
    .ignoresSafeArea()
    .allowsHitTesting(false)
    .transition(.opacity)
  }
}
