// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TipMeCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        // Foundation-only. Deliberately free of UIKit/SwiftUI so it can be linked
        // by the app, the share extension, and (Phase 2) a server-side trigger.
        .library(name: "TipMeCore", targets: ["TipMeCore"])
    ],
    targets: [
        .target(name: "TipMeCore"),
        .testTarget(
            name: "TipMeCoreTests",
            dependencies: ["TipMeCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
