import Foundation
import os

/// Optional troubleshooting log, turned on in Settings. While enabled, each message goes to the
/// unified log and is appended to ~/Library/Logs/MacMeet/MacMeet.log, which can be read without
/// admin rights. While disabled, nothing is recorded.
enum DebugLog {
  static let enabledKey = "debugLogging"

  static let fileURL = FileManager.default
    .homeDirectoryForCurrentUser
    .appending(path: "Library/Logs/MacMeet/MacMeet.log")

  private static let logger = Logger(subsystem: "local.macmeet.MacMeet", category: "debug")
  private static let queue = DispatchQueue(label: "local.macmeet.MacMeet.debug-log")

  static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

  static func write(_ message: @autoclosure () -> String) {
    guard isEnabled else { return }
    let message = message()
    logger.notice("\(message, privacy: .public)")
    let line = Data("\(Date.now.formatted(.iso8601)) \(message)\n".utf8)
    queue.async { append(line) }
  }

  private static func append(_ line: Data) {
    let manager = FileManager.default
    try? manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let handle = try? FileHandle(forWritingTo: fileURL) else {
      try? line.write(to: fileURL)
      return
    }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: line)
  }
}
