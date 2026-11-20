import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
  @ObservedObject private var app = AppController.shared

  private var keepsRunning: Bool { app.closeBehavior == .keepRunning }

  private var menuBarBinding: Binding<Bool> {
    Binding(
      get: { app.effectiveKeepInMenuBar },
      set: { app.keepInMenuBar = $0 }
    )
  }

  var body: some View {
    Form {
      Section {
        Picker("When the main window is closed", selection: $app.closeBehavior) {
          Text("Quit MacMeet").tag(AppController.CloseBehavior.quit)
          Text("Keep MacMeet running").tag(AppController.CloseBehavior.keepRunning)
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()

        Toggle("Keep icon in the Dock", isOn: $app.keepInDock)
          .disabled(!keepsRunning)

        Toggle("Keep item in the menu bar", isOn: menuBarBinding)
          .disabled(!keepsRunning || !app.keepInDock)
      } header: {
        Text("When the main window is closed")
      } footer: {
        if keepsRunning && !app.keepInDock {
          Text("The menu bar item stays while the Dock icon is hidden, so you can always get back to MacMeet.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Section {
        Toggle("Use system-wide hotkeys for mute and camera", isOn: $app.useSystemWideHotkeys)
        KeyboardShortcuts.Recorder("Mute/unmute microphone:", name: .toggleMicrophone)
          .disabled(!app.useSystemWideHotkeys)
        KeyboardShortcuts.Recorder("Turn camera on/off:", name: .toggleCamera)
          .disabled(!app.useSystemWideHotkeys)
      } header: {
        Text("Keyboard Shortcuts")
      } footer: {
        Text("When enabled, these shortcuts mute your microphone or turn off your camera during a call, even when MacMeet isn't the active app. Click a shortcut to record a new one.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section {
        Toggle("Record debug log", isOn: $app.debugLogging)
        Button("Show Log in Finder") { app.showDebugLog() }
      } header: {
        Text("Troubleshooting")
      } footer: {
        Text("Records the links MacMeet receives and the pages it opens to ~/Library/Logs/MacMeet/MacMeet.log.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(width: 440)
    .fixedSize(horizontal: false, vertical: true)
  }
}
