// swift-tools-version:6.0
import PackageDescription

// PersonalAICore is platform-neutral (Linux + Apple). It owns everything that must be correct
// regardless of UI or inference runtime: the immutable archive, search indexes, memory,
// retrieval and context planning. The iOS app (App/) depends on it.
let package = Package(
    name: "PersonalAI",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PersonalAICore", targets: ["PersonalAICore"]),
        .executable(name: "paibench", targets: ["paibench"]),
        .executable(name: "paieval", targets: ["paieval"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .target(
            name: "PersonalAICore",
            dependencies: [.target(name: "CSQLite", condition: .when(platforms: [.linux]))]
        ),
        .executableTarget(name: "paibench", dependencies: ["PersonalAICore"]),
        .executableTarget(name: "paieval", dependencies: ["PersonalAICore"]),
        .testTarget(name: "PersonalAICoreTests", dependencies: ["PersonalAICore"]),
    ]
)
