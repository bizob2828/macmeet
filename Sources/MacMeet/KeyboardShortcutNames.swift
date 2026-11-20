import AppKit
import KeyboardShortcuts

/// System-wide shortcut names, configurable in Settings. The initial values match the
/// in-app ⌘D/⌘E menu shortcuts, so existing users see no change until they customize them.
@MainActor
extension KeyboardShortcuts.Name {
  static let toggleMicrophone = Self("toggleMicrophone", default: .init(.d, modifiers: [.command]))
  static let toggleCamera = Self("toggleCamera", default: .init(.e, modifiers: [.command]))
}
