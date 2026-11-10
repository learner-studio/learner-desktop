// swift-tools-version:6.0
// Learner Desktop: the menu-bar app (one executable target) and its three test lanes.
//   LightTests   fixtures only, whole lane under 1 minute        (pre-commit)
//   MediumTests  real child processes and local stand-ins, 1-3 min (pre-push)
//   HeavyTests   the live machine: screenpipe, ai-vault, server, 3+ min (pre-push)
// scripts/test.sh runs a lane: scripts/test.sh light|medium|heavy|all
// Voice ID links sherpa-onnx statically from local binaries: run scripts/fetch-voice-id.sh once.
import PackageDescription

let package = Package(
    name: "LearnerDesktop",
    platforms: [.macOS(.v15)],
    targets: [
        // Catches Objective-C exceptions (AVAudioEngine raises them), which Swift cannot.
        .target(name: "ObjCCatch", path: "menu-bar-app-objc"),
        // sherpa-onnx (Apache-2.0): its C API and ONNX Runtime, static, fetched (not in git),
        // and its Swift wrapper, vendored as upstream ships it (Swift 5 mode, as upstream builds it).
        .binaryTarget(name: "SherpaOnnxC", path: "third_party/sherpa-onnx/artifacts/sherpa-onnx.xcframework"),
        .binaryTarget(name: "OnnxRuntime", path: "third_party/sherpa-onnx/artifacts/onnxruntime.xcframework"),
        .target(
            name: "SherpaOnnx",
            dependencies: ["SherpaOnnxC", "OnnxRuntime"],
            path: "third_party/sherpa-onnx/swift",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("c++"), .linkedFramework("CoreML"), .linkedFramework("Foundation")]
        ),
        .executableTarget(
            name: "LearnerDesktop",
            dependencies: ["ObjCCatch", "SherpaOnnx"],
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
