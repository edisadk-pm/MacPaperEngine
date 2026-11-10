// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MacPaper",
    platforms: [.macOS(.v14)],
    targets: [
        // Shared by both processes. Must never import SwiftUI: the engine links it.
        .target(name: "MacPaperCore"),
        // Always-running desktop renderer. AppKit + AVFoundation only.
        .executableTarget(name: "MacPaperEngine", dependencies: ["MacPaperCore"]),
        // Settings window. Runs only while it is open.
        .executableTarget(name: "MacPaper", dependencies: ["MacPaperCore"]),
    ]
)
