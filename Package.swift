// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacPerfMonitor",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "MacPerfMonitorCore", targets: ["MacPerfMonitorCore"]),
        .executable(name: "macperfmonitor-cli", targets: ["macperfmonitor-cli"]),
        .executable(name: "MacPerfMonitor", targets: ["MacPerfMonitor"]),
        .executable(name: "MacPerfMonitorHelper", targets: ["MacPerfMonitorHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        // Thin C shim exposing libproc / mach / sysctl headers and a couple of
        // helpers (Rosetta detection, rusage_info_v6) that are awkward from Swift.
        .target(
            name: "CMacPerfMonitor"
        ),

        // The whole data layer: system readers, models, sampling, persistence,
        // analysis. Builds and runs with no SwiftUI dependency so it is testable
        // headlessly and reusable across the app, menubar, and CLI harness.
        .target(
            name: "MacPerfMonitorCore",
            dependencies: [
                "CMacPerfMonitor",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),

        // M0 data-layer spike + headless diagnostics. Links MacPerfMonitorCore.
        .executableTarget(
            name: "macperfmonitor-cli",
            dependencies: [
                "MacPerfMonitorCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),

        // Shared XPC contract between the app and the privileged helper: the
        // @objc service protocol, the server-side service, the listener
        // delegate, and the client connection. Foundation + MacPerfMonitorCore only,
        // so it carries no SwiftUI and can be tested in process.
        .target(
            name: "MacPerfMonitorIPC",
            dependencies: ["MacPerfMonitorCore"]
        ),

        // The privileged root LaunchDaemon. A thin XPC listener over MacPerfMonitorIPC
        // that reads process data as root for the app. Registered via
        // SMAppService and bundled under Contents/MacOS by Scripts/bundle.sh.
        .executableTarget(
            name: "MacPerfMonitorHelper",
            dependencies: ["MacPerfMonitorIPC", "MacPerfMonitorCore"]
        ),

        // The SwiftUI app: menubar, windows, views, view models. Built from the
        // command line via SPM and wrapped into a .app bundle by Scripts/bundle.sh.
        // Uses @main in App/MacPerfMonitorApp.swift (there must be no main.swift here).
        .executableTarget(
            name: "MacPerfMonitor",
            dependencies: [
                "MacPerfMonitorCore",
                "MacPerfMonitorIPC",
                "Sparkle",
            ],
            resources: [
                .process("Resources")
            ]
        ),

        // In-app auto-update for the directly-distributed (non-App-Store) build.
        // Sparkle handles EdDSA-signed appcast updates, the privileged install to
        // /Applications, the atomic swap, and the relaunch. Vendored as a local
        // binary target (ThirdParty/Sparkle.xcframework) rather than a remote SPM
        // dependency so clean builds never depend on a network artifact download.
        // Update by replacing the xcframework + Scripts/sparkle-tools from the
        // matching Sparkle-for-Swift-Package-Manager release.
        .binaryTarget(
            name: "Sparkle",
            path: "ThirdParty/Sparkle.xcframework"
        ),

        .testTarget(
            name: "MacPerfMonitorCoreTests",
            dependencies: [
                "MacPerfMonitorCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),

        .testTarget(
            name: "MacPerfMonitorIPCTests",
            dependencies: ["MacPerfMonitorIPC", "MacPerfMonitorCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
