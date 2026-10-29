// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "LocalScribe", platforms: [.macOS("26.0")],
    products: [.executable(name: "LocalScribe", targets: ["LocalScribe"]),
               .executable(name: "LocalScribeModelService", targets: ["LocalScribeModelService"]),
               .executable(name: "LocalScribeWorker", targets: ["LocalScribeWorker"])],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "2.31.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.6"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.2.1")
    ],
    targets: [
        .target(name: "CWorkerIsolation", linkerSettings: [.linkedLibrary("sandbox")]),
        .target(name: "LocalScribeCore"),
        .target(name: "LocalScribeQwen", dependencies: [
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "Tokenizers", package: "swift-transformers")
        ], path: "ThirdParty/QwenASR/Sources"),
        .target(name: "LocalScribeVibeVoice", dependencies: [
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "Tokenizers", package: "swift-transformers")
        ], path: "ThirdParty/VibeVoiceASR/Sources"),
        // Tracked SpeakerKit 1.1.1 snapshot with tail reflection, inference errors and backpressure fixes.
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
        .executableTarget(name: "LocalScribeWorker", dependencies: ["LocalScribeCore", "CWorkerIsolation", "LocalScribeSpeakerKit", "LocalScribeQwen", "LocalScribeVibeVoice",
            .product(name: "WhisperKit", package: "argmax-oss-swift"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "LocalScribeTests", dependencies: ["LocalScribeCore"]),
        .testTarget(name: "LocalScribeDiarizationTests", dependencies: ["LocalScribeSpeakerKit", "LocalScribeCore", "LocalScribeWorker", "CWorkerIsolation"]),
        .testTarget(name: "LocalScribeUITests", dependencies: ["LocalScribe", "LocalScribeModelService"])
    ]
)
