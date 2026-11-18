import AppKit
import SwiftUI

struct JoinMeetingView: View {
  let onJoin: (String) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var input = ""

  private var isValid: Bool { MeetController.meetingURL(from: input) != nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Join a Meeting")
        .font(.headline)
      TextField("Meeting code or link", text: $input, prompt: Text("abc-defg-hij"))
        .textFieldStyle(.roundedBorder)
        .frame(width: 320)
        .onSubmit(join)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Join", action: join)
          .keyboardShortcut(.defaultAction)
          .disabled(!isValid)
      }
    }
    .padding(20)
    .onAppear(perform: prefillFromClipboard)
  }

  private func join() {
    guard isValid else { return }
    onJoin(input)
    dismiss()
  }

  private func prefillFromClipboard() {
    guard let text = NSPasteboard.general.string(forType: .string),
          MeetController.meetingURL(from: text) != nil else { return }
    input = text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
