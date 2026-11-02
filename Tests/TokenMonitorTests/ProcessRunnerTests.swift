import Foundation
import Testing
import TokenMonitorCore

@Suite struct ProcessRunnerTests {
    @Test func timeoutTerminatesAHungProcess() async throws {
        let start = ContinuousClock.now
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: .milliseconds(300))
        #expect(result.timedOut)
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func outputIsCapped() async throws {
        let result = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/yes"), arguments: [], timeout: .milliseconds(500), maxOutputBytes: 1000
        )
        #expect(result.stdout.count == 1000)
    }

    @Test func reportsNonZeroExit() async throws {
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/false"), arguments: [], timeout: .seconds(5))
        #expect(result.exitCode != 0)
        #expect(!result.timedOut)
    }

    @Test func passesStdinWithoutArgv() async throws {
        let result = try await ProcessRunner.run(
            URL(fileURLWithPath: "/bin/cat"), arguments: [], stdin: Data("secret\n".utf8), timeout: .seconds(5)
        )
        #expect(result.stdoutString == "secret\n")
    }

    @Test func grandchildHoldingStdoutDoesNotHang() async throws {
        let start = ContinuousClock.now
        let result = try await ProcessRunner.run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 5 & echo hi"], timeout: .seconds(10)
        )
        #expect(result.stdoutString == "hi\n")
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func childThatNeverReadsStdinStillTimesOut() async throws {
        let start = ContinuousClock.now
        let result = try await ProcessRunner.run(
            URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"],
            stdin: Data(count: 1_048_576), timeout: .milliseconds(300)
        )
        #expect(result.timedOut)
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func missingExecutableThrows() async {
        await #expect(throws: ProcessRunnerError.self) {
            try await ProcessRunner.run(URL(fileURLWithPath: "/nonexistent/tool"), arguments: [], timeout: .seconds(1))
        }
    }
}
