import AppKit
import Combine
import ServiceManagement

private let enabledProviders: [UsageProvider] = [.codex]

private func usageProviderClient(for provider: UsageProvider) -> any UsageProviderClient.Type {
    switch provider {
    case .codex: return CodexUsageClient.self
    }
}

/// Result of fetching one provider, kept fully Sendable so it can cross the
/// TaskGroup child-task boundary without carrying an existential `Error`.
private enum FetchOutcome: Sendable {
    case success(ProviderSnapshot)
    case clientError(UsageClientError)
    case other(String)
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var snapshots: [UsageProvider: ProviderSnapshot] = [:]
    @Published var errors: [UsageProvider: UsageClientError] = [:]
    @Published var isLoading = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var menuIconName: String {
        didSet { UserDefaults.standard.set(menuIconName, forKey: "menuIconName") }
    }
    @Published var menuIconSize: Double {
        didSet { UserDefaults.standard.set(menuIconSize, forKey: "menuIconSize") }
    }
    @Published var menuTextSize: Double {
        didSet { UserDefaults.standard.set(menuTextSize, forKey: "menuTextSize") }
    }
    @Published var touchBarEnabled: Bool {
        didSet { UserDefaults.standard.set(touchBarEnabled, forKey: "touchBarEnabled") }
    }
    @Published var touchBarWhenCodexActive: Bool {
        didSet { UserDefaults.standard.set(touchBarWhenCodexActive, forKey: "touchBarWhenCodexActive") }
    }
    @Published var appLanguage: AppLanguage {
        didSet { UserDefaults.standard.set(appLanguage.rawValue, forKey: "appLanguage") }
    }

    // Non-UsageClientError fetch failures, keyed the same way as `errors` so
    // errorMessage(for:) can fall back to them.
    @Published var otherErrors: [UsageProvider: String] = [:]

    // A settings action (currently just launch-at-login) is not a provider
    // fetch error, so it gets its own slot rather than borrowing a provider's.
    // Published so AppDelegate/UsageTouchBarController can observe it — a
    // launch-at-login failure doesn't touch isLoading or errors, so without
    // this it would silently fail to redraw.
    @Published var settingsErrorMessage: String?

    private var refreshTask: Task<Void, Never>?
    private var pendingRefresh = false

    init() {
        let defaults = UserDefaults.standard
        menuIconName = defaults.string(forKey: "menuIconName") ?? "gauge.with.dots.needle.67percent"
        menuIconSize = defaults.object(forKey: "menuIconSize") as? Double ?? 12
        menuTextSize = defaults.object(forKey: "menuTextSize") as? Double ?? 12
        touchBarEnabled = defaults.object(forKey: "touchBarEnabled") as? Bool ?? true
        touchBarWhenCodexActive = defaults.object(forKey: "touchBarWhenCodexActive") as? Bool ?? true
        appLanguage = defaults.string(forKey: "appLanguage").flatMap(AppLanguage.init(rawValue:)) ?? .system
        refresh()
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    func snapshot(for provider: UsageProvider) -> ProviderSnapshot? {
        snapshots[provider]
    }

    func errorMessage(for provider: UsageProvider) -> String? {
        // Re-derived from appLanguage on every access, so a language switch
        // re-localizes stored errors for free via the ObservableObject refresh.
        if let error = errors[provider] { return error.message(language: appLanguage) }
        return otherErrors[provider]
    }

    // Phase 1 has exactly one provider; these keep the existing UI call sites
    // (UsagePopover, AppDelegate, UsageTouchBarController) working unchanged.
    // settingsErrorMessage takes precedence, matching the old single
    // `errorMessage`'s last-write-wins behavior between a fetch failure and a
    // settings-action failure: refresh() clears settingsErrorMessage, so a
    // fetch failure after a settings failure wins; a settings failure after a
    // fetch failure wins here since it's checked first.
    var primarySnapshot: ProviderSnapshot? { snapshot(for: .codex) }
    var primaryErrorMessage: String? { settingsErrorMessage ?? errorMessage(for: .codex) }

    var menuTitle: String {
        if let snapshot = primarySnapshot {
            let fiveHour = snapshot.primary.map { "\($0.remainingPercent)%" } ?? "–"
            let weekly = snapshot.secondary.map { "\($0.remainingPercent)%" } ?? "–"
            return "\(fiveHour)·\(weekly)"
        }
        return isLoading ? "…" : "!"
    }

    func tr(_ key: String) -> String {
        L10n.string(key, language: appLanguage)
    }

    func tr(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: tr(key), locale: appLanguage.locale, arguments: arguments)
    }

    func formatDate(_ date: Date, includeDate: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.locale = appLanguage.locale
        formatter.setLocalizedDateFormatFromTemplate(includeDate ? "MdHm" : "Hm")
        return formatter.string(from: date)
    }

    /// Refreshes if the snapshot is older than `maxAge`, otherwise does nothing.
    func refreshIfStale(olderThan maxAge: TimeInterval = 60) {
        guard let snapshot = primarySnapshot else {
            refresh()
            return
        }
        if Date().timeIntervalSince(snapshot.fetchedAt) >= maxAge { refresh() }
    }

    func refresh() {
        // A request arriving mid-flight is queued rather than dropped, so a wake
        // or timer tick during a slow fetch still produces fresh data.
        guard !isLoading else {
            pendingRefresh = true
            return
        }
        pendingRefresh = false
        isLoading = true
        settingsErrorMessage = nil
        for provider in enabledProviders {
            errors[provider] = nil
            otherErrors[provider] = nil
        }

        Task {
            await withTaskGroup(of: (UsageProvider, FetchOutcome).self) { group in
                for provider in enabledProviders {
                    group.addTask {
                        do {
                            let snapshot = try await Task.detached(priority: .userInitiated) {
                                try usageProviderClient(for: provider).fetch()
                            }.value
                            return (provider, .success(snapshot))
                        } catch let error as UsageClientError {
                            return (provider, .clientError(error))
                        } catch {
                            return (provider, .other(error.localizedDescription))
                        }
                    }
                }
                for await (provider, outcome) in group {
                    switch outcome {
                    case .success(let snapshot):
                        snapshots[provider] = snapshot
                    case .clientError(let error):
                        errors[provider] = error
                    case .other(let message):
                        otherErrors[provider] = message
                    }
                }
            }
            isLoading = false
            if pendingRefresh { refresh() }
        }
    }

    func openDashboard() {
        NSWorkspace.shared.open(usageDashboardURL)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
        } catch {
            settingsErrorMessage = tr("error_launch_at_login", error.localizedDescription)
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
