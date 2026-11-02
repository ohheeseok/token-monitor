import AppKit

// Synchronous entry point on purpose: running `NSApplication.run()` inside an awaited
// `MainActor.run` would keep the main actor busy forever and starve every MainActor task.
let arguments = Array(CommandLine.arguments.dropFirst())

if CommandMode.handles(arguments) {
    Task { @MainActor in exit(await CommandMode.run(arguments)) }
    RunLoop.main.run()
}

let app = NSApplication.shared
let controller = AppController(demo: arguments.contains("--demo"))
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
