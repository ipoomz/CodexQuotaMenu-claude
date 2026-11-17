import Foundation

enum ClaudeUsageParserTests {
    static func run() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let json = """
        {"five_hour":{"utilization":27.0,"resets_at":"2026-11-04T15:00:00.123456+00:00"},
         "seven_day":{"utilization":64.5,"resets_at":"2026-11-08T03:00:00Z"},
         "seven_day_opus":null,
         "seven_day_sonnet":{"utilization":10,"resets_at":null}}
        """.data(using: .utf8)!
        let snapshot = try! ClaudeUsageParser.parseUsage(json, planType: "max", now: now)

        precondition(snapshot.fiveHour?.usedPercent == 27)
        precondition(snapshot.fiveHour?.remainingPercentInt == 73)
        precondition(snapshot.weekly?.remainingPercentInt == 36)
        precondition(snapshot.fiveHour?.resetAt != nil)
        precondition(snapshot.weekly?.resetAt != nil)
        precondition(snapshot.weeklyOpus == nil)
        precondition(snapshot.weeklySonnet?.resetAt == nil)
        precondition(snapshot.planType == "max")

        let clamped = #"{"five_hour":{"utilization":140,"resets_at":null}}"#.data(using: .utf8)!
        let clampedSnapshot = try! ClaudeUsageParser.parseUsage(clamped, planType: nil, now: now)
        precondition(clampedSnapshot.fiveHour?.remainingPercentInt == 0)
        precondition(clampedSnapshot.weekly == nil)

        precondition((try? ClaudeUsageParser.parseUsage(Data("{}".utf8), planType: nil)) == nil)
        precondition((try? ClaudeUsageParser.parseUsage(Data("nope".utf8), planType: nil)) == nil)

        let credentials = #"{"claudeAiOauth":{"accessToken":"tok","subscriptionType":"pro"}}"#.data(using: .utf8)!
        let parsed = ClaudeUsageParser.parseCredentials(credentials)
        precondition(parsed?.accessToken == "tok")
        precondition(parsed?.planType == "pro")
        precondition(ClaudeUsageParser.parseCredentials(Data("{}".utf8)) == nil)

        let stale = ClaudeSnapshot.failure(ClaudeUsageError.unauthorized, previous: snapshot, now: now)
        precondition(stale.isStale && stale.hasAnyData && stale.errorMessage != nil)
        let empty = ClaudeSnapshot.failure(ClaudeUsageError.credentialsMissing, previous: nil, now: now)
        precondition(!empty.hasAnyData && !empty.isStale)

        precondition(claudeMenuBarTitle(fiveHourRemainingPercent: 73, weeklyRemainingPercent: 36)
            == "\u{00A0}5h73%\u{00A0}W36%")
        precondition(claudeMenuBarTitle(fiveHourRemainingPercent: nil, weeklyRemainingPercent: nil) == " --")

        precondition(ClaudeUsageParser.filteredCookieHeader(from: "sk-ant-sid01-abc") == "sessionKey=sk-ant-sid01-abc")
        precondition(
            ClaudeUsageParser.filteredCookieHeader(from: "Cookie: foo=1; sessionKey=sk-ant-x; cf_clearance=zz; _ga=9")
                == "sessionKey=sk-ant-x; cf_clearance=zz"
        )
        precondition(ClaudeUsageParser.filteredCookieHeader(from: "foo=1; _ga=9") == nil)
        precondition(ClaudeUsageParser.filteredCookieHeader(from: "") == nil)

        let orgs = #"[{"uuid":"api-org","capabilities":["api"]},{"uuid":"chat-org","capabilities":["chat"]}]"#.data(using: .utf8)!
        precondition(ClaudeUsageParser.parseOrganizationID(orgs) == "chat-org")
        precondition(ClaudeUsageParser.parseOrganizationID(Data("[]".utf8)) == nil)

        print("Claude usage parser tests passed")
    }
}
