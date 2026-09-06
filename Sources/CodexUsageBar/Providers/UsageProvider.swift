import Foundation

enum UsageProvider: String, CaseIterable, Identifiable, Sendable, Codable {
    case codex
    case claude

    var id: String { rawValue }

    // Brand names — never localized.
    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }

    var dashboardURL: URL {
        switch self {
        case .codex: return URL(string: "https://chatgpt.com/codex/settings/usage")!
        case .claude: return URL(string: "https://claude.ai/settings/usage")!
        }
    }
}

struct RateWindow: Sendable, Codable {
    let usedPercent: Int
    let durationMinutes: Int?
    let resetsAt: Date?

    /// `usedPercent` as the servers report it can sit outside 0…100 (Codex
    /// briefly reports over 100 at the moment a window is exhausted), so
    /// both derived percentages are clamped and always sum to 100.
    var usedPercentClamped: Int { max(0, min(100, usedPercent)) }
    var remainingPercent: Int { 100 - usedPercentClamped }

    /// How far through the window we are, 0…1. Needs both the window's length
    /// and its reset time, so it is nil for the per-model weekly limits, whose
    /// length the endpoint doesn't state.
    func elapsedFraction(now: Date = Date()) -> Double? {
        guard let durationMinutes, durationMinutes > 0, let resetsAt else { return nil }
        let total = Double(durationMinutes) * 60
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining.isFinite else { return nil }
        return max(0, min(1, (total - remaining) / total))
    }

    /// The percentage a perfectly even burn would have reached by now — the
    /// "pace" mark the progress bars draw. Being past it means the window is
    /// being spent faster than it refills.
    func expectedUsedPercent(now: Date = Date()) -> Int? {
        guard let fraction = elapsedFraction(now: now) else { return nil }
        return Int((fraction * 100).rounded())
    }

    /// Used relative to elapsed: 1.0 is exactly on pace, 2.0 is burning twice
    /// as fast as the window refills. Nil until enough of the window has
    /// passed for the ratio to mean anything — early on, one request looks
    /// like an infinite burn rate.
    func paceRatio(now: Date = Date()) -> Double? {
        guard let fraction = elapsedFraction(now: now), fraction >= 0.1 else { return nil }
        return (Double(usedPercentClamped) / 100) / fraction
    }
}

/// An extra, provider-specific window (e.g. Claude's per-model weekly limits).
/// Empty for Codex.
struct NamedWindow: Sendable, Codable {
    let name: String
    let window: RateWindow
}

struct CreditInfo: Sendable, Codable {
    let balance: String?
    let unlimited: Bool
    let resetCount: Int
}

struct ProviderSnapshot: Sendable, Codable {
    let provider: UsageProvider
    let primary: RateWindow?
    let secondary: RateWindow?
    let extras: [NamedWindow]
    let plan: String?
    let credits: CreditInfo?
    let fetchedAt: Date
}

extension ProviderSnapshot {
    /// This snapshot with `plan` borrowed from `other` when it has none. A
    /// provider's on-disk cache carries the usage but not the account's plan
    /// (only the credentials know that), so an adopted cache entry would
    /// otherwise blank the plan line until the next network fetch.
    func fillingPlan(from other: ProviderSnapshot?) -> ProviderSnapshot {
        guard plan == nil, let inherited = other?.plan else { return self }
        return ProviderSnapshot(
            provider: provider,
            primary: primary,
            secondary: secondary,
            extras: extras,
            plan: inherited,
            credits: credits,
            fetchedAt: fetchedAt
        )
    }
}

enum UsageClientError: LocalizedError, Sendable {
    case codexNotFound
    case launchFailed(String)
    case timedOut
    case invalidResponse
    case server(String)
    case claudeCredentialsNotFound
    case claudeTokenExpired
    case claudeNotSubscribed
    case httpStatus(Int)
    /// HTTP 429 with the server's `Retry-After` in seconds when it sent one.
    /// Split out from `httpStatus` because it's the one status the store has
    /// to act on rather than just display.
    case rateLimited(TimeInterval?)
    case network(String)

    func message(language: AppLanguage) -> String {
        switch self {
        case .codexNotFound:
            return L10n.string("error_codex_not_found", language: language)
        case .launchFailed(let message):
            return L10n.format("error_launch_failed", language: language, message)
        case .timedOut:
            return L10n.string("error_timeout", language: language)
        case .invalidResponse:
            return L10n.string("error_invalid_response", language: language)
        case .server(let message):
            return L10n.format("error_server", language: language, message)
        case .claudeCredentialsNotFound:
            return L10n.string("error_claude_credentials_not_found", language: language)
        case .claudeTokenExpired:
            return L10n.string("error_claude_token_expired", language: language)
        case .claudeNotSubscribed:
            return L10n.string("error_claude_not_subscribed", language: language)
        case .httpStatus(let code):
            // A 401 almost always means the token expired between our expiry
            // check and the request landing, so point at the same remedy.
            if code == 401 {
                return L10n.string("error_claude_token_expired", language: language)
            }
            return L10n.format("error_http_status", language: language, code)
        case .rateLimited:
            return L10n.string("error_rate_limited", language: language)
        case .network(let message):
            return L10n.format("error_network", language: language, message)
        }
    }

    var errorDescription: String? { message(language: .system) }
}

protocol UsageProviderClient {
    static var provider: UsageProvider { get }
    /// Whether the provider's tooling is present on this machine.
    static func isInstalled() -> Bool
    /// A snapshot the provider's own tooling already fetched and left on disk,
    /// if it keeps one. Reading it costs nothing against the provider's rate
    /// limit, so the store checks it every cycle and only calls `fetch()` when
    /// it's missing or stale. Runs off the main actor and may do file IO.
    static func cachedSnapshot() -> ProviderSnapshot?
    static func fetch() throws -> ProviderSnapshot
    /// An opaque, cheap-to-read identity for the account currently signed in,
    /// when the provider can tell without spending a request. The store keys
    /// its rate-limit back-off on this: signing in as somebody else means the
    /// previous account's cooldown no longer applies, and holding it against
    /// the new one would hide fresh data for up to an hour. Nil means "can't
    /// tell", which the store treats as unchanged.
    static func accountIdentity() -> String?
}

extension UsageProviderClient {
    static func cachedSnapshot() -> ProviderSnapshot? { nil }
    static func accountIdentity() -> String? { nil }
}
