// swift-tools-version: 6.0
// Frame: SwiftUI Liquid Glass front end for the `frames` CLI.
// Choice: Swift Package (executableTarget), NOT an Xcodeproj.
// Why: matches existing ~/Developer conventions (NudgeMac, Notify, idea are
// all SPM executableTargets), keeps the build one command (`swift build`),
// and avoids checking in an opaque .pbxproj. A tiny build.sh wraps the
// binary in Frame.app (same pattern as NudgeMac/build.sh).
import PackageDescription

let package = Package(
    name: "Frame",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Frame",
            path: "Sources/Frame"
        ),
        .testTarget(name: "FrameTests", dependencies: ["Frame"], path: "Tests/Swift"),
    ]
)
