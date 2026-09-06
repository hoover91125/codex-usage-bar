import AppKit
import Combine
import ObjectiveC

/// DFRFoundation is a private framework. These two functions are what make
/// the Control Strip tray icon and the modal bar's close box work, and they
/// are resolved with `dlsym` rather than linked so a macOS release that drops
/// them degrades to "no tray icon" instead of a launch failure.
enum DFRSupport {
    private typealias SetControlStripPresence = @convention(c) (NSString, ObjCBool) -> Void
    private typealias SetShowsCloseBox = @convention(c) (ObjCBool) -> Void

    // AppKit normally has DFRFoundation loaded already on Touch Bar hardware,
    // so the global handle is tried first; the explicit path is the fallback.
    private static let handle: UnsafeMutableRawPointer? = {
        if let global = dlopen(nil, RTLD_LAZY),
           dlsym(global, "DFRElementSetControlStripPresenceForIdentifier") != nil {
            return global
        }
        return dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY)
    }()

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        guard let handle else { return nil }
        return dlsym(handle, name)
    }

    static var isAvailable: Bool {
        symbol("DFRElementSetControlStripPresenceForIdentifier") != nil
    }

    /// Adds (or removes) the app's icon from the Control Strip, next to
    /// brightness/volume. The identifier must match the tray item registered
    /// through `TouchBarSystemModal.addSystemTrayItem` and the one handed to
    /// `present`, or the system has nothing to draw.
    static func setControlStripPresence(_ identifier: String, present: Bool) {
        guard let pointer = symbol("DFRElementSetControlStripPresenceForIdentifier") else { return }
        unsafeBitCast(pointer, to: SetControlStripPresence.self)(identifier as NSString, ObjCBool(present))
    }

    /// Puts an ⓧ at the left edge of a presented system-modal bar. Tapping it
    /// dismisses the bar and hands the whole strip back to the native Control
    /// Strip — the system does that on its own and does *not* notify us, which
    /// is why the tray button below always presents rather than toggling.
    static func setShowsCloseBox(_ shows: Bool) {
        guard let pointer = symbol("DFRSystemModalShowsCloseBoxWhenFrontMost") else { return }
        unsafeBitCast(pointer, to: SetShowsCloseBox.self)(ObjCBool(shows))
    }
}

enum TouchBarSystemModal {
    /// Shared by the presented modal bar and the Control Strip tray item —
    /// the system links the two through this string.
    static let trayItemIdentifier = "com.local.codexusagebar.touchbar"

    private static let presentSelector = NSSelectorFromString(
        "presentSystemModalTouchBar:placement:systemTrayItemIdentifier:"
    )
    private static let dismissSelector = NSSelectorFromString("dismissSystemModalTouchBar:")
    private static let addTraySelector = NSSelectorFromString("addSystemTrayItem:")
    private static let removeTraySelector = NSSelectorFromString("removeSystemTrayItem:")

    static var isAvailable: Bool {
        class_getClassMethod(NSTouchBar.self, presentSelector) != nil &&
            class_getClassMethod(NSTouchBar.self, dismissSelector) != nil
    }

    /// How the modal bar shares the strip. `0` leaves the native Control Strip
    /// in place on the right and gives the bar only the region to its left —
    /// which is what makes the native brightness/volume controls reachable,
    /// and lets expanding the Control Strip temporarily cover the usage items
    /// the way it covers any app's Touch Bar. `1` takes over the whole strip.
    /// Both values are undocumented, so this is overridable at runtime with
    /// `defaults write <bundle id> touchBarPlacement -int 1` rather than
    /// hardcoded, in case a macOS release swaps the meanings.
    static var placement: Int {
        UserDefaults.standard.object(forKey: "touchBarPlacement") as? Int ?? 0
    }

