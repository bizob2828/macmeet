// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MacMeet",
  platforms: [.macOS(.v14)],
  targets: [
    .executableTarget(
      name: "MacMeet",
      path: "Sources/MacMeet"
    ),
  ]
)
