import AppKit
import Combine
import ObjectiveC

enum TouchBarSystemModal {
    private static let presentSelector = NSSelectorFromString(
        "presentSystemModalTouchBar:placement:systemTrayItemIdentifier:"
    )
    private static let dismissSelector = NSSelectorFromString("dismissSystemModalTouchBar:")

    static var isAvailable: Bool {
        class_getClassMethod(NSTouchBar.self, presentSelector) != nil &&
            class_getClassMethod(NSTouchBar.self, dismissSelector) != nil
    }

    static func present(_ touchBar: NSTouchBar) -> Bool {
        guard let method = class_getClassMethod(NSTouchBar.self, presentSelector) else {
            return false
        }
        typealias Function = @convention(c) (
            AnyObject,
            Selector,
            NSTouchBar,
            Int,
            NSString
        ) -> Void
        let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
        function(
            NSTouchBar.self,
            presentSelector,
            touchBar,
            1,
            "com.local.codexusagebar.touchbar" as NSString
        )
        return true
    }

    static func dismiss(_ touchBar: NSTouchBar) {
        guard let method = class_getClassMethod(NSTouchBar.self, dismissSelector) else { return }
        typealias Function = @convention(c) (AnyObject, Selector, NSTouchBar) -> Void
        let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
        function(NSTouchBar.self, dismissSelector, touchBar)
    }
}

private extension NSTouchBarItem.Identifier {
    static let fiveHourUsage = NSTouchBarItem.Identifier("com.local.codexusagebar.five-hour")
    static let weeklyUsage = NSTouchBarItem.Identifier("com.local.codexusagebar.weekly")
    static let resetTimes = NSTouchBarItem.Identifier("com.local.codexusagebar.reset-times")
    static let refreshUsage = NSTouchBarItem.Identifier("com.local.codexusagebar.refresh")
    // `.both` content mode shows up to four items at once (each provider's two
    // windows), so each provider/window pair needs its own identifier — the
    // single generic `fiveHourUsage`/`weeklyUsage` pair above stays reserved
    // for `.automatic`, unchanged widths and all.
    static let codexFiveHour = NSTouchBarItem.Identifier("com.local.codexusagebar.codex-five-hour")
    static let codexWeekly = NSTouchBarItem.Identifier("com.local.codexusagebar.codex-weekly")
    static let claudeFiveHour = NSTouchBarItem.Identifier("com.local.codexusagebar.claude-five-hour")
    static let claudeWeekly = NSTouchBarItem.Identifier("com.local.codexusagebar.claude-weekly")
}

/// What the Touch Bar shows, orthogonal to `TouchBarDisplayMode` (which
/// controls *when* it appears). `.automatic` is today's single-provider
/// behavior via `effectiveTouchBarSource`; `.both` shows Codex and Claude side
/// by side at narrower widths. Absent `UserDefaults` key means `.automatic` —
/// no migration needed since this preference didn't exist before.
enum TouchBarContent: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case both

    var id: String { rawValue }
}

/// How the system-modal Touch Bar is presented. `whenRelevantAppFrontmost`
/// is the old behavior (now driven by the expanded app list below); `always`
/// keeps it up regardless of what's frontmost; `off` never presents it.
enum TouchBarDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case always
    case whenRelevantAppFrontmost
    case off

    var id: String { rawValue }
}

