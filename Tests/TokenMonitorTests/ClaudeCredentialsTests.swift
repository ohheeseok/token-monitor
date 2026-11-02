import Foundation
import Testing
import TokenMonitorCore

@Suite struct ClaudeCredentialsTests {
    @Test func defaultProfileUsesBaseService() {
        #expect(ClaudeCredentials.serviceName(configDir: nil) == "Claude Code-credentials")
    }

    @Test func customDirUsesShortSHA256Suffix() {
        // sha256("/Users/test/.claude-work") prefix, computed independently with shasum.
        #expect(ClaudeCredentials.serviceName(configDir: "/Users/test/.claude-work") == "Claude Code-credentials-03abf0ee")
    }

    @Test func parsesClaudeAiOauthPayload() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"tok","refreshToken":"r","expiresAt":1793600000000,"subscriptionType":"max"}}"#
        let credential = try ClaudeCredentials.parse(Data(json.utf8), source: "test")
        #expect(credential.accessToken == "tok")
        #expect(credential.subscriptionType == "max")
    }

    @Test func rejectsPayloadWithoutOAuth() {
        #expect(throws: ClaudeCredentials.Failure.malformed) {
            try ClaudeCredentials.parse(Data(#"{"mcpOAuth":{}}"#.utf8), source: "test")
        }
    }
}
