// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "LocalScribe", platforms: [.macOS("26.0")],
    products: [.executable(name: "LocalScribe", targets: ["LocalScribe"]),
               .executable(name: "LocalScribeModelService", targets: ["LocalScribeModelService"]),
               .executable(name: "LocalScribeWorker", targets: ["LocalScribeWorker"])],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "2.31.3")
    ],
    targets: [
        .target(name: "CWorkerIsolation", linkerSettings: [.linkedLibrary("sandbox")]),
        .target(name: "LocalScribeCore"),
        // Tracked SpeakerKit 1.1.1 snapshot with tail reflection and inference failure propagation.
        // ArgmaxCore is supplied by the pinned WhisperKit product.
        .target(name: "LocalScribeSpeakerKit", dependencies: [
            .product(name: "WhisperKit", package: "argmax-oss-swift")
        ], path: "ThirdParty/SpeakerKit/Sources/SpeakerKit", swiftSettings: [
            .swiftLanguageMode(.v6),
            .enableUpcomingFeature("InferIsolatedConformances"),
            .enableUpcomingFeature("NonisolatedNonsendingByDefault")
        ]),
        .executableTarget(name: "LocalScribeModelService", dependencies: ["LocalScribeCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "LocalScribe", dependencies: ["LocalScribeCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "LocalScribeWorker", dependencies: ["LocalScribeCore", "CWorkerIsolation", "LocalScribeSpeakerKit",
            .product(name: "WhisperKit", package: "argmax-oss-swift"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "LocalScribeTests", dependencies: ["LocalScribeCore"]),
        .testTarget(name: "LocalScribeDiarizationTests", dependencies: ["LocalScribeSpeakerKit", "LocalScribeCore", "LocalScribeWorker"]),
        .testTarget(name: "LocalScribeUITests", dependencies: ["LocalScribe", "LocalScribeModelService"])
    ]
)
