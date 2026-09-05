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
}

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
    private var subscriptions = Set<AnyCancellable>()
    private var systemModalVisible = false
    private var codexIsFrontmost = false

    init(store: UsageStore) {
        self.store = store
        super.init()

        touchBar.delegate = self
        touchBar.customizationIdentifier = NSTouchBar.CustomizationIdentifier(
            "com.local.codexusagebar.usage"
        )
        touchBar.defaultItemIdentifiers = [
            .fiveHourUsage,
            .fixedSpaceSmall,
            .weeklyUsage,
            .fixedSpaceSmall,
            .resetTimes,
            .flexibleSpace,
            .refreshUsage
        ]

        Publishers.CombineLatest4(store.$snapshots, store.$isLoading, store.$errors, store.$otherErrors)
            .combineLatest(store.$settingsErrorMessage)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.updateItems() }
            .store(in: &subscriptions)

        store.$appLanguage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateItems() }
            .store(in: &subscriptions)

        Publishers.CombineLatest(store.$touchBarEnabled, store.$touchBarWhenCodexActive)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.applyPresentationMode() }
            .store(in: &subscriptions)

        NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didActivateApplicationNotification
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            self?.codexIsFrontmost = application.bundleIdentifier == "com.openai.codex"
            self?.applyPresentationMode()
        }
        .store(in: &subscriptions)

        codexIsFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.openai.codex"
        updateItems()
        applyPresentationMode()
    }

    deinit {
        if systemModalVisible {
            TouchBarSystemModal.dismiss(touchBar)
        }
    }

    func touchBar(
        _ touchBar: NSTouchBar,
        makeItemForIdentifier identifier: NSTouchBarItem.Identifier
    ) -> NSTouchBarItem? {
        switch identifier {
        case .fiveHourUsage:
            let result = makeUsageItem(identifier: identifier, title: store.tr("five_hour_short"))
            fiveHourLabel = result.label
            fiveHourProgress = result.progress
            updateItems()
            return result.item
        case .weeklyUsage:
            let result = makeUsageItem(identifier: identifier, title: store.tr("weekly_short"))
            weeklyLabel = result.label
            weeklyProgress = result.progress
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
        title: String
    ) -> (item: NSCustomTouchBarItem, label: NSTextField, progress: TouchBarProgressView) {
        let item = NSCustomTouchBarItem(identifier: identifier)
        let label = NSTextField(labelWithString: "\(title) –")
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.alignment = .center

        let progress = TouchBarProgressView()
        progress.widthAnchor.constraint(equalToConstant: 145).isActive = true
        progress.heightAnchor.constraint(equalToConstant: 5).isActive = true

        let stack = NSStackView(views: [label, progress])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        stack.widthAnchor.constraint(equalToConstant: 155).isActive = true

        item.view = stack
        item.customizationLabel = store.tr("quota_customization", title)
        return (item, label, progress)
    }

    private func updateItems() {
        updateUsage(
            window: store.primarySnapshot?.primary,
            prefix: "5h",
            label: fiveHourLabel,
            progress: fiveHourProgress
        )
        updateUsage(
            window: store.primarySnapshot?.secondary,
            prefix: store.tr("weekly_prefix"),
            label: weeklyLabel,
            progress: weeklyProgress
        )

        if let snapshot = store.primarySnapshot {
            let primaryReset = resetText(snapshot.primary?.resetsAt, short: true)
            let weeklyReset = resetText(snapshot.secondary?.resetsAt, short: false)
            resetLabel?.stringValue = store.tr("touch_bar_reset", primaryReset, weeklyReset)
        } else {
            resetLabel?.stringValue = store.isLoading ? store.tr("loading_usage") : store.tr("usage_unavailable")
        }
        refreshButton?.isEnabled = !store.isLoading
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
        NSApp.touchBar = store.touchBarEnabled ? touchBar : nil
        let shouldShowSystemModal = store.touchBarEnabled &&
            store.touchBarWhenCodexActive &&
            codexIsFrontmost &&
            TouchBarSystemModal.isAvailable

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
