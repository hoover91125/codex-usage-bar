import Foundation

/// Claude Code's own copy of the `/api/oauth/usage` response. It keeps the
/// last one in its config file (`~/.claude.json`, or `.claude.json` inside
/// `CLAUDE_CONFIG_DIR`) under `cachedUsageUtilization`, refreshes it at most
/// every five minutes, and trusts it for up to an hour. Reading it costs no
/// request against the endpoint's per-account rate limit — a budget shared by
/// every client signed in to the account — so it's preferred over the network
/// whenever it's fresh. The file is only ever read; nothing else in it is
/// looked at.
enum ClaudeCodeUsageCache {
    struct Entry {
        /// Same shape as the endpoint's JSON body.
        let utilization: [String: Any]
        let fetchedAt: Date
    }

    static func configFilePath() -> String {
        let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        return (configDir ?? NSHomeDirectory()) + "/.claude.json"
    }

    /// The cached utilization, or nil when the file, the entry, or its account
    /// can't be trusted.
    static func load() -> Entry? {
        guard let data = FileManager.default.contents(atPath: configFilePath()),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cached = json["cachedUsageUtilization"] as? [String: Any],
              let fetchedAtMs = (cached["fetchedAtMs"] as? NSNumber)?.doubleValue,
              let utilization = cached["utilization"] as? [String: Any] else {
            return nil
        }
        // Claude Code stamps the entry with the account it belongs to and
        // drops it after an account switch; mirror that so numbers from a
        // previous login are never shown as the current account's.
        if let cachedAccount = cached["accountUuid"] as? String,
           let currentAccount = (json["oauthAccount"] as? [String: Any])?["accountUuid"] as? String,
           cachedAccount != currentAccount {
            return nil
        }
        let fetchedAt = Date(timeIntervalSince1970: fetchedAtMs / 1000)
        // A timestamp in the future can only come from a clock change, and
        // honouring one would pin the display to it until the clock caught up.
        guard fetchedAt <= Date() else { return nil }
        return Entry(utilization: utilization, fetchedAt: fetchedAt)
    }
}
