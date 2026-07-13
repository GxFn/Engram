// swift-tools-version: 6.0
import PackageDescription

// Layered module graph (see README "Architecture"):
// Features depend on Domain protocols only; Infrastructure implements Domain
// protocols as leaf plugins; AppShell is the assembly layer consumed by the
// Xcode app target. Extension targets (M2 ShareExtension) must only ever link
// lightweight modules (ClipCore/AppGroupSupport/ClipPipeline) — engines stay out by structure,
// not by discipline.
let package = Package(
    name: "Engram",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "AppShell", targets: ["AppShell"]),
        .library(name: "AskFeature", targets: ["AskFeature"]),
        .library(name: "MemoryFeature", targets: ["MemoryFeature"]),
        .library(name: "InsightFeature", targets: ["InsightFeature"]),
        .library(name: "BenchFeature", targets: ["BenchFeature"]),
        .library(name: "SettingsFeature", targets: ["SettingsFeature"]),
        .library(name: "EngineKit", targets: ["EngineKit"]),
        .library(name: "RAGCore", targets: ["RAGCore"]),
        .library(name: "ClipCore", targets: ["ClipCore"]),
        .library(name: "MetricsKit", targets: ["MetricsKit"]),
        .library(name: "VideoUnderstanding", targets: ["VideoUnderstanding"]),
        .library(name: "StoryboardCore", targets: ["StoryboardCore"]),
        .library(name: "AnalysisStore", targets: ["AnalysisStore"]),
        .library(name: "ShotDetection", targets: ["ShotDetection"]),
        .library(name: "ScriptCore", targets: ["ScriptCore"]),
        .library(name: "SpeechTranscription", targets: ["SpeechTranscription"]),
        .library(name: "FrameVision", targets: ["FrameVision"]),
        .library(name: "QwenVLRuntime", targets: ["QwenVLRuntime"]),
        .library(name: "CloudVision", targets: ["CloudVision"]),
        .library(name: "ScriptComposer", targets: ["ScriptComposer"]),
        .library(name: "MLXEngine", targets: ["MLXEngine"]),
        .library(name: "FMEngine", targets: ["FMEngine"]),
        .library(name: "EmbeddingMLX", targets: ["EmbeddingMLX"]),
        .library(name: "VectorStoreSQLite", targets: ["VectorStoreSQLite"]),
        .library(name: "CSQLiteVec", targets: ["CSQLiteVec"]),
        .library(name: "ClipPipeline", targets: ["ClipPipeline"]),
        .library(name: "ClipDigest", targets: ["ClipDigest"]),
        .library(name: "ModelStore", targets: ["ModelStore"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "AppGroupSupport", targets: ["AppGroupSupport"]),
        .library(name: "EngramLogging", targets: ["EngramLogging"]),
        .executable(name: "MacVideoSmoke", targets: ["MacVideoSmoke"]),
        .executable(name: "StoryboardFixtureCLI", targets: ["StoryboardFixtureCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.4"),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.4")),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        // MARK: - Domain (pure Swift contracts and types, zero third-party dependencies)
        .target(name: "EngineKit", path: "Sources/Domain/EngineKit"),
        .target(name: "RAGCore", path: "Sources/Domain/RAGCore"),
        .target(name: "ClipCore", path: "Sources/Domain/ClipCore"),
        .target(name: "MetricsKit", path: "Sources/Domain/MetricsKit"),
        .target(name: "VideoUnderstanding", path: "Sources/Domain/VideoUnderstanding"),
        .target(
            name: "StoryboardCore",
            dependencies: ["VideoUnderstanding", "ScriptCore"],
            path: "Sources/Domain/StoryboardCore"
        ),
        .target(
            name: "AnalysisStore",
            dependencies: ["VideoUnderstanding", "StoryboardCore"],
            path: "Sources/Infrastructure/AnalysisStore"
        ),
        .target(
            name: "ShotDetection",
            dependencies: ["VideoUnderstanding"],
            path: "Sources/Infrastructure/ShotDetection"
        ),
        .target(
            name: "ScriptCore",
            dependencies: ["VideoUnderstanding", "EngineKit"],
            path: "Sources/Domain/ScriptCore"
        ),

        // MARK: - Shared kits
        .target(name: "AppGroupSupport", path: "Sources/Shared/AppGroupSupport"),
        .target(name: "EngramLogging", path: "Sources/Shared/EngramLogging"),
        .target(
            name: "CSQLiteVec",
            path: "Sources/Vendor/CSQLiteVec",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .define("SQLITE_CORE", to: "1"),
                .define("SQLITE_VEC_STATIC", to: "1"),
                .define("SQLITE_ENABLE_FTS5", to: "1"),
                .define("SQLITE_OMIT_LOAD_EXTENSION", to: "1"),
                .define("SQLITE_THREADSAFE", to: "1"),
                .define("SQLITE_VEC_ENABLE_DISKANN", to: "0"),
                .define("SQLITE_VEC_ENABLE_RESCORE", to: "0"),
            ]
        ),

        // MARK: - Infrastructure (protocol implementations, leaf plugins)
        .target(
            name: "MLXEngine",
            dependencies: [
                "EngineKit",
                "EngramLogging",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/Infrastructure/MLXEngine"
        ),
        .target(
            name: "FMEngine",
            dependencies: ["EngineKit", "EngramLogging"],
            path: "Sources/Infrastructure/FMEngine"
        ),
        .target(
            name: "EmbeddingMLX",
            dependencies: [
                "RAGCore",
                "EngramLogging",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/Infrastructure/EmbeddingMLX"
        ),
        .target(
            name: "VectorStoreSQLite",
            dependencies: ["RAGCore", "EngramLogging", "CSQLiteVec"],
            path: "Sources/Infrastructure/VectorStoreSQLite"
        ),
        .target(
            name: "SpeechTranscription",
            dependencies: ["VideoUnderstanding", "EngramLogging"],
            path: "Sources/Infrastructure/SpeechTranscription"
        ),
        .target(
            name: "FrameVision",
            dependencies: ["VideoUnderstanding", "EngramLogging"],
            path: "Sources/Infrastructure/FrameVision"
        ),
        .target(
            name: "QwenVLRuntime",
            dependencies: [
                "EngineKit",
                "VideoUnderstanding",
                "EngramLogging",
                "ModelStore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/Infrastructure/QwenVLRuntime"
        ),
        .target(
            name: "CloudVision",
            dependencies: [
                "ScriptCore",
                "VideoUnderstanding",
                "EngineKit",
                "EngramLogging",
            ],
            path: "Sources/Infrastructure/CloudVision"
        ),
        .target(
            name: "ScriptComposer",
            dependencies: [
                "ScriptCore",
                "VideoUnderstanding",
                "QwenVLRuntime",
                "EngineKit",
                "EngramLogging",
            ],
            path: "Sources/Infrastructure/ScriptComposer"
        ),
        .target(
            name: "ClipPipeline",
            dependencies: ["ClipCore", "AppGroupSupport"],
            path: "Sources/Infrastructure/ClipPipeline"
        ),
        .target(
            name: "ClipDigest",
            dependencies: [
                "AppGroupSupport",
                "ClipCore",
                "ClipPipeline",
                "Persistence",
                "VideoUnderstanding",
                "StoryboardCore",
                "AnalysisStore",
                "ShotDetection",
                "ScriptCore",
                "EngramLogging",
            ],
            path: "Sources/Infrastructure/ClipDigest"
        ),
        .target(
            name: "ModelStore",
            dependencies: [
                "EngineKit",
                "EngramLogging",
                .product(name: "Hub", package: "swift-transformers"),
            ],
            path: "Sources/Infrastructure/ModelStore"
        ),
        .target(
            name: "Persistence",
            dependencies: ["ClipCore", "ScriptCore", "AppGroupSupport", "EngramLogging"],
            path: "Sources/Infrastructure/Persistence"
        ),

        // MARK: - Features (SwiftUI, Domain-only dependencies — dependency rule 1)
        .target(
            name: "AskFeature",
            dependencies: ["EngineKit", "RAGCore", "EngramLogging"],
            path: "Sources/Features/AskFeature"
        ),
        .target(
            name: "MemoryFeature",
            dependencies: ["ClipCore", "ScriptCore", "EngramLogging"],
            path: "Sources/Features/MemoryFeature"
        ),
        .target(
            name: "BenchFeature",
            dependencies: ["EngineKit", "MetricsKit", "RAGCore", "EngramLogging"],
            path: "Sources/Features/BenchFeature",
            resources: [.process("BenchSuite")]
        ),
        .target(
            name: "SettingsFeature",
            dependencies: ["EngineKit", "EngramLogging"],
            path: "Sources/Features/SettingsFeature"
        ),
        .target(
            name: "InsightFeature",
            dependencies: ["ScriptCore", "EngramLogging"],
            path: "Sources/Features/InsightFeature"
        ),

        // MARK: - AppShell (assembly layer; the only place allowed to wire Infrastructure into Features)
        .target(
            name: "AppShell",
            dependencies: [
                "AskFeature",
                "MemoryFeature",
                "InsightFeature",
                "BenchFeature",
                "SettingsFeature",
                "EngineKit",
                "RAGCore",
                "ClipDigest",
                "AnalysisStore",
                "ShotDetection",
                "EmbeddingMLX",
                "SpeechTranscription",
                "FrameVision",
                "ScriptComposer",
                "CloudVision",
                "MLXEngine",
                "ModelStore",
                "Persistence",
                "VectorStoreSQLite",
                "AppGroupSupport",
            ],
            path: "Sources/AppShell"
        ),
        .executableTarget(
            name: "MacVideoSmoke",
            dependencies: [
                "EngineKit",
                "VideoUnderstanding",
                "SpeechTranscription",
                "FrameVision",
                "ScriptCore",
                "ScriptComposer",
                "MLXEngine",
                "ModelStore",
            ],
            path: "Tools/MacVideoSmoke"
        ),
        .executableTarget(
            name: "StoryboardFixtureCLI",
            dependencies: ["VideoUnderstanding"],
            path: "Tools/StoryboardFixtureCLI"
        ),

        // MARK: - Tests
        .testTarget(name: "AskFeatureTests", dependencies: ["AskFeature", "EngineKit", "RAGCore"], path: "Tests/AskFeatureTests"),
        .testTarget(
            name: "AppShellTests",
            dependencies: [
                "AppShell",
                "AskFeature",
                "BenchFeature",
                "EngineKit",
                "RAGCore",
                "MemoryFeature",
                "ModelStore",
                "ClipCore",
                "ClipDigest",
                "ClipPipeline",
                "Persistence",
                "AppGroupSupport",
                "ScriptCore",
                "VideoUnderstanding",
            ],
            path: "Tests/AppShellTests"
        ),
        .testTarget(name: "BenchFeatureTests", dependencies: ["BenchFeature", "EngineKit", "MetricsKit", "RAGCore"], path: "Tests/BenchFeatureTests"),
        .testTarget(
            name: "ClipDigestTests",
            dependencies: ["ClipDigest", "ClipCore", "ClipPipeline", "Persistence", "ScriptCore", "VideoUnderstanding", "StoryboardCore", "AnalysisStore"],
            path: "Tests/ClipDigestTests"
        ),
        .testTarget(name: "ClipPipelineTests", dependencies: ["AppGroupSupport", "ClipCore", "ClipPipeline"], path: "Tests/ClipPipelineTests"),
        .testTarget(name: "EngineKitTests", dependencies: ["EngineKit"], path: "Tests/EngineKitTests"),
        .testTarget(name: "EmbeddingMLXTests", dependencies: ["EmbeddingMLX", "RAGCore"], path: "Tests/EmbeddingMLXTests"),
        .testTarget(name: "MetricsKitTests", dependencies: ["MetricsKit"], path: "Tests/MetricsKitTests"),
        .testTarget(name: "MemoryFeatureTests", dependencies: ["MemoryFeature", "ClipCore", "ScriptCore"], path: "Tests/MemoryFeatureTests"),
        .testTarget(name: "InsightFeatureTests", dependencies: ["InsightFeature", "ScriptCore"], path: "Tests/InsightFeatureTests"),
        .testTarget(name: "MLXEngineTests", dependencies: ["EngineKit", "MLXEngine"], path: "Tests/MLXEngineTests"),
        .testTarget(name: "ModelStoreTests", dependencies: ["EngineKit", "ModelStore"], path: "Tests/ModelStoreTests"),
        .testTarget(name: "PersistenceTests", dependencies: ["AppGroupSupport", "Persistence", "ScriptCore"], path: "Tests/PersistenceTests"),
        .testTarget(name: "RAGCoreTests", dependencies: ["RAGCore"], path: "Tests/RAGCoreTests"),
        .testTarget(name: "VideoUnderstandingTests", dependencies: ["VideoUnderstanding"], path: "Tests/VideoUnderstandingTests"),
        .testTarget(
            name: "StoryboardCoreTests",
            dependencies: ["StoryboardCore", "ScriptCore", "VideoUnderstanding"],
            path: "Tests/StoryboardCoreTests"
        ),
        .testTarget(
            name: "AnalysisStoreTests",
            dependencies: ["AnalysisStore", "VideoUnderstanding"],
            path: "Tests/AnalysisStoreTests"
        ),
        .testTarget(
            name: "ShotDetectionTests",
            dependencies: ["ShotDetection", "VideoUnderstanding"],
            path: "Tests/ShotDetectionTests"
        ),
        .testTarget(name: "ScriptCoreTests", dependencies: ["ScriptCore", "VideoUnderstanding"], path: "Tests/ScriptCoreTests"),
        .testTarget(name: "SpeechTranscriptionTests", dependencies: ["SpeechTranscription", "VideoUnderstanding"], path: "Tests/SpeechTranscriptionTests"),
        .testTarget(name: "FrameVisionTests", dependencies: ["FrameVision", "VideoUnderstanding"], path: "Tests/FrameVisionTests"),
        .testTarget(
            name: "QwenVLRuntimeTests",
            dependencies: ["QwenVLRuntime", "VideoUnderstanding", "ModelStore", "EngineKit"],
            path: "Tests/QwenVLRuntimeTests"
        ),
        .testTarget(
            name: "CloudVisionTests",
            dependencies: ["CloudVision", "ScriptCore", "VideoUnderstanding", "EngineKit"],
            path: "Tests/CloudVisionTests"
        ),
        .testTarget(
            name: "ScriptComposerTests",
            dependencies: [
                "ScriptComposer",
                "ScriptCore",
                "VideoUnderstanding",
                "QwenVLRuntime",
                "EngineKit",
            ],
            path: "Tests/ScriptComposerTests"
        ),
        .testTarget(name: "SettingsFeatureTests", dependencies: ["SettingsFeature", "EngineKit"], path: "Tests/SettingsFeatureTests"),
        .testTarget(name: "ClipCoreTests", dependencies: ["ClipCore"], path: "Tests/ClipCoreTests"),
        .testTarget(name: "VectorStoreSQLiteTests", dependencies: ["VectorStoreSQLite", "RAGCore"], path: "Tests/VectorStoreSQLiteTests"),
    ]
)
