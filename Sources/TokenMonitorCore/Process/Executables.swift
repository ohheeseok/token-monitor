import Foundation

/// Resolves CLI tools to absolute paths. Apps launched from Finder or at login do not inherit the
/// interactive shell's PATH, so we check the usual install locations explicitly.
public enum Executables {
    static let searchDirectories: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs += path.split(separator: ":").map(String.init)
        }
        return dirs
    }()

    public static func find(_ name: String) -> URL? {
        for dir in searchDirectories {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    public static let security = URL(fileURLWithPath: "/usr/bin/security")
}
