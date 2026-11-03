// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JiangJingRegression",
    products: [.library(name: "CaptureCore", targets: ["CaptureCore"])],
    targets: [
        .target(name: "CaptureCore", path: "JiangJing", exclude: [
            "App", "Features", "Resources", "Support", "Info.plist", "PrivacyInfo.xcprivacy",
            "Camera/CameraController.swift", "Camera/CameraPreviewView.swift", "Camera/PortraitRotation.swift",
            "Media/MediaLibraryModel.swift", "Media/PhotoLibrarySaver.swift"
        ], sources: ["Camera/CaptureState.swift", "Media/MediaJournal.swift"]),
        .testTarget(name: "RegressionTests", dependencies: ["CaptureCore"], path: "Tests/RegressionTests")
    ]
)