/// Bundle identifiers of apps a user might plausibly be running Codex or
/// Claude from, mapped to the provider that implies — best-effort, since a
/// generic editor or terminal being frontmost doesn't actually mean Codex or
/// Claude is running inside it and there's no reliable way to detect that.
/// Those entries map to `nil`: frontmost enough to count as "relevant" (so
/// the Touch Bar stays up in `whenRelevantAppFrontmost` mode) but not
/// specific enough to pick a provider, so item content falls back to
/// `menuBarSource` while one of these is frontmost.
private let relevantAppProviders: [String: UsageProvider?] = [
    "com.openai.codex": .codex,
    "com.openai.chat": .codex,
    "com.anthropic.claudefordesktop": .claude,
    "com.microsoft.VSCode": nil,
    "com.microsoft.VSCodeInsiders": nil,
    "com.todesktop.230313mzl4w4u92": nil, // Cursor
    "com.apple.Terminal": nil,
    "com.googlecode.iterm2": nil,
    "com.mitchellh.ghostty": nil,
    "com.github.wez.wezterm": nil,
    "io.alacritty": nil,
    "dev.warp.Warp-Stable": nil
]

final class TouchBarProgressView: NSView {
    var value: Double = 0 {
        didSet { needsDisplay = true }
    }
    var tintColor: NSColor = .controlAccentColor {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 145, height: 5) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 0, dy: 0.5)
        let radius = rect.height / 2
        NSColor.labelColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

        let fraction = max(0, min(1, value / 100))
        guard fraction > 0 else { return }
        let fillRect = NSRect(x: rect.minX, y: rect.minY, width: rect.width * fraction, height: rect.height)
        tintColor.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
    }
}

@MainActor
final class UsageTouchBarController: NSObject, NSTouchBarDelegate {
    let touchBar = NSTouchBar()

    private let store: UsageStore
    private var fiveHourLabel: NSTextField?
    private var fiveHourProgress: TouchBarProgressView?
    private var weeklyLabel: NSTextField?
    private var weeklyProgress: TouchBarProgressView?
    private var resetLabel: NSTextField?
    private var refreshButton: NSButton?
    // `.both` content mode's four items — populated only while those
    // identifiers are actually in the bar (see `defaultItemIdentifiers(for:)`).
    private var codexFiveHourLabel: NSTextField?
    private var codexFiveHourProgress: TouchBarProgressView?
    private var codexWeeklyLabel: NSTextField?
    private var codexWeeklyProgress: TouchBarProgressView?
    private var claudeFiveHourLabel: NSTextField?
    private var claudeFiveHourProgress: TouchBarProgressView?
    private var claudeWeeklyLabel: NSTextField?
    private var claudeWeeklyProgress: TouchBarProgressView?
    private var subscriptions = Set<AnyCancellable>()
    private var systemModalVisible = false

    // `.automatic` mode's original widths — unchanged by this feature.
    private static let automaticItemWidth: CGFloat = 155
    private static let automaticProgressWidth: CGFloat = 145

    // `.both` mode needs four items to fit alongside the refresh button, so
    // these are narrower. Sized against the worst-case label text measured
    // with `NSAttributedString.size(withAttributes:)` against the real label
    // font (`.monospacedDigitSystemFont(ofSize: 12, weight: .medium)`) across
    // all six languages and both providers: "Cdx Sem 100%" (Codex + Spanish's
    // "Sem" weekly prefix + a 3-digit percent) measures ~89.6pt. 112pt leaves
    // a ~104pt label area — comfortable headroom without being sized to fill
    // the ~685pt Control-Strip budget (four items this size plus spacers and
    // the refresh button land around 525pt, well short of that).
    private static let bothItemWidth: CGFloat = 112
    private static let bothProgressWidth: CGFloat = 96

    // Whether the frontmost app is in `relevantAppProviders` at all (any
    // value, including a nil/generic entry) — gates system-modal visibility
    // in `.whenRelevantAppFrontmost` mode.
    private var relevantAppIsFrontmost = false

    // The specific provider the frontmost app implies, if any. Only a subset
    // of `relevantAppProviders` resolves to one; a generic editor/terminal
    // (or an app not in the list at all) leaves this nil, which falls back
    // to `menuBarSource` for item content.
    private var frontmostImpliedProvider: UsageProvider?

