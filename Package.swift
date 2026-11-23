// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JiangJingRegression",
    products: [.library(name: "CaptureCore", targets: ["CaptureCore"])],
    targets: [
        .target(name: "CaptureCore", path: "JiangJing", exclude: [
            "App", "Features", "Resources", "Support", "Info.plist", "PrivacyInfo.xcprivacy",
            "Camera/CameraController.swift", "Camera/CameraPreviewView.swift", "Camera/PortraitRotation.swift",
            "Media/MediaLibraryModel.swift", "Media/PhotoLibrarySaver.swift",
            "Store/StoreBackend.swift", "Store/StoreManager.swift",
            "Store/LabelRenderer.swift", "Store/LabelExporter.swift"
        ], sources: ["Camera/CaptureState.swift", "Camera/BackgroundTaskLifetime.swift",
                     "Camera/LockedFrameState.swift", "Media/MediaJournal.swift",
                     "Store/StoreCatalog.swift", "Store/StoreState.swift", "Store/LabelLayout.swift", "Store/LabelPreferences.swift"]),
        .testTarget(name: "RegressionTests", dependencies: ["CaptureCore"], path: "Tests/RegressionTests"),
        .testTarget(name: "CameraLifecycleTests", dependencies: ["CaptureCore"], path: "JiangJingTests",
                    exclude: ["MediaLibraryModelTests.swift", "StoreManagerTests.swift", "MockStoreBackend.swift", "LabelExporterTests.swift"], sources: ["CameraLifecycleTests.swift"])
    ]
)
