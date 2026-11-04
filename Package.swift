// swift-tools-version:6.0
import PackageDescription

// The widget extension is linked as an ordinary executable here; scripts/build.sh
// wraps it in an .appex bundle inside QuotaDeck.app/Contents/PlugIns.
let appExtension: [SwiftSetting] = [.unsafeFlags(["-application-extension"])]

let package = Package(
    name: "QuotaDeck",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "QuotaDeckKit",
            path: "Sources/QuotaDeckKit",
            swiftSettings: appExtension
        ),
        .executableTarget(
            name: "QuotaDeck",
            dependencies: ["QuotaDeckKit"],
            path: "Sources/QuotaDeck"
        ),
        .executableTarget(
            name: "QuotaDeckWidget",
            dependencies: ["QuotaDeckKit"],
            path: "Sources/QuotaDeckWidget",
            swiftSettings: appExtension,
            // Like Xcode: enter through NSExtensionMain, which sets up the extension
            // context and then calls the WidgetBundle's main.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-application_extension",
                                           "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
    ],
    swiftLanguageModes: [.v5]
)
