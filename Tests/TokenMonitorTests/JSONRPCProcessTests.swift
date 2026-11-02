import Foundation
import Testing
import TokenMonitorCore

@Suite struct JSONRPCProcessTests {
    /// Answers request 2 before request 1, then exits right after writing the last response.
    static let outOfOrderServer = """
    import json, sys
    reqs = [json.loads(sys.stdin.readline()) for _ in range(2)]
    for r in reversed(reqs):
        sys.stdout.write(json.dumps({"id": r["id"], "result": {"method": r["method"]}}) + "\\n")
    sys.stdout.flush()
    """

    @Test func concurrentRequestsGetTheirOwnResponsesEvenAtExit() async throws {
        let rpc = JSONRPCProcess(
            executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-I", "-c", Self.outOfOrderServer]
        )
        try rpc.start()
        defer { rpc.stop() }
        async let first = rpc.request("first", timeout: .seconds(10))
        async let second = rpc.request("second", timeout: .seconds(10))
        let (a, b) = try await (first, second)
        #expect(String(decoding: a, as: UTF8.self).contains("first"))
        #expect(String(decoding: b, as: UTF8.self).contains("second"))
    }

    @Test func requestAfterExitFailsFast() async throws {
        let rpc = JSONRPCProcess(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
        try rpc.start()
        defer { rpc.stop() }
        try await Task.sleep(for: .milliseconds(200))
        await #expect(throws: JSONRPCProcess.Failure.self) {
            try await rpc.request("anything", timeout: .seconds(10))
        }
    }

    @Test func rpcErrorDescriptionHidesServerMessage() {
        let failure = JSONRPCProcess.Failure.rpcError(code: -32000, message: "token sk-secret is invalid")
        #expect(!"\(failure)".contains("secret"))
    }
}