    init(store: UsageStore) {
        self.store = store
        super.init()

        touchBar.delegate = self
        touchBar.customizationIdentifier = NSTouchBar.CustomizationIdentifier(
            "com.local.codexusagebar.usage"
        )
        // Left for `rebuildDefaultItemIdentifiersIfNeeded()` (called from the
        // first `updateItems()` below) to populate for the actual starting
        // content plan, rather than hardcoding the `.automatic` set here.

        Publishers.CombineLatest4(store.$snapshots, store.$isLoading, store.$errors, store.$otherErrors)
            .combineLatest(store.$settingsErrorMessage)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.updateItems() }
            .store(in: &subscriptions)

        store.$appLanguage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateItems() }
            .store(in: &subscriptions)

        store.$menuBarSource
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateItems() }
            .store(in: &subscriptions)

        // `effectiveTouchBarSource`'s fallback (mirroring `menuTitle`'s) reads
        // `enabledProviders`, which is derived from these three — so they
        // need their own trigger for item content, same as AppDelegate's
        // status item does for the menu bar title.
        Publishers.CombineLatest3(store.$providerEnabledCodex, store.$providerEnabledClaude, store.$installedProviders)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.updateItems() }
            .store(in: &subscriptions)

        // Orthogonal to `touchBarDisplayMode` (when the bar shows) — this is
        // what it shows, and it changes the item set itself, so it goes
        // through `updateItems()` (which recomputes `defaultItemIdentifiers`)
        // rather than `applyPresentationMode()`.
        store.$touchBarContent
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateItems() }
            .store(in: &subscriptions)

        store.$touchBarDisplayMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyPresentationMode() }
            .store(in: &subscriptions)

        NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didActivateApplicationNotification
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.updateFrontmostApp(bundleIdentifier: application?.bundleIdentifier)
            self?.updateItems()
            self?.applyPresentationMode()
        }
        .store(in: &subscriptions)

        updateFrontmostApp(bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        updateItems()
        applyPresentationMode()
    }

    /// Looks up the frontmost app's bundle identifier in `relevantAppProviders`
    /// and updates both the visibility gate and the content-selection hint.
    /// A bundle id absent from the map (e.g. Finder) and one present but
    /// mapped to `nil` (e.g. VS Code) both leave `frontmostImpliedProvider`
    /// nil — only the former also clears `relevantAppIsFrontmost`.
    private func updateFrontmostApp(bundleIdentifier: String?) {
        guard let bundleIdentifier, let implied = relevantAppProviders[bundleIdentifier] else {
            relevantAppIsFrontmost = false
            frontmostImpliedProvider = nil
            return
        }
        relevantAppIsFrontmost = true
        frontmostImpliedProvider = implied
    }

    deinit {
        if systemModalVisible {
            TouchBarSystemModal.dismiss(touchBar)
        }
    }

    /// Explicit teardown for paths that don't go through `deinit` — a process
    /// killed by a signal never runs it, and a system-modal Touch Bar left
    /// presented past that point stays blank until ControlStrip/TouchBarServer
    /// restarts. Harmless to call when nothing is presented (mode `.off`, or
    /// Touch Bar hardware unavailable) since it's gated on the same flag.
    func teardown() {
        guard systemModalVisible else { return }
        TouchBarSystemModal.dismiss(touchBar)
        systemModalVisible = false
    }

    func touchBar(
        _ touchBar: NSTouchBar,
        makeItemForIdentifier identifier: NSTouchBarItem.Identifier
    ) -> NSTouchBarItem? {
        switch identifier {
        case .fiveHourUsage:
            let title = store.tr("five_hour_short")
            let result = makeUsageItem(
                identifier: identifier,
                initialTitle: title,
                itemWidth: Self.automaticItemWidth,
                progressWidth: Self.automaticProgressWidth,
                customizationLabel: store.tr("quota_customization", title)
            )
            fiveHourLabel = result.label
            fiveHourProgress = result.progress
            updateItems()
            return result.item
        case .weeklyUsage:
            let title = store.tr("weekly_short")
            let result = makeUsageItem(
                identifier: identifier,
                initialTitle: title,
                itemWidth: Self.automaticItemWidth,
                progressWidth: Self.automaticProgressWidth,
                customizationLabel: store.tr("quota_customization", title)
            )
            weeklyLabel = result.label
            weeklyProgress = result.progress
            updateItems()
            return result.item
        case .codexFiveHour, .codexWeekly, .claudeFiveHour, .claudeWeekly:
            let provider: UsageProvider = (identifier == .codexFiveHour || identifier == .codexWeekly) ? .codex : .claude
            let isWeekly = identifier == .codexWeekly || identifier == .claudeWeekly
            let title = isWeekly ? store.tr("weekly_short") : store.tr("five_hour_short")
            // Brand names aren't localized, so this is built directly rather
            // than reusing `quota_customization` (whose localized template
            // hardcodes the word "Codex" — fine for the two `.automatic`
            // items above, wrong for a Claude item).
            let result = makeUsageItem(
                identifier: identifier,
                initialTitle: title,
                itemWidth: Self.bothItemWidth,
                progressWidth: Self.bothProgressWidth,
                customizationLabel: "\(provider.displayName) \(title)"
            )
            switch identifier {
            case .codexFiveHour:
                codexFiveHourLabel = result.label
                codexFiveHourProgress = result.progress
            case .codexWeekly:
                codexWeeklyLabel = result.label
                codexWeeklyProgress = result.progress
            case .claudeFiveHour:
                claudeFiveHourLabel = result.label
                claudeFiveHourProgress = result.progress
            case .claudeWeekly:
                claudeWeeklyLabel = result.label
                claudeWeeklyProgress = result.progress
            default:
                break
            }
            updateItems()
            return result.item
        case .resetTimes:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let label = NSTextField(labelWithString: store.tr("loading_reset"))
            label.font = .systemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.lineBreakMode = .byTruncatingMiddle
            label.widthAnchor.constraint(equalToConstant: 245).isActive = true
            item.view = label
            item.customizationLabel = store.tr("reset_customization")
            resetLabel = label
            updateItems()
            return item
        case .refreshUsage:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let button = NSButton(
                image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: store.tr("refresh_usage"))!,
                target: self,
                action: #selector(refreshUsage)
            )
            button.bezelColor = .controlAccentColor
            item.view = button
            item.customizationLabel = store.tr("refresh_codex_usage")
            refreshButton = button
            updateItems()
            return item
        default:
            return nil
        }
    }

    private func makeUsageItem(
        identifier: NSTouchBarItem.Identifier,
        initialTitle: String,
        itemWidth: CGFloat,
        progressWidth: CGFloat,
        customizationLabel: String
    ) -> (item: NSCustomTouchBarItem, label: NSTextField, progress: TouchBarProgressView) {
        let item = NSCustomTouchBarItem(identifier: identifier)
        let label = NSTextField(labelWithString: "\(initialTitle) –")
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.alignment = .center

        let progress = TouchBarProgressView()
        progress.widthAnchor.constraint(equalToConstant: progressWidth).isActive = true
        progress.heightAnchor.constraint(equalToConstant: 5).isActive = true

        let stack = NSStackView(views: [label, progress])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        stack.widthAnchor.constraint(equalToConstant: itemWidth).isActive = true

        item.view = stack
        item.customizationLabel = customizationLabel
        return (item, label, progress)
    }

    // Which provider's data the items show. Prefers the provider the
    // frontmost app implies (Codex frontmost -> Codex, Claude Desktop
    // frontmost -> Claude) as long as it's actually enabled; otherwise falls
    // back to `menuBarSource`, with the same "not enabled -> first enabled"
    // fallback `menuTitle` uses, so the Touch Bar never shows a provider the
    // menu bar and popover have hidden. This never writes back to
    // `menuBarSource` — it's a Touch-Bar-local read, not a preference change.
    private var effectiveTouchBarSource: UsageProvider {
        if let implied = frontmostImpliedProvider, store.enabledProviders.contains(implied) {
            return implied
        }
        let enabled = store.enabledProviders
        return enabled.contains(store.menuBarSource) ? store.menuBarSource : (enabled.first ?? store.menuBarSource)
    }

    // What `updateItems()` is actually rendering right now. `.both` collapses
    // to `.automatic` when no provider is enabled — same as the Touch Bar
    // behaves today in that situation — rather than showing an empty pair of
    // provider groups.
    private enum ContentPlan: Equatable {
        case automatic
        case both([UsageProvider])
    }

    private var contentPlan: ContentPlan {
        guard store.touchBarContent == .both else { return .automatic }
        let providers = store.enabledProviders
        return providers.isEmpty ? .automatic : .both(providers)
    }

    private func defaultItemIdentifiers(for plan: ContentPlan) -> [NSTouchBarItem.Identifier] {
        switch plan {
        case .automatic:
            return [.fiveHourUsage, .fixedSpaceSmall, .weeklyUsage, .fixedSpaceSmall, .resetTimes, .flexibleSpace, .refreshUsage]
        case .both(let providers):
            var identifiers: [NSTouchBarItem.Identifier] = []
            for provider in providers {
                if !identifiers.isEmpty { identifiers.append(.fixedSpaceLarge) }
                switch provider {
                case .codex: identifiers += [.codexFiveHour, .fixedSpaceSmall, .codexWeekly]
                case .claude: identifiers += [.claudeFiveHour, .fixedSpaceSmall, .claudeWeekly]
                }
            }
            identifiers += [.flexibleSpace, .refreshUsage]
            return identifiers
        }
    }

    // Switching between one provider and two (or `.automatic` and `.both`)
    // changes which identifiers belong in the bar, so this has to run
    // whenever content-affecting state changes — see the `updateItems()`
    // triggers wired up in `init`. Mutating `defaultItemIdentifiers` alone
    // isn't reliably picked up by an already-presented bar: neither the
    // normal `NSApp.touchBar` path nor (especially) the private system-modal
    // path is documented to re-query the delegate on its own, so both are
    // forced — toggling `NSApp.touchBar` through nil, and dismissing +
    // re-presenting the system-modal bar outright — whenever the identifier
    // list actually changes. Skipping this (or skipping the change check and
    // always poking it) is exactly the "stale item list" failure mode: this
    // is the line that keeps four-item `.both` from silently staying stuck
    // showing two items after a mode switch, or vice versa.
    private func rebuildDefaultItemIdentifiersIfNeeded() {
        let newIdentifiers = defaultItemIdentifiers(for: contentPlan)
        guard newIdentifiers != touchBar.defaultItemIdentifiers else { return }
        touchBar.defaultItemIdentifiers = newIdentifiers

        if NSApp.touchBar === touchBar {
            NSApp.touchBar = nil
            NSApp.touchBar = touchBar
        }
        if systemModalVisible {
            TouchBarSystemModal.dismiss(touchBar)
            systemModalVisible = TouchBarSystemModal.present(touchBar)
        }
    }

    private func updateItems() {
        rebuildDefaultItemIdentifiersIfNeeded()

        switch contentPlan {
        case .automatic:
            updateAutomaticContent()
        case .both(let providers):
            updateBothContent(providers: providers)
        }
        refreshButton?.isEnabled = !store.isLoading
    }

    private func updateAutomaticContent() {
        let provider = effectiveTouchBarSource
        let snapshot = store.snapshot(for: provider)
        // The displayed provider can now change as the user switches apps
        // (see `effectiveTouchBarSource`), so naming it on both items —
        // not just a caption — is what keeps this unmistakable at a glance.
        updateUsage(
            window: snapshot?.primary,
            prefix: "\(provider.displayName) 5h",
            label: fiveHourLabel,
            progress: fiveHourProgress
        )
        updateUsage(
            window: snapshot?.secondary,
            prefix: "\(provider.displayName) \(store.tr("weekly_prefix"))",
            label: weeklyLabel,
            progress: weeklyProgress
        )

        if let snapshot {
            let primaryReset = resetText(snapshot.primary?.resetsAt, short: true)
            let weeklyReset = resetText(snapshot.secondary?.resetsAt, short: false)
            resetLabel?.stringValue = store.tr("touch_bar_reset", primaryReset, weeklyReset)
        } else {
            resetLabel?.stringValue = store.isLoading ? store.tr("loading_usage") : store.tr("usage_unavailable")
        }
    }

    // Both providers' items at once — abbreviated prefixes ("Cdx"/"Cld") so
    // each of the four items still names both its provider and its window at
    // a glance, the way the single `.automatic` item names just its provider.
    private func updateBothContent(providers: [UsageProvider]) {
        for provider in providers {
            let snapshot = store.snapshot(for: provider)
            let abbreviation = provider == .codex ? "Cdx" : "Cld"
            let (fiveHour, weekly) = bothModeItems(for: provider)
            updateUsage(
                window: snapshot?.primary,
                prefix: "\(abbreviation) 5h",
                label: fiveHour.label,
                progress: fiveHour.progress
            )
            updateUsage(
                window: snapshot?.secondary,
                prefix: "\(abbreviation) \(store.tr("weekly_prefix"))",
                label: weekly.label,
                progress: weekly.progress
            )
        }
    }

    private func bothModeItems(
        for provider: UsageProvider
    ) -> (fiveHour: (label: NSTextField?, progress: TouchBarProgressView?), weekly: (label: NSTextField?, progress: TouchBarProgressView?)) {
        switch provider {
        case .codex:
            return ((codexFiveHourLabel, codexFiveHourProgress), (codexWeeklyLabel, codexWeeklyProgress))
        case .claude:
            return ((claudeFiveHourLabel, claudeFiveHourProgress), (claudeWeeklyLabel, claudeWeeklyProgress))
        }
    }

    private func updateUsage(
        window: RateWindow?,
        prefix: String,
        label: NSTextField?,
        progress: TouchBarProgressView?
    ) {
        guard let window else {
            label?.stringValue = "\(prefix) –"
            label?.textColor = .secondaryLabelColor
            progress?.value = 0
            return
        }
        let remaining = window.remainingPercent
        let color: NSColor
        if remaining <= 10 {
            color = .systemRed
        } else if remaining <= 25 {
            color = .systemOrange
        } else {
            color = .controlAccentColor
        }
        label?.stringValue = "\(prefix) \(remaining)%"
        label?.textColor = color
        progress?.value = Double(remaining)
        progress?.tintColor = color
    }

    private func resetText(_ date: Date?, short: Bool) -> String {
        guard let date else { return "–" }
        return store.formatDate(date, includeDate: !short)
    }

    private func applyPresentationMode() {
        let mode = store.touchBarDisplayMode
        NSApp.touchBar = mode == .off ? nil : touchBar

        let shouldShowSystemModal: Bool
        switch mode {
        case .off:
            shouldShowSystemModal = false
        case .always:
            shouldShowSystemModal = TouchBarSystemModal.isAvailable
        case .whenRelevantAppFrontmost:
            shouldShowSystemModal = relevantAppIsFrontmost && TouchBarSystemModal.isAvailable
        }

        if shouldShowSystemModal && !systemModalVisible {
            systemModalVisible = TouchBarSystemModal.present(touchBar)
        } else if !shouldShowSystemModal && systemModalVisible {
            TouchBarSystemModal.dismiss(touchBar)
            systemModalVisible = false
        }
    }

    @objc private func refreshUsage() {
        store.refresh()
    }
}