    /// True when the presented bar covers the native Control Strip, which is
    /// what makes the close box and the Control Strip tray icon necessary.
    static var ownsWholeStrip: Bool { placement != 0 }

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
        // A non-empty tray identifier is what associates the bar with a
        // Control Strip item — and the system draws its own close box so the
        // user can collapse the bar back to that item. At `placement` 0 there
        // is no tray item and nothing to collapse to, so the identifier is
        // empty and the close box has no reason to appear.
        // `DFRSystemModalShowsCloseBoxWhenFrontMost(false)` alone does not
        // suppress it: the ⓧ survived that call across a ControlStrip restart.
        function(
            NSTouchBar.self,
            presentSelector,
            touchBar,
            placement,
            (ownsWholeStrip ? trayItemIdentifier : "") as NSString
        )
        return true
    }

    static func dismiss(_ touchBar: NSTouchBar) {
        guard let method = class_getClassMethod(NSTouchBar.self, dismissSelector) else { return }
        typealias Function = @convention(c) (AnyObject, Selector, NSTouchBar) -> Void
        let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
        function(NSTouchBar.self, dismissSelector, touchBar)
    }

    /// Registers the item the Control Strip will draw once
    /// `DFRSupport.setControlStripPresence` turns it on. Also undocumented,
    /// so a missing selector is a silent no-op and the caller keeps its
    /// "not installed" state.
    static func addSystemTrayItem(_ item: NSTouchBarItem) -> Bool {
        guard let method = class_getClassMethod(NSTouchBarItem.self, addTraySelector) else { return false }
        typealias Function = @convention(c) (AnyObject, Selector, NSTouchBarItem) -> Void
        let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
        function(NSTouchBarItem.self, addTraySelector, item)
        return true
    }

    static func removeSystemTrayItem(_ item: NSTouchBarItem) {
        guard let method = class_getClassMethod(NSTouchBarItem.self, removeTraySelector) else { return }
        typealias Function = @convention(c) (AnyObject, Selector, NSTouchBarItem) -> Void
        let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
        function(NSTouchBarItem.self, removeTraySelector, item)
    }
}

private extension NSTouchBarItem.Identifier {
    static let fiveHourUsage = NSTouchBarItem.Identifier("com.local.codexusagebar.five-hour")
    static let weeklyUsage = NSTouchBarItem.Identifier("com.local.codexusagebar.weekly")
    static let resetTimes = NSTouchBarItem.Identifier("com.local.codexusagebar.reset-times")
    // `.both` content mode shows up to four items at once (each provider's two
    // windows), so each provider/window pair needs its own identifier — the
    // single generic `fiveHourUsage`/`weeklyUsage` pair above stays reserved
    // for `.automatic`, unchanged widths and all.
    static let codexFiveHour = NSTouchBarItem.Identifier("com.local.codexusagebar.codex-five-hour")
    static let codexWeekly = NSTouchBarItem.Identifier("com.local.codexusagebar.codex-weekly")
    static let claudeFiveHour = NSTouchBarItem.Identifier("com.local.codexusagebar.claude-five-hour")
    static let claudeWeekly = NSTouchBarItem.Identifier("com.local.codexusagebar.claude-weekly")
    // Compact `.both`: one grouped item per provider (name printed once, both
    // windows side by side) plus a two-row reset item.
    static let codexCompact = NSTouchBarItem.Identifier("com.local.codexusagebar.codex-compact")
    static let claudeCompact = NSTouchBarItem.Identifier("com.local.codexusagebar.claude-compact")
    static let compactResetTimes = NSTouchBarItem.Identifier("com.local.codexusagebar.compact-reset-times")
    // `.both`'s own reset item — narrower than `.resetTimes`, so it needs a
    // separate identifier rather than reusing that one at a different width.
    static let bothResetTimes = NSTouchBarItem.Identifier("com.local.codexusagebar.both-reset-times")
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
    private var bothResetLabel: NSTextField?

    /// Compact `.both` builds one item per provider instead of one per
    /// provider/window pair, so its views are keyed by provider rather than
    /// held in eight separate properties.
    private struct CompactProviderViews {
        let fiveHourLabel: NSTextField
        let fiveHourProgress: TouchBarProgressView
        let weeklyLabel: NSTextField
        let weeklyProgress: TouchBarProgressView
    }
    private var compactViews: [UsageProvider: CompactProviderViews] = [:]
    private var compactResetRows: [UsageProvider: NSTextField] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var systemModalVisible = false

