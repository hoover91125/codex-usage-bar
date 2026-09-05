import AppKit
import Combine
import ObjectiveC
import ServiceManagement
import SwiftUI

private let usageDashboardURL = URL(string: "https://chatgpt.com/codex/settings/usage")!
private let usageMenuContentWidth: CGFloat = 330

struct RateWindow: Sendable {
    let usedPercent: Int
    let durationMinutes: Int?
    let resetsAt: Date?

    var remainingPercent: Int { max(0, min(100, 100 - usedPercent)) }
}

struct UsageSnapshot: Sendable {
    let primary: RateWindow?
    let secondary: RateWindow?
    let plan: String?
    let creditBalance: String?
    let unlimitedCredits: Bool
    let resetCredits: Int
    let fetchedAt: Date
}

enum UsageClientError: LocalizedError {
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

enum CodexUsageClient {
    static func fetch() throws -> UsageSnapshot {
        guard let executable = findCodexExecutable() else {
            throw UsageClientError.codexNotFound
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw UsageClientError.launchFailed(error.localizedDescription)
        }

        let timedOut = LockedFlag()
        let timeout = DispatchWorkItem {
            if process.isRunning {
                timedOut.value = true
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: timeout)

        let initialize: [String: Any] = [
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": "codex-usage-bar",
                    "title": "Codex Usage Bar",
                    "version": "1.0.0"
                ],
                "capabilities": ["experimentalApi": true]
            ]
        ]
        let request: [String: Any] = [
            "id": 2,
            "method": "account/rateLimits/read",
            "params": NSNull()
        ]

        do {
            let payload = try line(for: initialize) + line(for: request)
            try input.fileHandleForWriting.write(contentsOf: payload)
        } catch {
            if process.isRunning { process.terminate() }
            timeout.cancel()
            throw UsageClientError.launchFailed(error.localizedDescription)
        }

        var responseData = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            responseData.append(chunk)
            if containsResponse(id: 2, in: responseData) { break }
        }
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        timeout.cancel()

        if timedOut.value && !containsResponse(id: 2, in: responseData) {
            throw UsageClientError.timedOut
        }

