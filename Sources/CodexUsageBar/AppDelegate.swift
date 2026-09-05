import AppKit
import Combine
import Dispatch
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = UsageStore()

    private var statusItem: NSStatusItem?
    private var usageMenu: NSMenu?
    private var menuContentView: NSHostingView<UsagePopover>?
    private var settingsWindow: NSWindow?
    private var touchBarController: UsageTouchBarController?
    private var showSettingsAfterMenuCloses = false
    private var subscriptions = Set<AnyCancellable>()

    // Kept alive for the process lifetime; a signal killing the app (e.g. a
    // preview rebuild's `pkill`) skips `applicationWillTerminate` entirely, so
    // these are the only way to dismiss a presented system-modal Touch Bar
    // before the process actually exits.
    private var sigtermSource: DispatchSourceSignal?
    private var sigintSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        touchBarController = UsageTouchBarController(store: store)
        installSignalHandlers()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            button.alignment = .center
        }

        let menu = makeUsageMenu()
        usageMenu = menu
        item.menu = menu

        Publishers.CombineLatest4(store.$snapshots, store.$isLoading, store.$errors, store.$otherErrors)
            .combineLatest(store.$settingsErrorMessage)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.updateStatusItem()
                self?.resizeMenuContent()
            }
            .store(in: &subscriptions)

        // Section count (and which provider feeds the status item title)
        // changes with these without necessarily touching the fetch state
        // above, so they need their own trigger for the button title and the
        // popover's measured height.
        Publishers.CombineLatest4(
            store.$menuBarSource,
            store.$providerEnabledCodex,
            store.$providerEnabledClaude,
            store.$installedProviders
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _, _, _ in
            self?.updateStatusItem()
            self?.resizeMenuContent()
        }
        .store(in: &subscriptions)

        Publishers.CombineLatest3(store.$menuIconName, store.$menuIconSize, store.$menuTextSize)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.updateStatusItem() }
            .store(in: &subscriptions)

        store.$appLanguage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.settingsWindow?.title = self.store.tr("settings_window_title")
                self.resizeMenuContent()
            }
            .store(in: &subscriptions)

        // The 5-minute poll does not run while the machine is asleep, so data is
        // stale by up to that long after waking.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.store.refresh() }
            .store(in: &subscriptions)

        updateStatusItem()

        // `--self-test` is handled before the App value even exists (see
        // CodexUsageBarMain), but this one needs the running app, so it's
        // handled here instead.
        if CommandLine.arguments.contains("--settings") {
            presentSettingsWindow()
        }
    }

    // The app is LSUIElement with no Dock icon, so the status item is
    // normally the only way in. If it's ever unreachable (a crowded menu bar,
    // a menu-bar-hiding utility), re-launching from Finder/Spotlight/Launchpad
    // is the recovery path — macOS doesn't start a second instance, it sends
    // this already-running one a reopen event instead.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        presentSettingsWindow()
        return true
    }

    // Normal quit path (menu Quit, `NSApp.terminate`). A signal skips this —
    // see `installSignalHandlers`.
    func applicationWillTerminate(_ notification: Notification) {
        touchBarController?.teardown()
    }

    // `DispatchSourceSignal` doesn't suppress the default disposition on its
    // own, so SIG_IGN first is what stops the process from being killed
    // before the handler (and its Touch Bar teardown) gets to run. The
    // handler itself only touches `systemModalVisible`/AppKit state, both
    // fine from the main queue, so no raw-signal-handler safety concerns.
    private func installSignalHandlers() {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { [weak self] in
            self?.touchBarController?.teardown()
            exit(0)
        }
        term.resume()
        sigtermSource = term

        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler { [weak self] in
            self?.touchBarController?.teardown()
            exit(0)
        }
        interrupt.resume()
        sigintSource = interrupt
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }

        let pointSize = CGFloat(store.menuTextSize)
        let textFont = NSFont.monospacedDigitSystemFont(ofSize: pointSize, weight: .medium)
        let baselineOffset = -max(0.5, round(pointSize * 0.08 * 2) / 2)
        button.font = textFont
        button.attributedTitle = NSAttributedString(
            string: store.menuTitle,
            attributes: [
                .font: textFont,
                .foregroundColor: NSColor.labelColor,
                .baselineOffset: baselineOffset
            ]
        )

        if store.menuIconName == "none" {
            button.image = nil
        } else {
            let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: CGFloat(store.menuIconSize), weight: .medium)
            let image = NSImage(systemSymbolName: store.menuIconName, accessibilityDescription: "Codex Usage")?
                .withSymbolConfiguration(symbolConfiguration)
            image?.isTemplate = true
            button.image = image
        }
        button.imageScaling = .scaleProportionallyDown
    }

    private func makeUsageMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.minimumWidth = usageMenuContentWidth
        menu.delegate = self

        let contentItem = NSMenuItem()
        let hostingView = NSHostingView(rootView: UsagePopover(
            store: store,
            onShowSettings: { [weak self] in self?.requestSettings() }
        ))
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        menuContentView = hostingView
        resizeMenuContent()
        contentItem.view = hostingView
        menu.addItem(contentItem)
        return menu
    }

    /// The popover grows and shrinks with its content (error rows, credit rows,
    /// translated string lengths), so the host view is measured rather than
    /// pinned to a fixed height.
    private func resizeMenuContent() {
        guard let hostingView = menuContentView else { return }
        let height = max(1, ceil(hostingView.fittingSize.height))
        guard abs(hostingView.frame.height - height) > 0.5 || hostingView.frame.width != usageMenuContentWidth else { return }
        hostingView.frame = NSRect(x: 0, y: 0, width: usageMenuContentWidth, height: height)
    }

    private func requestSettings() {
        guard usageMenu != nil else {
            presentSettingsWindow()
            return
        }
        showSettingsAfterMenuCloses = true
        usageMenu?.cancelTrackingWithoutAnimation()
    }

    func menuWillOpen(_ menu: NSMenu) {
        resizeMenuContent()
        store.refreshIfStale()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard showSettingsAfterMenuCloses else { return }
        showSettingsAfterMenuCloses = false
        DispatchQueue.main.async { [weak self] in self?.presentSettingsWindow() }
    }

    private func presentSettingsWindow() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 500),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = store.tr("settings_window_title")
            window.isReleasedWhenClosed = false
            window.center()
            window.contentView = NSHostingView(rootView: SettingsView(store: store))
            settingsWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
