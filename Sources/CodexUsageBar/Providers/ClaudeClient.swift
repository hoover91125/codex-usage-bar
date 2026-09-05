import Foundation

enum ClaudeUsageClient: UsageProviderClient {
    static let provider: UsageProvider = .claude

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let requestTimeout: TimeInterval = 15
    // Created once and reused: URLSession(configuration:) is retained until
    // invalidated, so a fresh one per fetch() call would leak every refresh.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        return URLSession(configuration: config)
    }()

    static func isInstalled() -> Bool {
        ClaudeCredentialStore.isAvailable()
    }

    /// Claude Code's own on-disk copy of the usage response (see
    /// `ClaudeCodeUsageCache`). No credentials are touched here: the plan
    /// isn't in the cache, and the store fills it in from the last snapshot.
    static func cachedSnapshot() -> ProviderSnapshot? {
        guard let entry = ClaudeCodeUsageCache.load() else { return nil }
        return try? parse(entry.utilization, plan: nil, fetchedAt: entry.fetchedAt)
    }

    static func fetch() throws -> ProviderSnapshot {
        let credentials = try ClaudeCredentialStore.load()
        if credentials.isExpired {
            throw UsageClientError.claudeTokenExpired
        }

        var request = URLRequest(url: usageURL, timeoutInterval: requestTimeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseHTTP: HTTPURLResponse?
        var transportError: Error?

        let task = session.dataTask(with: request) { data, response, error in
            responseData = data
            responseHTTP = response as? HTTPURLResponse
            transportError = error
            semaphore.signal()
        }
        task.resume()

        // fetch() runs off the main actor (a detached Task), so blocking here
        // is safe; it never waits on the queue that would need to deliver the
        // completion handler.
        if semaphore.wait(timeout: .now() + requestTimeout + 2) == .timedOut {
            task.cancel()
            throw UsageClientError.timedOut
        }

        if let transportError {
            throw UsageClientError.network(transportError.localizedDescription)
        }
        guard let http = responseHTTP, let data = responseData else {
            throw UsageClientError.invalidResponse
        }
        if http.statusCode == 429 {
            throw UsageClientError.rateLimited(retryAfterSeconds(http))
        }
        guard (200...299).contains(http.statusCode) else {
            throw UsageClientError.httpStatus(http.statusCode)
        }

        return try parse(data, plan: credentials.subscriptionType)
    }

    /// `Retry-After` is either a delay in seconds or an HTTP date; both forms
    /// are accepted, and anything else (or a header the server didn't send)
    /// leaves the back-off length to the caller.
    private static func retryAfterSeconds(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) {
            return max(0, seconds)
        }
        guard let date = httpDateFormatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    private static func parse(_ data: Data, plan: String?) throws -> ProviderSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageClientError.invalidResponse
        }
        return try parse(json, plan: plan, fetchedAt: Date())
    }

    /// Shared by the network response and Claude Code's cached copy of it,
    /// which have the same shape.
    private static func parse(_ json: [String: Any], plan: String?, fetchedAt: Date) throws -> ProviderSnapshot {
        let primary = window(json["five_hour"], durationMinutes: 300)
        let secondary = window(json["seven_day"], durationMinutes: 10080)

        var extras: [NamedWindow] = []
        if let opus = window(json["seven_day_opus"]) {
            extras.append(NamedWindow(name: "Opus", window: opus))
        }
        if let sonnet = window(json["seven_day_sonnet"]) {
            extras.append(NamedWindow(name: "Sonnet", window: sonnet))
        }
        if let limits = json["limits"] as? [[String: Any]] {
            for limit in limits {
                guard limit["kind"] as? String == "weekly_scoped",
                      let percent = numberValue(limit["percent"]) else { continue }
                let name = (limit["scope"] as? [String: Any])
                    .flatMap { $0["model"] as? [String: Any] }
                    .flatMap { $0["display_name"] as? String } ?? "Weekly"
                let resetsAt = (limit["resets_at"] as? String).flatMap(parseDate)
                extras.append(NamedWindow(
                    name: name,
                    window: RateWindow(
                        usedPercent: clampedPercent(percent),
                        durationMinutes: nil,
                        resetsAt: resetsAt
                    )
                ))
            }
        }

        guard primary != nil || secondary != nil || !extras.isEmpty else {
            throw UsageClientError.claudeNotSubscribed
        }

        return ProviderSnapshot(
            provider: .claude,
            primary: primary,
            secondary: secondary,
            extras: extras,
            plan: plan,
            credits: creditInfo(from: json["extra_usage"] as? [String: Any]),
            fetchedAt: fetchedAt
        )
    }

    private static func window(_ value: Any?, durationMinutes: Int? = nil) -> RateWindow? {
        guard let object = value as? [String: Any],
              let utilization = numberValue(object["utilization"]) else {
            return nil
        }
        let resetsAt = (object["resets_at"] as? String).flatMap(parseDate)
        return RateWindow(usedPercent: clampedPercent(utilization), durationMinutes: durationMinutes, resetsAt: resetsAt)
    }

    private static func creditInfo(from extraUsage: [String: Any]?) -> CreditInfo? {
        guard let extraUsage else { return nil }
        let isEnabled = extraUsage["is_enabled"] as? Bool ?? false
        let monthlyLimit = numberValue(extraUsage["monthly_limit"])
        let usedCredits = numberValue(extraUsage["used_credits"])
        let currency = extraUsage["currency"] as? String ?? ""

        var balance: String?
        if let usedCredits, let monthlyLimit {
            let used = formatCredits(usedCredits)
            let limit = formatCredits(monthlyLimit)
            balance = currency.isEmpty ? "\(used) / \(limit)" : "\(used) / \(limit) \(currency)"
        }

        return CreditInfo(
            balance: balance,
            unlimited: monthlyLimit == nil && isEnabled,
            resetCount: 0
        )
    }

    private static func formatCredits(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    private static func numberValue(_ value: Any?) -> Double? {
        if value is NSNull { return nil }
        return (value as? NSNumber)?.doubleValue
    }

    private static func clampedPercent(_ value: Double) -> Int {
        max(0, min(100, Int(floor(value))))
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: string)
    }
}
