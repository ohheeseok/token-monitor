// swift-tools-version: 6.2
import PackageDescription

// With Command Line Tools only (no Xcode), swift-testing lives outside the default search path
// and `swift test` does not run it, so the tests are an executable target: `swift run TokenMonitorTests`.
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let cltLibs = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

let package = Package(
    name: "TokenMonitor",
    defaultLocalization: "ko",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "TokenMonitor", targets: ["TokenMonitor"]),
    ],
    targets: [
        .target(
            name: "TokenMonitorCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "TokenMonitor",
            dependencies: ["TokenMonitorCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "TokenMonitorTests",
            dependencies: ["TokenMonitorCore"],
            path: "Tests/TokenMonitorTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6), .unsafeFlags(["-F", cltFrameworks])],
            linkerSettings: [.unsafeFlags([
                "-F", cltFrameworks,
                "-Xlinker", "-rpath", "-Xlinker", cltFrameworks,
                "-Xlinker", "-rpath", "-Xlinker", cltLibs,
            ])]
        ),
    ]
)
