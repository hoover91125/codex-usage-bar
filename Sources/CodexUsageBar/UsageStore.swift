import AppKit
import Combine
import ServiceManagement

func usageProviderClient(for provider: UsageProvider) -> any UsageProviderClient.Type {
    switch provider {
    case .codex: return CodexUsageClient.self
    case .claude: return ClaudeUsageClient.self
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
    @Published var touchBarDisplayMode: TouchBarDisplayMode {
        didSet { UserDefaults.standard.set(touchBarDisplayMode.rawValue, forKey: "touchBarDisplayMode") }
    }
    // Orthogonal to `touchBarDisplayMode` (when the bar shows, not what it
    // shows). No migration needed — an absent key means `.automatic`, which
    // is today's only behavior anyway.
    @Published var touchBarContent: TouchBarContent {
        didSet { UserDefaults.standard.set(touchBarContent.rawValue, forKey: "touchBarContent") }
    }
    @Published var appLanguage: AppLanguage {
        didSet { UserDefaults.standard.set(appLanguage.rawValue, forKey: "appLanguage") }
    }
    @Published var providerEnabledCodex: Bool {
        didSet { UserDefaults.standard.set(providerEnabledCodex, forKey: "providerEnabledCodex") }
    }
    @Published var providerEnabledClaude: Bool {
        didSet { UserDefaults.standard.set(providerEnabledClaude, forKey: "providerEnabledClaude") }
    }
    @Published var menuBarSource: UsageProvider {
        didSet { UserDefaults.standard.set(menuBarSource.rawValue, forKey: "menuBarSource") }
    }

    // Populated off the main actor at the start of every refresh cycle.
    // `isInstalled()` spawns a subprocess for both providers, so it must never
    // run from a computed property or view body — this cache is what those
    // read instead.
    @Published private(set) var installedProviders: Set<UsageProvider> = []

    // False until the first `refreshInstalledProviders()` completes, so the
    // popover can tell "not yet probed" (render as loading) apart from
    // "probed and genuinely missing" (render the unavailable line).
    @Published private(set) var installationProbed = false

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
    private var pendingForce = false

    // Attempt (not success) timestamps, so a failed request still counts
    // against the provider's throttle — it still cost a request.
    private var lastAttempt: [UsageProvider: Date] = [:]

    // A 429 is a hard "back off" signal from the server: the provider is
    // skipped until this deadline even under a forced refresh.
    private var cooldownUntil: [UsageProvider: Date] = [:]

    init() {
        let defaults = UserDefaults.standard
        menuIconName = defaults.string(forKey: "menuIconName") ?? "gauge.with.dots.needle.67percent"
        menuIconSize = defaults.object(forKey: "menuIconSize") as? Double ?? 12
        menuTextSize = defaults.object(forKey: "menuTextSize") as? Double ?? 12
        if let stored = defaults.string(forKey: "touchBarDisplayMode").flatMap(TouchBarDisplayMode.init(rawValue:)) {
            touchBarDisplayMode = stored
        } else if defaults.object(forKey: "touchBarEnabled") != nil {
            // One-time migration from the old two-boolean scheme. The old
            // keys are left untouched (unused from here on) so this stays
            // inspectable/reversible rather than destructive.
            let wasEnabled = defaults.bool(forKey: "touchBarEnabled")
            let wasCodexOnly = defaults.object(forKey: "touchBarWhenCodexActive") as? Bool ?? true
            let migrated: TouchBarDisplayMode = !wasEnabled ? .off : (wasCodexOnly ? .whenRelevantAppFrontmost : .always)
            touchBarDisplayMode = migrated
            defaults.set(migrated.rawValue, forKey: "touchBarDisplayMode")
        } else {
            touchBarDisplayMode = .always
        }
        touchBarContent = defaults.string(forKey: "touchBarContent").flatMap(TouchBarContent.init(rawValue:)) ?? .automatic
        appLanguage = defaults.string(forKey: "appLanguage").flatMap(AppLanguage.init(rawValue:)) ?? .system
        providerEnabledCodex = defaults.object(forKey: "providerEnabledCodex") as? Bool ?? true
        providerEnabledClaude = defaults.object(forKey: "providerEnabledClaude") as? Bool ?? true
        menuBarSource = defaults.string(forKey: "menuBarSource").flatMap(UsageProvider.init(rawValue:)) ?? .codex
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

    /// Providers the user has toggled on and that are actually present on
    /// this machine. This is the fetch list — it's right that it excludes a
    /// provider that can't be fetched. Reads the cached `installedProviders`
    /// rather than probing `isInstalled()` itself, so this is cheap to call
    /// from a view body.
    var enabledProviders: [UsageProvider] {
        UsageProvider.allCases.filter { isProviderEnabled($0) && installedProviders.contains($0) }
    }

    /// Providers the user has toggled on, regardless of whether they're
    /// installed. The popover iterates this (not `enabledProviders`) so a
    /// toggled-on-but-missing provider still gets a section that can explain
    /// itself, instead of silently vanishing.
    var toggledOnProviders: [UsageProvider] {
        UsageProvider.allCases.filter { isProviderEnabled($0) }
    }

    func isProviderEnabled(_ provider: UsageProvider) -> Bool {
        switch provider {
        case .codex: return providerEnabledCodex
        case .claude: return providerEnabledClaude
        }
    }

    func setProviderEnabled(_ enabled: Bool, for provider: UsageProvider) {
        switch provider {
        case .codex: providerEnabledCodex = enabled
        case .claude: providerEnabledClaude = enabled
        }
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

    var menuTitle: String {
        let provider = enabledProviders.contains(menuBarSource) ? menuBarSource : enabledProviders.first
        guard let provider, let snapshot = snapshot(for: provider) else {
            return isLoading ? "…" : "!"
        }
        let fiveHour = snapshot.primary.map { "\($0.remainingPercent)%" } ?? "–"
        let weekly = snapshot.secondary.map { "\($0.remainingPercent)%" } ?? "–"
        return "\(fiveHour)·\(weekly)"
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

    /// Refreshes if the oldest enabled provider's snapshot is older than
    /// `maxAge`, or if any enabled provider has no snapshot at all yet.
    func refreshIfStale(olderThan maxAge: TimeInterval = 60) {
        let providers = enabledProviders
        guard !providers.isEmpty else { return }
        let fetchedAts = providers.compactMap { snapshots[$0]?.fetchedAt }
        if fetchedAts.count < providers.count {
            refresh()
            return
        }
        if let oldest = fetchedAts.min(), Date().timeIntervalSince(oldest) >= maxAge {
            refresh()
        }
    }

    /// The floor between fetch attempts for a provider. Codex is a local
    /// subprocess with nothing to throttle; Claude's `/api/oauth/usage` is
    /// rate limited (Claude Code itself caches it for 5 minutes), so we match
    /// that cadence to avoid HTTP 429s.
    func minimumRefreshInterval(for provider: UsageProvider) -> TimeInterval {
        switch provider {
        case .codex: return 0
        case .claude: return 300
        }
    }

    /// `force: true` bypasses the per-provider throttle (but never the 429
    /// cooldown) — only the popover's manual Refresh button does this. The
    /// timer, the wake-from-sleep handler, and `refreshIfStale` all call the
    /// non-forced form.
    func refresh(force: Bool = false) {
        // A request arriving mid-flight is queued rather than dropped, so a
        // wake or timer tick during a slow fetch still produces fresh data.
        // A forced request must not be downgraded by a coalesced non-forced
        // one, so pendingForce only ever grows until it's consumed.
        guard !isLoading else {
            pendingRefresh = true
            pendingForce = pendingForce || force
            return
        }
        isLoading = true
        settingsErrorMessage = nil

        Task { [weak self] in
            await self?.runRefreshCycle(force: force)
        }
    }

    private func runRefreshCycle(force: Bool) async {
        await refreshInstalledProviders()

        let now = Date()
        var providersToFetch: [UsageProvider] = []
        for provider in enabledProviders {
            // A 429 cooldown is a hard skip, even under force.
            if let cooldown = cooldownUntil[provider], cooldown > now { continue }
            if !force, let last = lastAttempt[provider],
               now.timeIntervalSince(last) < minimumRefreshInterval(for: provider) {
                continue
            }
            providersToFetch.append(provider)
        }

        if !providersToFetch.isEmpty {
            for provider in providersToFetch {
                lastAttempt[provider] = Date()
                errors[provider] = nil
                otherErrors[provider] = nil
            }

            await withTaskGroup(of: (UsageProvider, FetchOutcome).self) { group in
                for provider in providersToFetch {
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
                        cooldownUntil[provider] = nil
                    case .clientError(let error):
                        errors[provider] = error
                        if case .httpStatus(429) = error {
                            cooldownUntil[provider] = Date().addingTimeInterval(60)
                        }
                    case .other(let message):
                        otherErrors[provider] = message
                    }
                }
            }
        }

        isLoading = false
        if pendingRefresh {
            pendingRefresh = false
            let nextForce = pendingForce
            pendingForce = false
            refresh(force: nextForce)
        }
    }

    private func refreshInstalledProviders() async {
        installedProviders = await Task.detached(priority: .utility) {
            Set(UsageProvider.allCases.filter { usageProviderClient(for: $0).isInstalled() })
        }.value
        installationProbed = true
    }

    func openDashboard(for provider: UsageProvider) {
        NSWorkspace.shared.open(provider.dashboardURL)
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
