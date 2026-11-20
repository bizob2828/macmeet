// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MacMeet",
  platforms: [.macOS(.v14)],
  dependencies: [
    // Pinned below 1.16, which adds #Preview/@Entry usage that needs Xcode's Previews macro
    // plugin — unavailable with just the Command Line Tools, which this project supports.
    .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "1.15.0"),
  ],
  targets: [
    .executableTarget(
      name: "MacMeet",
      dependencies: [
        .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
      ],
      path: "Sources/MacMeet"
    ),
  ]
)
