import Foundation

/// Secrets that TokenMonitor itself owns (e.g. the OpenRouter API key).
///
/// Items are created through `/usr/bin/security` with `-T /usr/bin/security`, and read back through the
/// same tool. That keeps the item's ACL independent of TokenMonitor's own (ad-hoc, per-build) code
/// signature: SecItem-created items are bound to the creating binary's cdhash and block on an
/// authorization dialog after every rebuild. The secret is passed on stdin (`security -i`), never in argv.
public enum AppKeychain {
    public static let service = "com.heeseok.tokenmonitor"

    public enum Failure: Error, Sendable, Equatable {
        case unsupportedCharacters
        case commandFailed(exitCode: Int32)
    }

    public static func save(_ secret: String, account: String) async throws(Failure) {
        // `security -i` tokenizes its input like a shell; refuse anything that would need escaping.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:+=/~@!#$%^&*()[]{},<>?|"))
        guard !secret.isEmpty, secret.unicodeScalars.allSatisfy(allowed.contains),
              account.unicodeScalars.allSatisfy(allowed.contains)
        else { throw .unsupportedCharacters }

        let command = "add-generic-password -U -s \(service) -a \(account) -T /usr/bin/security -w \"\(secret)\"\n"
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                Executables.security, arguments: ["-i"], stdin: Data(command.utf8), timeout: .seconds(10)
            )
        } catch {
            throw .commandFailed(exitCode: -1)
        }
        guard result.exitCode == 0, !result.timedOut else { throw .commandFailed(exitCode: result.exitCode) }
    }

    /// Returns nil when the item does not exist.
    public static func read(account: String) async throws(Failure) -> String? {
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                Executables.security,
                arguments: ["find-generic-password", "-s", service, "-a", account, "-w"],
                timeout: .seconds(10)
            )
        } catch {
            throw .commandFailed(exitCode: -1)
        }
        if result.exitCode == 44 { return nil } // errSecItemNotFound
        guard result.exitCode == 0, !result.timedOut else { throw .commandFailed(exitCode: result.exitCode) }
        return result.stdoutString.trimmingCharacters(in: .newlines)
    }

    public static func delete(account: String) async {
        _ = try? await ProcessRunner.run(
            Executables.security,
            arguments: ["delete-generic-password", "-s", service, "-a", account],
            timeout: .seconds(10)
        )
    }
}
