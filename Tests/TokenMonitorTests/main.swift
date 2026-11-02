import Testing

// Command Line Tools ship swift-testing but `swift test` does not run it without Xcode,
// so this executable calls the SwiftPM entry point directly: `swift run TokenMonitorTests`.
await Testing.__swiftPMEntryPoint() as Never
