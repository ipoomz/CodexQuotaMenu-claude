import Foundation

enum QuotaWindowKind: Equatable {
    case fiveHour
    case weekly
}

func quotaWindowKind(durationMinutes: Int?) -> QuotaWindowKind? {
    guard let durationMinutes else {
        return nil
    }

    switch durationMinutes {
    case 240...360:
        return .fiveHour
    case 6 * 24 * 60...8 * 24 * 60:
        return .weekly
    default:
        return nil
    }
}

func codexMenuBarTitle(fiveHourRemainingPercent: Int?, weeklyRemainingPercent: Int?) -> String {
    if let fiveHourRemainingPercent, let weeklyRemainingPercent {
        return "\u{00A0}5h\(fiveHourRemainingPercent)%\u{00A0}W\(weeklyRemainingPercent)%"
    }
    if let fiveHourRemainingPercent {
        return "\u{00A0}5h\(fiveHourRemainingPercent)%"
    }
    if let weeklyRemainingPercent {
        return "\u{00A0}W\(weeklyRemainingPercent)%"
    }
    return " --"
}

func singleLineMenuBarTitle(_ title: String) -> String {
    String(title.map { $0.isNewline ? " " : $0 })
}

struct BankedResetCredit: Equatable {
    let id: String
    let title: String?
    let resetType: String?
    let status: String
    let expiresAt: Date?
}

func bankedResetDisplayTitle(_ credit: BankedResetCredit) -> String {
    if let title = credit.title?.trimmingCharacters(in: .whitespacesAndNewlines),
       !title.isEmpty,
       !title.unicodeScalars.contains(where: isCJKUnifiedIdeograph) {
        return title
    }

    if let resetType = credit.resetType?.trimmingCharacters(in: .whitespacesAndNewlines),
       !resetType.isEmpty {
        if resetType.caseInsensitiveCompare("full") == .orderedSame {
            return "Full reset"
        }
        return resetType.replacingOccurrences(of: "_", with: " ").capitalized
    }

    return "Full reset"
}

private func isCJKUnifiedIdeograph(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3400...0x4DBF,
         0x4E00...0x9FFF,
         0xF900...0xFAFF,
         0x20000...0x2FA1F:
        return true
    default:
        return false
    }
}

struct BankedResetSummary: Equatable {
    let availableCount: Int
    let credits: [BankedResetCredit]

    var availableCredits: [BankedResetCredit] {
        credits
            .filter { $0.status == "available" }
            .sorted {
                let leftExpiry = $0.expiresAt ?? .distantFuture
                let rightExpiry = $1.expiresAt ?? .distantFuture
                if leftExpiry == rightExpiry {
                    return $0.id < $1.id
                }
                return leftExpiry < rightExpiry
            }
    }
}

enum BankedResetParseError: LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        "Codex returned unrecognized banked reset data"
    }
}

func parseBankedResetResponse(_ data: Data) throws -> BankedResetSummary {
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let availableCount = (json["available_count"] as? NSNumber)?.intValue,
          let rawCredits = json["credits"] as? [[String: Any]] else {
        throw BankedResetParseError.invalidResponse
    }

    let credits = try rawCredits.map { rawCredit in
        guard let id = rawCredit["id"] as? String,
              !id.isEmpty,
              let status = rawCredit["status"] as? String else {
            throw BankedResetParseError.invalidResponse
        }

        return BankedResetCredit(
            id: id,
            title: rawCredit["title"] as? String,
            resetType: rawCredit["reset_type"] as? String,
            status: status,
            expiresAt: parseISO8601Date(rawCredit["expires_at"] as? String)
        )
    }

    return BankedResetSummary(
        availableCount: max(0, availableCount),
        credits: credits
    )
}

func formatBankedResetExpiry(_ date: Date, timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd EEE HH:mm:ss"
    return formatter.string(from: date)
}

private func parseISO8601Date(_ value: String?) -> Date? {
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

struct UsageSnapshot {
    let sourceDate: Date
    let sourceName: String
    let planType: String?
    let fiveHourUsedPercent: Int?
    let weeklyUsedPercent: Int?
    let fiveHourWindowMinutes: Int?
    let weeklyWindowMinutes: Int?
    let fiveHourResetAt: Date?
    let weeklyResetAt: Date?
    let warningMessage: String?
    let errorMessage: String?
    var bankedResetSummary: BankedResetSummary? = nil
    var bankedResetErrorMessage: String? = nil

    var fiveHourRemainingPercent: Int? {
        fiveHourUsedPercent.map { max(0, min(100, 100 - $0)) }
    }

    var weeklyRemainingPercent: Int? {
        weeklyUsedPercent.map { max(0, min(100, 100 - $0)) }
    }
}
