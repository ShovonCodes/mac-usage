// swift-tools-version:5.9
// This file tells Swift Package Manager how to build the app.
// No Xcode project is needed — just run `swift build` on your Mac.
import PackageDescription

let package = Package(
    name: "MacUsage",
    platforms: [
        // MenuBarExtra (the API that puts our app in the menu bar) needs macOS 13+
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "MacUsage",
            path: "Sources/MacUsage"
        )
    ]
)
