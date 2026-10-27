// swift-tools-version:6.0
// Learner Desktop: the menu-bar app (one executable target) and its three test lanes.
//   LightTests   fixtures only, whole lane under 1 minute        (pre-commit)
//   MediumTests  real child processes and local stand-ins, 1-3 min (pre-push)
//   HeavyTests   the live machine: screenpipe, ai-vault, server, 3+ min (pre-push)
// scripts/test.sh runs a lane: scripts/test.sh light|medium|heavy|all
import PackageDescription

let package = Package(
    name: "LearnerDesktop",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "LearnerDesktop",
            path: "menu-bar-app",
            exclude: ["com.benpollack.learner-desktop.plist", "learner-desktop", "Learner Desktop.app", "Models"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "TestSupport", path: "Tests/TestSupport", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "LightTests", dependencies: ["LearnerDesktop", "TestSupport"], path: "Tests/LightTests",
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "MediumTests", dependencies: ["LearnerDesktop", "TestSupport"], path: "Tests/MediumTests",
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "HeavyTests", dependencies: ["LearnerDesktop", "TestSupport"], path: "Tests/HeavyTests",
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
