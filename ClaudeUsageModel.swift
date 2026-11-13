import Foundation

enum ClaudeUsageError: LocalizedError, Equatable {
    case credentialsMissing
    case unauthorized
    case network(String)
    case api(Int)
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .credentialsMissing:
            return "Claude Code sign-in was not found. Run `claude` and log in."
        case .unauthorized:
            return "Claude Code session expired. Open Claude Code to refresh it."
        case let .network(message):
            return "Claude network error: \(message)"
        case let .api(status):
            return "Claude usage API returned HTTP \(status)"
        case .parseFailed:
            return "Claude usage data could not be parsed"
        }
    }
}

struct ClaudeUsageWindow: Equatable {
    let usedPercent: Double
    let resetAt: Date?

    var remainingPercentInt: Int {
        Int(max(0, min(100, 100 - usedPercent)).rounded())
    }
}

struct ClaudeSnapshot: Equatable {
    let fiveHour: ClaudeUsageWindow?
    let weekly: ClaudeUsageWindow?
    let weeklyOpus: ClaudeUsageWindow?
    let weeklySonnet: ClaudeUsageWindow?
    let planType: String?
    let lastUpdated: Date
    let isStale: Bool
    let errorMessage: String?

    var hasAnyData: Bool {
        fiveHour != nil || weekly != nil
    }

    static func failure(_ error: Error, previous: ClaudeSnapshot?, now: Date = Date()) -> ClaudeSnapshot {
        if let previous, previous.hasAnyData {
            return ClaudeSnapshot(
                fiveHour: previous.fiveHour,
                weekly: previous.weekly,
                weeklyOpus: previous.weeklyOpus,
                weeklySonnet: previous.weeklySonnet,
                planType: previous.planType,
                lastUpdated: previous.lastUpdated,
                isStale: true,
                errorMessage: error.localizedDescription
            )
        }
        return ClaudeSnapshot(
            fiveHour: nil,
            weekly: nil,
            weeklyOpus: nil,
            weeklySonnet: nil,
            planType: nil,
            lastUpdated: now,
            isStale: false,
            errorMessage: error.localizedDescription
        )
    }
}

enum ClaudeUsageParser {
    /// Parses the response of `GET https://api.anthropic.com/api/oauth/usage`.
    /// `utilization` is the used percentage (0-100); `resets_at` is ISO 8601.
    static func parseUsage(_ data: Data, planType: String?, now: Date = Date()) throws -> ClaudeSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeUsageError.parseFailed
        }

        let fiveHour = window(json["five_hour"])
        let weekly = window(json["seven_day"])
        guard fiveHour != nil || weekly != nil else {
            throw ClaudeUsageError.parseFailed
        }

        return ClaudeSnapshot(
            fiveHour: fiveHour,
            weekly: weekly,
            weeklyOpus: window(json["seven_day_opus"]),
            weeklySonnet: window(json["seven_day_sonnet"]),
            planType: planType,
            lastUpdated: now,
            isStale: false,
            errorMessage: nil
        )
    }

    /// Extracts the OAuth access token and subscription type from the JSON that
    /// Claude Code stores under the `Claude Code-credentials` Keychain item.
    static func parseCredentials(_ data: Data) -> (accessToken: String, planType: String?)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            return nil
        }
        return (token, oauth["subscriptionType"] as? String)
    }

    private static func window(_ value: Any?) -> ClaudeUsageWindow? {
        guard let dict = value as? [String: Any],
              let utilization = (dict["utilization"] as? NSNumber)?.doubleValue else {
            return nil
        }
        return ClaudeUsageWindow(
            usedPercent: max(0, min(100, utilization)),
            resetAt: parseDate(dict["resets_at"] as? String)
        )
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

func claudeMenuBarTitle(fiveHourRemainingPercent: Int?, weeklyRemainingPercent: Int?) -> String {
    switch (fiveHourRemainingPercent, weeklyRemainingPercent) {
    case let (five?, week?):
        return "\u{00A0}5h\(five)%\u{00A0}W\(week)%"
    case let (five?, nil):
        return "\u{00A0}5h\(five)%"
    case let (nil, week?):
        return "\u{00A0}W\(week)%"
    default:
        return " --"
    }
}
