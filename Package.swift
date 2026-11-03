// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "QuotaDeck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "QuotaDeck",
            path: "Sources/QuotaDeck"
        )
    ],
    swiftLanguageModes: [.v5]
)