    // The Control Strip tray icon: a permanent slot next to brightness and
    // volume that re-presents the usage bar after the close box has handed
    // the strip back to the system.
    private var controlStripItem: NSCustomTouchBarItem?
    private var controlStripButton: NSButton?
    private var controlStripInstalled = false

    // The app region beside the native Control Strip is ~685pt, which is the
    // budget these widths were always sized against — `placement` 0 doesn't
    // shrink it, so these are the original values.
    private static let automaticItemWidth: CGFloat = 155
    private static let automaticProgressWidth: CGFloat = 145
    private static let resetLabelWidth: CGFloat = 245

    // `.both` mode needs four of these in that same ~685pt, so they are
    // narrower. Sized against the worst-case label text measured with
    // `NSAttributedString.size(withAttributes:)` against the real label font
    // (`.monospacedDigitSystemFont(ofSize: 12, weight: .medium)`) across all
    // six languages and both providers: "Cdx Sem 100%" (Codex + Spanish's
    // "Sem" weekly prefix + a 3-digit percent) measures ~89.6pt. Four items
    // plus their spacers land at 480pt, leaving ~200pt for the reset item
    // below.
    private static let bothItemWidth: CGFloat = 112
    private static let bothProgressWidth: CGFloat = 96

    // Compact `.both`. The provider name is printed once per item instead of
    // once per window, which is what pays for the reset item: two grouped
    // items plus the reset item and their spacers come to ~590pt, inside the
    // ~685pt budget — where four separate items (480pt) plus a reset item did
    // not fit.
    //
    // Unlike `.both` above, the text-bearing widths here are measured at
    // startup rather than hand-picked. The localized `five_hour_short` beside
    // a 3-digit percent ("5 horas 100%", "5 小時 100%") had outgrown the
    // original 58pt column in every language, and a replacement constant
    // would be just as stale after the next translation edit. `widestLabel`
    // sizes the column and the reset item against the widest string any
    // supported language can produce, using a real label so the cell's own
    // padding is counted: NSTextField truncates once its width drops below
    // `intrinsicContentSize`, which for a centered label is ~4pt more than
    // the bare string — the gap that made a hand-measured 62pt column still
    // clip Spanish's "Sem 100%" (63pt). Today's worst cases are Spanish, for
    // a 67pt column, 198pt items and a 192pt reset item.
    private static let compactNameWidth: CGFloat = 44
    private static let compactProgressWidth: CGFloat = 54
    private static let compactSpacing: CGFloat = 6
    private static let compactInset: CGFloat = 4
    private static let compactNameFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static let compactColumnFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    private static let compactResetFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    // +4 on each measured width is headroom, so a fraction of a point of
    // font-metric drift between macOS releases can't reintroduce the clip.
    private static let compactColumnWidth: CGFloat =
        ceil(widestLabel(compactColumnTexts, font: compactColumnFont, alignment: .center)) + 4
    private static let compactItemWidth: CGFloat =
        compactInset * 2 + compactNameWidth + compactSpacing * 2 + compactColumnWidth * 2
    private static let compactResetWidth: CGFloat =
        ceil(widestLabel(compactResetTexts, font: compactResetFont, alignment: .left)) + 4 + compactInset * 2

    /// The width below which a label with this font and alignment starts
    /// truncating the widest of `strings` — `intrinsicContentSize` of the
    /// same kind of label the items use, so the cell's padding is included.
    private static func widestLabel(
        _ strings: [String],
        font: NSFont,
        alignment: NSTextAlignment
    ) -> CGFloat {
        let label = NSTextField(labelWithString: "")
        label.font = font
        label.alignment = alignment
        return strings.reduce(0) { widest, string in
            label.stringValue = string
            return max(widest, label.intrinsicContentSize.width)
        }
    }

    /// Everything a compact column label can show, across all languages: a
    /// window prefix beside a 3-digit percent, the way `updateUsage` formats
    /// it (its "–" placeholder is narrower). "5h" is language-neutral, so
    /// only the weekly prefix varies.
    private static var compactColumnTexts: [String] {
        ["5h 100%"] + AppLanguage.allCases.map { language in
            "\(L10n.string("weekly_prefix", language: language)) 100%"
        }
    }

