import AppKit
import SwiftUI

struct MenuBarLabel: View {
  @ObservedObject private var meet = MeetController.shared

  var body: some View {
    Image(systemName: meet.isInCall ? "video.fill" : "video")
  }
}

struct MenuBarMenu: View {
  @ObservedObject private var meet = MeetController.shared
  @Environment(\.openSettings) private var openSettings

  private var app: AppController { .shared }

  var body: some View {
    Button("Open MacMeet") {
      // Wait for the menu to close; activating while it's still tracking can leave the window
      // behind the app that was frontmost.
      DispatchQueue.main.async { app.showWindow() }
    }

    Divider()

    Button("New Meeting") { app.newMeeting() }
    Button("Join Meeting…") { app.showJoinSheet() }

    if let code = meet.meetingCode {
      Divider()
      Text("In meeting \(code)")
      Button("Toggle Microphone") { meet.toggleMicrophone() }
      Button("Toggle Camera") { meet.toggleCamera() }
      Button("Copy Meeting Link") { meet.copyMeetingLink() }
    }

    Divider()

    Button("About MacMeet") { app.showAbout() }
    Button("Settings…") {
      // Without a Dock icon the app isn't active, so the Settings window would open behind
      // other apps.
      NSApp.activate()
      openSettings()
    }
    Button("Quit MacMeet") { NSApp.terminate(nil) }
  }
}
