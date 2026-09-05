import AppKit
import Combine
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        touchBarController = UsageTouchBarController(store: store)

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