    /// Everything a compact reset row can show, across all languages and
    /// providers, at a worst-case date: two-digit month, day, hour and
    /// minute (digits are monospaced, so which ones doesn't matter). Built
    /// through `compactResetRow` so this can't drift from what is displayed.
    private static var compactResetTexts: [String] {
        let date = Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2000, month: 12, day: 31, hour: 23, minute: 59)
        ) ?? Date()
        var texts: [String] = []
        for language in AppLanguage.allCases {
            let weeklyPrefix = L10n.string("weekly_prefix", language: language)
            let fiveHour = L10n.formatDate(date, language: language, includeDate: false)
            let weekly = L10n.formatDate(date, language: language, includeDate: true)
            for provider in UsageProvider.allCases {
                texts.append(compactResetRow(
                    provider: provider, fiveHour: fiveHour, weeklyPrefix: weeklyPrefix, weekly: weekly
                ))
                for key in ["loading_usage", "usage_unavailable"] {
                    texts.append("\(provider.displayName) \(L10n.string(key, language: language))")
                }
            }
        }
        return texts
    }

    /// One compact reset row: "Claude 5h 18:30 · Wk 9/13, 18:30". "5h" as in
    /// `touch_bar_reset` rather than the localized `five_hour_short`, which
    /// pushed the row past any width that leaves room for the two items
    /// beside it.
    private static func compactResetRow(
        provider: UsageProvider,
        fiveHour: String,
        weeklyPrefix: String,
        weekly: String
    ) -> String {
        "\(provider.displayName) 5h \(fiveHour) · \(weeklyPrefix) \(weekly)"
    }

    // The `.both` reset item gets what's left of the budget once the four
    // usage items have taken theirs — narrower than `.automatic`'s, hence its
    // more compact text (see `updateBothResetLabel`).
    private static let bothResetLabelWidth: CGFloat = 195

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

        // Which number each item prints and when it changes color — neither
        // touches the snapshots, so they need their own trigger.
        Publishers.CombineLatest3(
            store.$usageDisplayMode,
            store.$warningRemainingPercent,
            store.$criticalRemainingPercent
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _, _ in self?.updateItems() }
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
        Publishers.CombineLatest(store.$touchBarContent, store.$touchBarBothCompact)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.updateItems() }
            .store(in: &subscriptions)

        store.$touchBarDisplayMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyPresentationMode() }
            .store(in: &subscriptions)

        // The tray icon mirrors the menu bar icon, so it follows that setting.
        store.$menuIconName
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateControlStripIcon() }
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

        // Only meaningful at `placement` 1, where the bar covers the native
        // Control Strip and the ⓧ is the only way to get it back. At
        // `placement` 0 the Control Strip is never covered, so the ⓧ has
        // nothing to restore — and dismissing through it leaves the bar hidden
        // with no notification to us, which reads as the app having broken.
        // Has to be set before the first `present` below to take effect.
        DFRSupport.setShowsCloseBox(TouchBarSystemModal.ownsWholeStrip)

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
        // Same cleanup as `teardown()`, inlined because `deinit` is nonisolated
        // and can't call the main-actor helper.
        if controlStripInstalled, let item = controlStripItem {
            DFRSupport.setControlStripPresence(TouchBarSystemModal.trayItemIdentifier, present: false)
            TouchBarSystemModal.removeSystemTrayItem(item)
        }
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
        // The Control Strip keeps drawing a dead tray icon if the process
        // exits without withdrawing it, so this goes first and runs
        // unconditionally — unlike the dismiss below, it isn't gated on
        // anything currently being presented.
        setControlStripPresence(installed: false)
        guard systemModalVisible else { return }
        TouchBarSystemModal.dismiss(touchBar)
        systemModalVisible = false
    }

    /// Installs or withdraws the Control Strip tray icon. Both private APIs
    /// are needed: `addSystemTrayItem` registers what to draw, and
    /// `DFRElementSetControlStripPresenceForIdentifier` is what actually puts
    /// it in the strip; either one missing leaves the flag false so a later
    /// call can retry.
    private func setControlStripPresence(installed: Bool) {
        guard DFRSupport.isAvailable else { return }
        if installed {
            guard !controlStripInstalled else { return }
            let item = controlStripItem ?? makeControlStripItem()
            controlStripItem = item
            guard TouchBarSystemModal.addSystemTrayItem(item) else { return }
            DFRSupport.setControlStripPresence(TouchBarSystemModal.trayItemIdentifier, present: true)
            controlStripInstalled = true
        } else {
            guard controlStripInstalled, let item = controlStripItem else { return }
            DFRSupport.setControlStripPresence(TouchBarSystemModal.trayItemIdentifier, present: false)
            TouchBarSystemModal.removeSystemTrayItem(item)
            controlStripInstalled = false
        }
    }

    private func makeControlStripItem() -> NSCustomTouchBarItem {
        let item = NSCustomTouchBarItem(
            identifier: NSTouchBarItem.Identifier(TouchBarSystemModal.trayItemIdentifier)
        )
        let button = NSButton(
            image: controlStripImage(),
            target: self,
            action: #selector(presentFromControlStrip)
        )
        button.bezelStyle = .rounded
        controlStripButton = button
        item.view = button
        return item
    }

    private func controlStripImage() -> NSImage {
        // `menuIconName` can be "none" (menu bar text only), which isn't a
        // symbol name — the tray slot still needs something to draw, so it
        // falls back to the default gauge.
        let name = store.menuIconName == "none" ? "gauge.with.dots.needle.67percent" : store.menuIconName
        let image = NSImage(systemSymbolName: name, accessibilityDescription: store.tr("show_usage_bar"))
            ?? NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: store.tr("show_usage_bar"))!
        image.isTemplate = true
        return image
    }

    private func updateControlStripIcon() {
        controlStripButton?.image = controlStripImage()
    }

    // Always presents, never toggles: the close box dismisses the bar without
    // telling us, so `systemModalVisible` can be stale-true at this point and
    // a toggle would need two taps to bring the bar back.
    @objc private func presentFromControlStrip() {
        guard TouchBarSystemModal.isAvailable else { return }
        systemModalVisible = TouchBarSystemModal.present(touchBar)
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
        case .codexCompact, .claudeCompact:
            let provider: UsageProvider = identifier == .codexCompact ? .codex : .claude
            let item = makeCompactProviderItem(identifier: identifier, provider: provider)
            updateItems()
            return item
        case .compactResetTimes:
            let item = makeCompactResetItem()
            updateItems()
            return item
        case .resetTimes, .bothResetTimes:
            let isBoth = identifier == .bothResetTimes
            let item = NSCustomTouchBarItem(identifier: identifier)
            let label = NSTextField(labelWithString: store.tr("loading_reset"))
            label.font = .systemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.lineBreakMode = .byTruncatingMiddle
            label.widthAnchor.constraint(
                equalToConstant: isBoth ? Self.bothResetLabelWidth : Self.resetLabelWidth
            ).isActive = true
            item.view = label
            item.customizationLabel = store.tr("reset_customization")
            if isBoth {
                bothResetLabel = label
            } else {
                resetLabel = label
            }
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

    /// One item per provider: the brand name once on the left, then a column
    /// per window (label above a short bar). Printing the name once instead of
    /// on all four labels is the whole width saving.
    private func makeCompactProviderItem(
        identifier: NSTouchBarItem.Identifier,
        provider: UsageProvider
    ) -> NSCustomTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: identifier)

        let name = NSTextField(labelWithString: provider.displayName)
        name.font = Self.compactNameFont
        name.alignment = .left
        name.lineBreakMode = .byTruncatingTail
        name.widthAnchor.constraint(equalToConstant: Self.compactNameWidth).isActive = true

        // Same prefixes `updateCompactContent` uses, so the placeholder is
        // already the right width.
        let fiveHour = makeCompactColumn(initialTitle: "5h")
        let weekly = makeCompactColumn(initialTitle: store.tr("weekly_prefix"))

        let stack = NSStackView(views: [name, fiveHour.stack, weekly.stack])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Self.compactSpacing
        stack.edgeInsets = NSEdgeInsets(
            top: 2, left: Self.compactInset, bottom: 2, right: Self.compactInset
        )
        stack.widthAnchor.constraint(equalToConstant: Self.compactItemWidth).isActive = true

        item.view = stack
        item.customizationLabel = provider.displayName
        compactViews[provider] = CompactProviderViews(
            fiveHourLabel: fiveHour.label,
            fiveHourProgress: fiveHour.progress,
            weeklyLabel: weekly.label,
            weeklyProgress: weekly.progress
        )
        return item
    }

    private func makeCompactColumn(
        initialTitle: String
    ) -> (stack: NSStackView, label: NSTextField, progress: TouchBarProgressView) {
        let label = NSTextField(labelWithString: "\(initialTitle) –")
        label.font = Self.compactColumnFont
        label.alignment = .center
        // `compactColumnWidth` is measured so this never triggers; if a
        // string it wasn't measured against does outgrow it, an ellipsis is
        // at least visible, where `.byClipping` cut the percent mid-glyph.
        label.lineBreakMode = .byTruncatingTail

        let progress = TouchBarProgressView()
        progress.widthAnchor.constraint(equalToConstant: Self.compactProgressWidth).isActive = true
        progress.heightAnchor.constraint(equalToConstant: 5).isActive = true

        let stack = NSStackView(views: [label, progress])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 2
        stack.widthAnchor.constraint(equalToConstant: Self.compactColumnWidth).isActive = true
        return (stack, label, progress)
    }

    /// Two rows, one per provider, in the same order as the items to their
    /// left — so a row's provider is unambiguous without repeating a bar.
    private func makeCompactResetItem() -> NSCustomTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: .compactResetTimes)

        var rows: [NSView] = []
        compactResetRows.removeAll()
        for provider in UsageProvider.allCases {
            let label = NSTextField(labelWithString: store.tr("loading_reset"))
            label.font = Self.compactResetFont
            label.textColor = .secondaryLabelColor
            label.alignment = .left
            label.lineBreakMode = .byTruncatingTail
            compactResetRows[provider] = label
            rows.append(label)
        }

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(
            top: 1, left: Self.compactInset, bottom: 1, right: Self.compactInset
        )
        stack.widthAnchor.constraint(equalToConstant: Self.compactResetWidth).isActive = true

        item.view = stack
        item.customizationLabel = store.tr("reset_customization")
        return item
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
        case bothCompact([UsageProvider])
    }

    private var contentPlan: ContentPlan {
        guard store.touchBarContent == .both else { return .automatic }
        let providers = store.enabledProviders
        guard !providers.isEmpty else { return .automatic }
        return store.touchBarBothCompact ? .bothCompact(providers) : .both(providers)
    }

    private func defaultItemIdentifiers(for plan: ContentPlan) -> [NSTouchBarItem.Identifier] {
        switch plan {
        case .automatic:
            return [.fiveHourUsage, .fixedSpaceSmall, .weeklyUsage, .fixedSpaceSmall, .resetTimes]
        case .both(let providers):
            var identifiers: [NSTouchBarItem.Identifier] = []
            for provider in providers {
                if !identifiers.isEmpty { identifiers.append(.fixedSpaceLarge) }
                switch provider {
                case .codex: identifiers += [.codexFiveHour, .fixedSpaceSmall, .codexWeekly]
                case .claude: identifiers += [.claudeFiveHour, .fixedSpaceSmall, .claudeWeekly]
                }
            }
            identifiers += [.fixedSpaceLarge, .bothResetTimes]
            return identifiers
        case .bothCompact(let providers):
            var identifiers: [NSTouchBarItem.Identifier] = []
            for provider in providers {
                if !identifiers.isEmpty { identifiers.append(.fixedSpaceLarge) }
                identifiers.append(provider == .codex ? .codexCompact : .claudeCompact)
            }
            identifiers += [.fixedSpaceLarge, .compactResetTimes]
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
        case .bothCompact(let providers):
            updateCompactContent(providers: providers)
        }
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
        updateBothResetLabel(providers: providers)
    }

    /// `.both`'s reset item has ~195pt rather than `.automatic`'s 245pt and
    /// twice as many windows to account for, so with both providers enabled it
    /// shows only the 5-hour resets — the ones that actually move within a
    /// session — abbreviated per provider ("Cdx 18:30 · Cld 19:05"). With a
    /// single provider enabled there is room for the full weekly-and-5h text,
    /// so it falls back to `.automatic`'s wording.
    private func updateBothResetLabel(providers: [UsageProvider]) {
        guard let bothResetLabel else { return }

        if providers.count == 1, let provider = providers.first {
            let snapshot = store.snapshot(for: provider)
            guard snapshot != nil else {
                bothResetLabel.stringValue = store.isLoading
                    ? store.tr("loading_usage")
                    : store.tr("usage_unavailable")
                return
            }
            bothResetLabel.stringValue = store.tr(
                "touch_bar_reset",
                resetText(snapshot?.primary?.resetsAt, short: true),
                resetText(snapshot?.secondary?.resetsAt, short: false)
            )
            return
        }

        let parts = providers.map { provider -> String in
            let abbreviation = provider == .codex ? "Cdx" : "Cld"
            return "\(abbreviation) \(resetText(store.snapshot(for: provider)?.primary?.resetsAt, short: true))"
        }
        bothResetLabel.stringValue = parts.joined(separator: " · ")
    }

    private func updateCompactContent(providers: [UsageProvider]) {
        for provider in providers {
            let snapshot = store.snapshot(for: provider)
            guard let views = compactViews[provider] else { continue }
            // No provider prefix here — the item's own name label carries it,
            // which is exactly the width `.both` spends four times over. "5h"
            // rather than the localized `five_hour_short`, as in `.automatic`
            // and `.both`: it is the only form that fits beside a 3-digit
            // percent in every language (see `compactColumnWidth`).
            updateUsage(
                window: snapshot?.primary,
                prefix: "5h",
                label: views.fiveHourLabel,
                progress: views.fiveHourProgress
            )
            updateUsage(
                window: snapshot?.secondary,
                prefix: store.tr("weekly_prefix"),
                label: views.weeklyLabel,
                progress: views.weeklyProgress
            )
        }

        // The reset item builds a row for every provider, so rows for ones the
        // user has disabled are emptied rather than left showing stale times.
        for (provider, row) in compactResetRows {
            guard providers.contains(provider) else {
                row.stringValue = ""
                continue
            }
            guard let snapshot = store.snapshot(for: provider) else {
                row.stringValue = "\(provider.displayName) " + (
                    store.isLoading ? store.tr("loading_usage") : store.tr("usage_unavailable")
                )
                continue
            }
            row.stringValue = Self.compactResetRow(
                provider: provider,
                fiveHour: resetText(snapshot.primary?.resetsAt, short: true),
                weeklyPrefix: store.tr("weekly_prefix"),
                weekly: resetText(snapshot.secondary?.resetsAt, short: false)
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
        let percent = store.displayPercent(window)
        let color: NSColor
        switch store.alertLevel(for: window) {
        case .critical: color = .systemRed
        case .warning: color = .systemOrange
        case .normal: color = .controlAccentColor
        }
        label?.stringValue = "\(prefix) \(percent)%"
        label?.textColor = color
        progress?.value = Double(percent)
        progress?.tintColor = color
    }

    private func resetText(_ date: Date?, short: Bool) -> String {
        guard let date else { return "–" }
        return store.formatDate(date, includeDate: !short)
    }

    private func applyPresentationMode() {
        let mode = store.touchBarDisplayMode
        NSApp.touchBar = mode == .off ? nil : touchBar

        // The tray icon is the way back after the close box, so it stays in the
        // Control Strip for as long as the Touch Bar feature is on — including
        // in `.whenRelevantAppFrontmost` while an unrelated app is frontmost
        // and the bar itself is hidden. At `placement` 0 there is no close box
        // and nothing to restore, and the icon would only cost a Control Strip
        // slot that the native brightness/volume controls want.
        setControlStripPresence(
            installed: mode != .off && TouchBarSystemModal.ownsWholeStrip && TouchBarSystemModal.isAvailable
        )

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

}
