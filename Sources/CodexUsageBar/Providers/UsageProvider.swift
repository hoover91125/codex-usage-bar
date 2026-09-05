import Foundation

enum UsageProvider: String, CaseIterable, Identifiable, Sendable {
    case codex
    // claude comes in Phase 2

    var id: String { rawValue }
}

struct RateWindow: Sendable {
    let usedPercent: Int
    let durationMinutes: Int?
    let resetsAt: Date?

    var remainingPercent: Int { max(0, min(100, 100 - usedPercent)) }
}

/// An extra, provider-specific window (e.g. Claude's per-model weekly limits).
/// Empty for Codex.
struct NamedWindow: Sendable {
    let name: String
    let window: RateWindow
}

struct CreditInfo: Sendable {
    let balance: String?
    let unlimited: Bool
    let resetCount: Int
}

struct ProviderSnapshot: Sendable {
    let provider: UsageProvider
    let primary: RateWindow?
    let secondary: RateWindow?
    let extras: [NamedWindow]
    let plan: String?
    let credits: CreditInfo?
    let fetchedAt: Date
}

enum UsageClientError: LocalizedError, Sendable {
    case codexNotFound
    case launchFailed(String)
    case timedOut
    case invalidResponse
    case server(String)

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
        }
    }

    var errorDescription: String? { message(language: .system) }
}

protocol UsageProviderClient {
    static var provider: UsageProvider { get }
    /// Whether the provider's tooling is present on this machine.
    static func isInstalled() -> Bool
    static func fetch() throws -> ProviderSnapshot
}
