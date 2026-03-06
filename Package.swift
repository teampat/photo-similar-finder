// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhotoSimilarFinder",
    platforms: [
        .macOS(.v14)  // onKeyPress, two-arg onChange require macOS 14+
    ],
    targets: [
        .executableTarget(
            name: "PhotoSimilarFinder",
            path: "PhotoSimilarFinder",
            linkerSettings: [
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("Vision"),
                .linkedFramework("Metal"),
                .linkedFramework("CoreImage"),
            ]
        )
    ]
)
