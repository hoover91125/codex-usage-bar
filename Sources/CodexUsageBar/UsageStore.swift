import AppKit
import Combine
import ServiceManagement

func usageProviderClient(for provider: UsageProvider) -> any UsageProviderClient.Type {
    switch provider {
    case .codex: return CodexUsageClient.self
    case .claude: return ClaudeUsageClient.self
    }
}

/// Whether every percentage the app shows — menu bar title, popover rows,
/// Touch Bar items — is what is left of a window or what has been used.
/// Progress bars follow the same choice, so in `.used` they fill up as the
/// window is consumed. Absent `UserDefaults` key means `.remaining`, which
/// is the only thing the app showed before this existed.
enum UsageDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case remaining
    case used

    var id: String { rawValue }
}

/// How far a window's remaining budget has fallen relative to the two
/// user-set thresholds (`warningRemainingPercent` / `criticalRemainingPercent`).
/// The views pick the colors; this is the one shared rule, so the popover
/// and the Touch Bar can't disagree about when to change.
enum UsageAlertLevel: Sendable {
    case normal
    case warning
    case critical
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
    /// Only meaningful while `touchBarContent == .both`: swaps the four
    /// separate provider/window items for one grouped item per provider,
    /// which frees enough width to also show both providers' reset times.
    @Published var touchBarBothCompact: Bool {
        didSet { UserDefaults.standard.set(touchBarBothCompact, forKey: "touchBarBothCompact") }
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
    @Published var usageDisplayMode: UsageDisplayMode {
        didSet { UserDefaults.standard.set(usageDisplayMode.rawValue, forKey: "usageDisplayMode") }
    }
    /// Alert thresholds, always stored as *remaining* percent no matter what
    /// `usageDisplayMode` shows: a window at or below `warning` remaining is
    /// orange, at or below `critical` remaining is red. The settings UI
    /// presents them as "used ≥" in `.used` mode by flipping against 100, so
    /// switching modes never changes when a window actually turns color.
    /// Each setter keeps `critical <= warning`; the clamp writes through the
    /// other property's `didSet`, which then finds nothing left to fix.
    @Published var warningRemainingPercent: Int {
        didSet {
            UserDefaults.standard.set(warningRemainingPercent, forKey: "alertWarningRemainingPercent")
            if criticalRemainingPercent > warningRemainingPercent {
                criticalRemainingPercent = warningRemainingPercent
            }
        }
    }
    @Published var criticalRemainingPercent: Int {
        didSet {
            UserDefaults.standard.set(criticalRemainingPercent, forKey: "alertCriticalRemainingPercent")
            if warningRemainingPercent < criticalRemainingPercent {
                warningRemainingPercent = criticalRemainingPercent
            }
        }
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

    /// Snapshots and throttle state survive a relaunch. Without this, every
    /// restart looked like a fresh install: no `lastAttempt`, so Claude was
    /// fetched immediately, and a few restarts in a row was enough to earn a
    /// 429 no matter how conservative the in-process throttle was.
    private struct PersistedCache: Codable {
        var snapshots: [String: ProviderSnapshot]
        var lastAttempt: [String: Date]
        var cooldownUntil: [String: Date]
        // Optional so a cache written before this field existed still decodes.
        var rateLimitStreak: [String: Int]?
    }

    private static let cacheDefaultsKey = "usageCacheV1"

    // Attempt (not success) timestamps, so a failed request still counts
    // against the provider's throttle — it still cost a request.
    private var lastAttempt: [UsageProvider: Date] = [:]

    // A 429 is a hard "back off" signal from the server: the provider is
    // skipped until this deadline even under a forced refresh.
    private var cooldownUntil: [UsageProvider: Date] = [:]

    // Consecutive 429s per provider, so each cooldown can be longer than the
    // last while the server keeps refusing. Cleared by the next success.
    private var rateLimitStreak: [UsageProvider: Int] = [:]

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
        touchBarBothCompact = defaults.object(forKey: "touchBarBothCompact") as? Bool ?? false
        appLanguage = defaults.string(forKey: "appLanguage").flatMap(AppLanguage.init(rawValue:)) ?? .system
        providerEnabledCodex = defaults.object(forKey: "providerEnabledCodex") as? Bool ?? true
        providerEnabledClaude = defaults.object(forKey: "providerEnabledClaude") as? Bool ?? true
        menuBarSource = defaults.string(forKey: "menuBarSource").flatMap(UsageProvider.init(rawValue:)) ?? .codex
        usageDisplayMode = defaults.string(forKey: "usageDisplayMode").flatMap(UsageDisplayMode.init(rawValue:)) ?? .remaining
        // The defaults are the thresholds that were hardcoded before these
        // were settings. Stored values are clamped and re-ordered on the way
        // in so a hand-edited plist can't put red above orange.
        let storedWarning = defaults.object(forKey: "alertWarningRemainingPercent") as? Int ?? 25
        let storedCritical = defaults.object(forKey: "alertCriticalRemainingPercent") as? Int ?? 10
        let warning = max(0, min(100, storedWarning))
        warningRemainingPercent = warning
        criticalRemainingPercent = max(0, min(warning, storedCritical))

        // Before the first `refresh()`, so a relaunch inside a provider's
        // minimum interval shows the cached numbers and skips the request.
        loadCache()
        refresh()

        // The tick is deliberately shorter than any provider's minimum
        // interval: it decides only *when eligibility is checked*, while
        // `minimumRefreshInterval` decides who actually gets fetched. A tick
        // equal to the interval (the old 300s) meant a cycle that started a
        // fraction of a second late pushed the next Claude fetch out by a
        // whole extra period.
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
        }
    }

    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheDefaultsKey),
              let cache = try? JSONDecoder().decode(PersistedCache.self, from: data) else { return }

        let now = Date()
        for (raw, snapshot) in cache.snapshots {
            guard let provider = UsageProvider(rawValue: raw) else { continue }
            snapshots[provider] = snapshot
        }
        // A timestamp in the future can only come from a clock change, and
        // honouring one would throttle the provider until the clock caught up
        // — so those are dropped rather than trusted.
        for (raw, date) in cache.lastAttempt {
            guard let provider = UsageProvider(rawValue: raw), date <= now else { continue }
            lastAttempt[provider] = date
        }
        for (raw, date) in cache.cooldownUntil {
            guard let provider = UsageProvider(rawValue: raw),
                  date > now,
                  date.timeIntervalSince(now) <= maxBackoff else { continue }
            cooldownUntil[provider] = date
        }
        // The streak only means something mid-episode, so it's restored for
        // providers whose cooldown is still running; anyone else starts over.
        for (raw, count) in cache.rateLimitStreak ?? [:] {
            guard let provider = UsageProvider(rawValue: raw),
                  cooldownUntil[provider] != nil, count > 0 else { continue }
            rateLimitStreak[provider] = count
        }
    }

    private func saveCache() {
        var cache = PersistedCache(snapshots: [:], lastAttempt: [:], cooldownUntil: [:], rateLimitStreak: [:])
        for (provider, snapshot) in snapshots { cache.snapshots[provider.rawValue] = snapshot }
        for (provider, date) in lastAttempt { cache.lastAttempt[provider.rawValue] = date }
        for (provider, date) in cooldownUntil { cache.cooldownUntil[provider.rawValue] = date }
        for (provider, count) in rateLimitStreak { cache.rateLimitStreak?[provider.rawValue] = count }
        guard let data = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheDefaultsKey)
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
        let fiveHour = snapshot.primary.map { "\(displayPercent($0))%" } ?? "–"
        let weekly = snapshot.secondary.map { "\(displayPercent($0))%" } ?? "–"
        return "\(fiveHour)·\(weekly)"
    }

    /// The one number every surface prints for `window`, per
    /// `usageDisplayMode`. Progress bars use it too, so a bar and its label
    /// always agree.
    func displayPercent(_ window: RateWindow) -> Int {
        switch usageDisplayMode {
        case .remaining: return window.remainingPercent
        case .used: return window.usedPercentClamped
        }
    }

    /// The localized "%d%% remaining" / "%d%% used" line for `window`.
    func displayPercentText(_ window: RateWindow) -> String {
        tr(usageDisplayMode == .used ? "used" : "remaining", displayPercent(window))
    }

    /// Thresholds compare against what is *left*, whichever way the number
    /// is displayed — see `warningRemainingPercent`.
    func alertLevel(for window: RateWindow) -> UsageAlertLevel {
        let remaining = window.remainingPercent
        if remaining <= criticalRemainingPercent { return .critical }
        if remaining <= warningRemainingPercent { return .warning }
        return .normal
    }

    func tr(_ key: String) -> String {
        L10n.string(key, language: appLanguage)
    }

    func tr(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: tr(key), locale: appLanguage.locale, arguments: arguments)
    }

    func formatDate(_ date: Date, includeDate: Bool = true) -> String {
        L10n.formatDate(date, language: appLanguage, includeDate: includeDate)
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
    /// subprocess with nothing to throttle. Claude's `/api/oauth/usage` is
    /// rate limited per account, with the budget shared by every client
    /// signed in to it (Claude Code itself refreshes its on-disk copy at most
    /// every 5 minutes), so we match that cadence. That alone can't prevent a
    /// 429 — another client may have spent the budget — which is why the
    /// store prefers `cachedSnapshot()` and backs off harder on each 429.
    func minimumRefreshInterval(for provider: UsageProvider) -> TimeInterval {
        switch provider {
        case .codex: return 0
        case .claude: return 300
        }
    }

    /// The floor a *forced* refresh still respects. `force` exists so the
    /// popover's Refresh button feels immediate, but letting it bypass the
    /// throttle entirely means repeated taps go straight to Claude's rate
    /// limiter — so it shortens the window rather than removing it. Codex is
    /// a local subprocess, so there is nothing to protect.
    func forcedMinimumRefreshInterval(for provider: UsageProvider) -> TimeInterval {
        switch provider {
        case .codex: return 0
        case .claude: return 60
        }
    }

    /// Upper bound on a 429 back-off, so a server sending an implausible
    /// `Retry-After` (or a bad cached value) can't wedge a provider.
    private var maxBackoff: TimeInterval { 3600 }

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
        await adoptLocalSnapshots()

        let now = Date()
        var providersToFetch: [UsageProvider] = []
        for provider in enabledProviders {
            // A 429 cooldown is a hard skip, even under force.
            if let cooldown = cooldownUntil[provider], cooldown > now { continue }
            let floor = force
                ? forcedMinimumRefreshInterval(for: provider)
                : minimumRefreshInterval(for: provider)
            if let last = lastAttempt[provider], now.timeIntervalSince(last) < floor {
                continue
            }
            // Data younger than the floor — usually just adopted from the
            // provider's local cache — makes a request pointless.
            if let fetchedAt = snapshots[provider]?.fetchedAt, now.timeIntervalSince(fetchedAt) < floor {
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
                        rateLimitStreak[provider] = nil
                    case .clientError(let error):
                        errors[provider] = error
                        if let backoff = backoffInterval(for: error, provider: provider) {
                            cooldownUntil[provider] = Date().addingTimeInterval(backoff)
                        }
                    case .other(let message):
                        otherErrors[provider] = message
                    }
                }
            }
        }

        saveCache()
        isLoading = false
        if pendingRefresh {
            pendingRefresh = false
            let nextForce = pendingForce
            pendingForce = false
            refresh(force: nextForce)
        }
    }

    /// How long to skip a provider after a rate-limit response. A positive
    /// `Retry-After` is the server's own estimate, so it wins. Claude's usage
    /// endpoint, though, answers 429 with `Retry-After: 0` while the limit has
    /// been seen to persist for half an hour or more, so zero (or no header)
    /// is treated as "unknown": the wait starts at the provider's minimum
    /// interval and doubles on every consecutive 429 — 300s, 600s, 1200s,
    /// 2400s, then the cap — instead of the old flat 60s, which just spent
    /// another request into the same closed window.
    private func backoffInterval(for error: UsageClientError, provider: UsageProvider) -> TimeInterval? {
        let retryAfter: TimeInterval?
        switch error {
        case .rateLimited(let seconds): retryAfter = seconds
        case .httpStatus(429): retryAfter = nil
        default: return nil
        }
        let streak = (rateLimitStreak[provider] ?? 0) + 1
        rateLimitStreak[provider] = streak
        if let retryAfter, retryAfter > 0 {
            return min(max(retryAfter, 60), maxBackoff)
        }
        let base = max(minimumRefreshInterval(for: provider), 60)
        let doublings = min(streak - 1, 8)
        return min(base * pow(2, Double(doublings)), maxBackoff)
    }

    /// Free data first. A provider may keep its own copy of the usage on disk
    /// (Claude Code caches the endpoint's last response in its config file),
    /// and reading that costs nothing against the rate limit — so it's never
    /// throttled or cooled down, and is adopted whenever it's newer than what
    /// is on screen. A fresh number also supersedes a stale error message;
    /// any 429 cooldown stays in force.
    private func adoptLocalSnapshots() async {
        let providers = enabledProviders
        guard !providers.isEmpty else { return }
        let local = await Task.detached(priority: .utility) {
            var found: [UsageProvider: ProviderSnapshot] = [:]
            for provider in providers {
                if let snapshot = usageProviderClient(for: provider).cachedSnapshot() {
                    found[provider] = snapshot
                }
            }
            return found
        }.value
        for (provider, snapshot) in local {
            let current = snapshots[provider]
            guard snapshot.fetchedAt > (current?.fetchedAt ?? .distantPast) else { continue }
            snapshots[provider] = snapshot.fillingPlan(from: current)
            errors[provider] = nil
            otherErrors[provider] = nil
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