        return try parseResponse(responseData)
    }

    private static func containsResponse(id: Int, in data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.split(whereSeparator: \.isNewline).contains { line in
            guard let lineData = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                return false
            }
            return (json["id"] as? NSNumber)?.intValue == id
        }
    }

    private static func line(for object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        return data
    }

    private static func parseResponse(_ data: Data) throws -> UsageSnapshot {
        guard let text = String(data: data, encoding: .utf8) else {
            throw UsageClientError.invalidResponse
        }

        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (json["id"] as? NSNumber)?.intValue == 2 else {
                continue
            }

            if let error = json["error"] as? [String: Any] {
                throw UsageClientError.server(error["message"] as? String ?? "Unknown error")
            }

            guard let result = json["result"] as? [String: Any],
                  let limits = preferredLimits(from: result) else {
                throw UsageClientError.invalidResponse
            }

            let credits = limits["credits"] as? [String: Any]
            let resets = result["rateLimitResetCredits"] as? [String: Any]

            return UsageSnapshot(
                primary: parseWindow(limits["primary"]),
                secondary: parseWindow(limits["secondary"]),
                plan: limits["planType"] as? String,
                creditBalance: credits?["balance"] as? String,
                unlimitedCredits: credits?["unlimited"] as? Bool ?? false,
                resetCredits: (resets?["availableCount"] as? NSNumber)?.intValue ?? 0,
                fetchedAt: Date()
            )
        }

        throw UsageClientError.invalidResponse
    }

    private static func preferredLimits(from result: [String: Any]) -> [String: Any]? {
        if let buckets = result["rateLimitsByLimitId"] as? [String: Any],
           let codex = buckets["codex"] as? [String: Any] {
            return codex
        }
        return result["rateLimits"] as? [String: Any]
    }

    private static func parseWindow(_ value: Any?) -> RateWindow? {
        guard let object = value as? [String: Any],
              let used = (object["usedPercent"] as? NSNumber)?.intValue else {
            return nil
        }
        let duration = (object["windowDurationMins"] as? NSNumber)?.intValue
        let resetTimestamp = (object["resetsAt"] as? NSNumber)?.doubleValue
        return RateWindow(
            usedPercent: used,
            durationMinutes: duration,
            resetsAt: resetTimestamp.map(Date.init(timeIntervalSince1970:))
        )
    }

    private static func findCodexExecutable() -> URL? {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        return candidates
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map(URL.init(fileURLWithPath:))
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var snapshot: UsageSnapshot?
    @Published var errorMessage: String?
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
        didSet {
            UserDefaults.standard.set(appLanguage.rawValue, forKey: "appLanguage")
            if let lastUsageError {
                errorMessage = lastUsageError.message(language: appLanguage)
            }
        }
    }

    private var refreshTask: Task<Void, Never>?
    private var lastUsageError: UsageClientError?
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

    var menuTitle: String {
        if let snapshot {
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
        guard let snapshot else {
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
        errorMessage = nil
        lastUsageError = nil

        Task {
            do {
                let value = try await Task.detached(priority: .userInitiated) {
                    try CodexUsageClient.fetch()
                }.value
                snapshot = value
            } catch let error as UsageClientError {
                lastUsageError = error
                errorMessage = error.message(language: appLanguage)
            } catch {
                errorMessage = error.localizedDescription
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
            errorMessage = tr("error_launch_at_login", error.localizedDescription)
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

struct UsageWindowRow: View {
    @ObservedObject var store: UsageStore
    let titleKey: String
    let window: RateWindow?

    private var color: Color {
        guard let remaining = window?.remainingPercent else { return .secondary }
        if remaining <= 10 { return .red }
        if remaining <= 25 { return .orange }
        return .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(store.tr(titleKey))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(window.map { store.tr("remaining", $0.remainingPercent) } ?? store.tr("unavailable"))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(color)
            }

            ProgressView(value: Double(window?.remainingPercent ?? 0), total: 100)
                .tint(color)

            if let reset = window?.resetsAt {
                Text(store.tr("reset_at", store.formatDate(reset)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

}

struct UsagePopover: View {
    @ObservedObject var store: UsageStore
    let onShowSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex Usage")
                        .font(.headline)
                    Text(store.snapshot?.plan?.uppercased() ?? store.tr("loading_account"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let snapshot = store.snapshot {
                UsageWindowRow(store: store, titleKey: "five_hour_quota", window: snapshot.primary)
                UsageWindowRow(store: store, titleKey: "weekly_quota", window: snapshot.secondary)

                Divider()

                HStack(spacing: 18) {
                    Label(creditLabel(snapshot), systemImage: "creditcard")
                    if snapshot.resetCredits > 0 {
                        Label(store.tr("reset_count", snapshot.resetCredits), systemImage: "arrow.counterclockwise.circle")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(store.tr("updated_at", store.formatDate(snapshot.fetchedAt, includeDate: false)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if let message = store.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let message = store.errorMessage, store.snapshot != nil {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Button {
                    store.refresh()
                } label: {
                    Label(store.tr("refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(store.isLoading)

                Button {
                    store.openDashboard()
                } label: {
                    Label(store.tr("official_usage"), systemImage: "safari")
                }

                Spacer()

                Button {
                    onShowSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help(store.tr("settings"))
                .fixedSize()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help(store.tr("quit"))
                .fixedSize()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Text(versionLabel)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .environment(\.locale, store.appLanguage.locale)
        .frame(width: usageMenuContentWidth)
    }

    private func creditLabel(_ snapshot: UsageSnapshot) -> String {
        if snapshot.unlimitedCredits { return store.tr("credits_unlimited") }
        if let balance = snapshot.creditBalance { return store.tr("credits_balance", balance) }
        return store.tr("credits_unavailable")
    }

    private var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local"
        return "v\(version) · build \(build)"
    }
}

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

        Publishers.CombineLatest3(store.$snapshot, store.$isLoading, store.$errorMessage)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.updateItems() }
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
            window: store.snapshot?.primary,
            prefix: "5h",
            label: fiveHourLabel,
            progress: fiveHourProgress
        )
        updateUsage(
            window: store.snapshot?.secondary,
            prefix: store.tr("weekly_prefix"),
            label: weeklyLabel,
            progress: weeklyProgress
        )

        if let snapshot = store.snapshot {
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

struct SettingsView: View {
    @ObservedObject var store: UsageStore

    private let icons = [
        ("gauge.with.dots.needle.67percent", "icon_gauge"),
        ("gauge.medium", "icon_simple_gauge"),
        ("speedometer", "icon_speedometer"),
        ("chart.bar.fill", "icon_bar_chart"),
        ("chart.line.uptrend.xyaxis", "icon_trend"),
        ("percent", "icon_percent"),
        ("bolt.circle.fill", "icon_bolt"),
        ("flame.fill", "icon_flame"),
        ("sparkles", "icon_sparkles"),
        ("terminal.fill", "icon_terminal"),
        ("command.circle.fill", "icon_command"),
        ("cpu", "icon_cpu"),
        ("memorychip", "icon_chip"),
        ("timer", "icon_timer"),
        ("clock.arrow.circlepath", "icon_refresh_clock"),
        ("waveform.path.ecg", "icon_waveform"),
        ("none", "icon_hidden")
    ]

    var body: some View {
        Form {
            Section(store.tr("section_language")) {
                Picker(store.tr("language"), selection: $store.appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language == .system ? store.tr("system_default") : language.nativeName)
                            .tag(language)
                    }
                }
            }

            Section(store.tr("section_menu_bar")) {
                Picker(store.tr("icon"), selection: $store.menuIconName) {
                    ForEach(icons, id: \.0) { icon in
                        Label(store.tr(icon.1), systemImage: icon.0 == "none" ? "eye.slash" : icon.0)
                            .tag(icon.0)
                    }
                }

                settingSlider(
                    title: store.tr("icon_size"),
                    value: $store.menuIconSize,
                    range: 9...18,
                    suffix: "\(Int(store.menuIconSize)) pt"
                )

                settingSlider(
                    title: store.tr("text_size"),
                    value: $store.menuTextSize,
                    range: 8...18,
                    suffix: "\(Int(store.menuTextSize)) pt"
                )
            }

            Section(store.tr("section_general")) {
                Toggle(store.tr("launch_at_login"), isOn: Binding(
                    get: { store.launchAtLogin },
                    set: { store.setLaunchAtLogin($0) }
                ))
            }

            Section("Touch Bar") {
                Toggle(store.tr("show_touch_bar"), isOn: $store.touchBarEnabled)
                Toggle(store.tr("auto_touch_bar"), isOn: $store.touchBarWhenCodexActive)
                    .disabled(!store.touchBarEnabled || !TouchBarSystemModal.isAvailable)

                Text(TouchBarSystemModal.isAvailable
                     ? store.tr("touch_bar_description")
                     : store.tr("touch_bar_unavailable"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(4)
        .environment(\.locale, store.appLanguage.locale)
        .frame(width: 440, height: 500)
    }

    @ViewBuilder
    private func settingSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double = 1,
        suffix: String
    ) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range, step: step)
            Text(suffix)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }
}

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

        Publishers.CombineLatest3(store.$snapshot, store.$isLoading, store.$errorMessage)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
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

struct CodexUsageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@main
enum CodexUsageBarMain {
    @MainActor
    static func main() {
        // Runs before the App value exists, so a self-test never builds the
        // AppDelegate, its UsageStore, or the background refresh timer.
        if CommandLine.arguments.contains("--self-test") {
            runSelfTest()
        }
        CodexUsageBarApp.main()
    }

    private static func runSelfTest() -> Never {
        do {
            let snapshot = try CodexUsageClient.fetch()
            let primary = snapshot.primary?.remainingPercent.description ?? "n/a"
            let secondary = snapshot.secondary?.remainingPercent.description ?? "n/a"
            print("OK 5h=\(primary)% weekly=\(secondary)% resets=\(snapshot.resetCredits)")
            exit(EXIT_SUCCESS)
        } catch {
            fputs("ERROR \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
