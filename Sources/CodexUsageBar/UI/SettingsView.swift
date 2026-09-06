import SwiftUI

/// The three alert bands drawn end to end, in whichever direction the current
/// display mode reads. Two numbers on two sliders never made it obvious which
/// color a given percentage lands in; this does, and it moves as the sliders
/// move.
private struct ThresholdPreview: View {
    @ObservedObject var store: UsageStore

    /// Band widths along the *remaining* axis, left to right: 0% left over
    /// through 100% left over. `.used` mode reads the same axis backwards.
    private var bands: [(level: UsageAlertLevel, width: Int)] {
        let critical = store.criticalRemainingPercent
        let warning = store.warningRemainingPercent
        let ordered: [(UsageAlertLevel, Int)] = [
            (.critical, critical),
            (.warning, warning - critical),
            (.normal, 100 - warning)
        ]
        return (store.usageDisplayMode == .used ? ordered.reversed() : ordered)
            .map { (level: $0.0, width: $0.1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geometry in
                bandStrip(totalWidth: geometry.size.width)
            }
            .frame(height: 12)

            HStack {
                Text("0%")
                Spacer()
                Text("100%")
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
    }

    // Split out of `body` and given explicit types throughout: inlined, the
    // width arithmetic inside a `ForEach` inside a `GeometryReader` pushed the
    // expression past the type checker's budget.
    private func bandStrip(totalWidth: CGFloat) -> some View {
        HStack(spacing: 1.5) {
            ForEach(Array(bands.enumerated()), id: \.offset) { _, band in
                let width: CGFloat = max(0, totalWidth * CGFloat(band.width) / 100)
                band.level.color
                    .frame(width: width)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// A System Settings-style sidebar row: the symbol in white on a tinted
/// rounded square, so the panes are told apart by color at a glance rather
/// than by reading five similar words.
private struct SidebarLabel: View {
    let title: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label {
            Text(title)
        } icon: {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(tint.gradient)
                .frame(width: 19, height: 19)
                .overlay(
                    Image(systemName: symbol)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white)
                )
        }
    }
}

struct SettingsView: View {
    /// Panes, in the order they appear. Named rather than indexed so the
    /// selection survives reordering.
    enum Tab: Hashable, CaseIterable, Identifiable {
        case services, display, menuBar, touchBar, general

        var id: Self { self }

        var symbol: String {
            switch self {
            case .services: return "square.stack.3d.up.fill"
            case .display: return "paintpalette.fill"
            case .menuBar: return "menubar.rectangle"
            case .touchBar: return "rectangle.bottomthird.inset.filled"
            case .general: return "gearshape.fill"
            }
        }

        var tint: Color {
            switch self {
            case .services: return .indigo
            case .display: return .pink
            case .menuBar: return .teal
            case .touchBar: return .orange
            case .general: return .gray
            }
        }

        var titleKey: String {
            switch self {
            case .services: return "tab_services"
            case .display: return "tab_display"
            case .menuBar: return "tab_menu_bar"
            case .touchBar: return "tab_touch_bar"
            case .general: return "tab_general"
            }
        }
    }

    @ObservedObject var store: UsageStore
    @State var selection: Tab = .services

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
        NavigationSplitView {
            List(Tab.allCases, selection: $selection) { tab in
                SidebarLabel(title: store.tr(tab.titleKey), symbol: tab.symbol, tint: tab.tint)
                    .tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 168, ideal: 178, max: 210)
            // The window is a fixed size, so collapsing the sidebar would
            // leave a wide empty pane with only this button to get back from.
            // Dropping it also returns its ~60pt of the title bar to the
            // window title, which was otherwise one point too wide to fit and
            // truncated to "Codex Usage Bar…".
            .toolbar(removing: .sidebarToggle)
        } detail: {
            // No `navigationTitle`: it would take over the window's own title,
            // which `AppDelegate` owns and keeps in step with the language
            // setting. Each pane's `Section` headers already name it.
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .environment(\.locale, store.appLanguage.locale)
        .frame(width: settingsWindowSize.width, height: settingsWindowSize.height)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .services: servicesPane
        case .display: displayPane
        case .menuBar: menuBarPane
        case .touchBar: touchBarPane
        case .general: generalPane
        }
    }

    // MARK: - Panes

    private var servicesPane: some View {
        Form {
            Section {
                ForEach(UsageProvider.allCases) { provider in
                    let installed = store.installedProviders.contains(provider)
                    Toggle(isOn: providerEnabledBinding(provider)) {
                        Text(provider.displayName)
                        if !installed {
                            Text(missingCaption(provider))
                        }
                    }
                    .disabled(!installed)
                }
            } header: {
                Text(store.tr("section_services"))
            }

            Section {
                Picker(store.tr("menu_bar_source"), selection: menuBarSourceBinding) {
                    ForEach(store.enabledProviders) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .disabled(store.enabledProviders.isEmpty)
            } footer: {
                footnote(store.tr("battery_note"))
            }
        }
        .formStyle(.grouped)
    }

    private var displayPane: some View {
        Form {
            Section {
                Picker(store.tr("display_mode"), selection: $store.usageDisplayMode) {
                    Text(store.tr("display_mode_remaining")).tag(UsageDisplayMode.remaining)
                    Text(store.tr("display_mode_used")).tag(UsageDisplayMode.used)
                }
                .pickerStyle(.segmented)

                Toggle(store.tr("show_pace_marker"), isOn: $store.showPaceMarker)
            } header: {
                Text(store.tr("section_display"))
            } footer: {
                footnote(store.tr("pace_help"))
            }

            Section {
                ThresholdPreview(store: store)
                    .padding(.vertical, 3)

                // Thresholds are stored as remaining percent; in `.used` mode
                // they are shown flipped ("used >= 75%") so each slider reads in
                // the same terms as every number on screen. The store keeps red
                // at or below orange, so dragging one past the other drags the
                // other along. No `step` here: a stepped Slider draws a tick
                // per step, and 21 ticks across 0-100 is clutter — the 5%
                // snapping lives in `thresholdBinding` instead.
                thresholdSlider(.warning, keyPath: \.warningRemainingPercent)
                thresholdSlider(.critical, keyPath: \.criticalRemainingPercent)
            } header: {
                Text(store.tr("section_alerts"))
            } footer: {
                footnote(store.tr("alert_description"))
            }
        }
        .formStyle(.grouped)
    }

    private var menuBarPane: some View {
        Form {
            Section {
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

                Toggle(store.tr("menu_bar_tint"), isOn: $store.menuBarTintEnabled)
            } header: {
                Text(store.tr("section_menu_bar"))
            }
        }
        .formStyle(.grouped)
    }

    private var touchBarPane: some View {
        Form {
            Section {
                Picker(store.tr("touch_bar_mode"), selection: $store.touchBarDisplayMode) {
                    Text(store.tr("touch_bar_mode_always")).tag(TouchBarDisplayMode.always)
                    Text(store.tr("touch_bar_mode_when_relevant")).tag(TouchBarDisplayMode.whenRelevantAppFrontmost)
                    Text(store.tr("touch_bar_mode_off")).tag(TouchBarDisplayMode.off)
                }
                .disabled(!TouchBarSystemModal.isAvailable)

                // What the bar shows, not when — same availability gate as
                // the mode picker above since both are meaningless without a
                // Touch Bar (or the system-modal API) to render into.
                Picker(store.tr("touch_bar_content"), selection: $store.touchBarContent) {
                    Text(store.tr("touch_bar_content_automatic")).tag(TouchBarContent.automatic)
                    Text(store.tr("touch_bar_content_both")).tag(TouchBarContent.both)
                }
                .disabled(!TouchBarSystemModal.isAvailable)

                // Only affects `.both`, so it's disabled rather than hidden
                // in the other mode — hiding it would make the pane change
                // height as the picker above changes.
                Toggle(store.tr("touch_bar_both_compact"), isOn: $store.touchBarBothCompact)
                    .disabled(!TouchBarSystemModal.isAvailable || store.touchBarContent != .both)
            } header: {
                Text("Touch Bar")
            } footer: {
                footnote(TouchBarSystemModal.isAvailable
                         ? store.tr("touch_bar_description")
                         : store.tr("touch_bar_unavailable"))
            }
        }
        .formStyle(.grouped)
    }

    private var generalPane: some View {
        Form {
            Section {
                Toggle(store.tr("launch_at_login"), isOn: Binding(
                    get: { store.launchAtLogin },
                    set: { store.setLaunchAtLogin($0) }
                ))

                Picker(store.tr("language"), selection: $store.appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language == .system ? store.tr("system_default") : language.nativeName)
                            .tag(language)
                    }
                }
            } header: {
                Text(store.tr("section_general"))
            }

            Section {
                LabeledContent("Codex Usage Bar") {
                    Text(versionLabel)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Link(store.tr("project_page"), destination: Self.projectURL)
            }
        }
        .formStyle(.grouped)
    }

    private static let projectURL = URL(string: "https://github.com/hoover91125/codex-usage-bar")!

    private var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local"
        return "v\(version) (\(build))"
    }

    /// A section footer. `Form`'s grouped style trails its footers to the
    /// right edge, which reads as a caption hanging off the wrong end of the
    /// pane, so this claims the full width and aligns itself.
    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Threshold sliders

    /// A threshold slider in the terms of the current display mode: the
    /// stored remaining percent as-is, or its used-percent mirror. Snaps to
    /// multiples of `thresholdStep` on write, which is what makes the knob
    /// step even though the Slider itself is continuous (and tick-free).
    private static let thresholdStep = 5.0

    private func thresholdSlider(
        _ level: UsageAlertLevel,
        keyPath: ReferenceWritableKeyPath<UsageStore, Int>
    ) -> some View {
        settingSlider(
            title: store.tr(level.nameKey),
            swatch: level.color,
            value: thresholdBinding(keyPath),
            range: 0...100,
            step: nil,
            suffix: thresholdSuffix(store[keyPath: keyPath])
        )
    }

    private func thresholdBinding(_ keyPath: ReferenceWritableKeyPath<UsageStore, Int>) -> Binding<Double> {
        Binding(
            get: {
                let remaining = store[keyPath: keyPath]
                return Double(store.usageDisplayMode == .used ? 100 - remaining : remaining)
            },
            set: { value in
                let shown = Int((value / Self.thresholdStep).rounded() * Self.thresholdStep)
                store[keyPath: keyPath] = store.usageDisplayMode == .used ? 100 - shown : shown
            }
        )
    }

    private func thresholdSuffix(_ remaining: Int) -> String {
        store.usageDisplayMode == .used ? "\u{2265} \(100 - remaining)%" : "\u{2264} \(remaining)%"
    }

    // MARK: - Helpers

    // Mirrors `menuTitle`'s fallback: if the stored preference points at a
    // provider that's toggled off or not installed, the picker shows the
    // provider actually feeding the menu bar rather than an empty selection.
    // Only the write is a direct pass-through — a fallback display never
    // silently overwrites the stored preference.
    private var menuBarSourceBinding: Binding<UsageProvider> {
        Binding(
            get: {
                let enabled = store.enabledProviders
                return enabled.contains(store.menuBarSource) ? store.menuBarSource : (enabled.first ?? store.menuBarSource)
            },
            set: { store.menuBarSource = $0 }
        )
    }

    private func providerEnabledBinding(_ provider: UsageProvider) -> Binding<Bool> {
        Binding(
            get: { store.isProviderEnabled(provider) },
            set: { store.setProviderEnabled($0, for: provider) }
        )
    }

    private func missingCaption(_ provider: UsageProvider) -> String {
        switch provider {
        case .codex: return store.tr("service_missing_codex")
        case .claude: return store.tr("service_missing_claude")
        }
    }

    /// `step: nil` gives a continuous slider with no tick marks; callers that
    /// want snapping without ticks do it in their binding. `LabeledContent` is
    /// what puts the label in the form's own leading column, so a slider row
    /// lines up with the pickers above it instead of starting wherever its
    /// own text happens to end.
    private func settingSlider(
        title: String,
        swatch: Color? = nil,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double? = 1,
        suffix: String
    ) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                if let step {
                    Slider(value: value, in: range, step: step)
                } else {
                    Slider(value: value, in: range)
                }
                Text(suffix)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
        } label: {
            HStack(spacing: 6) {
                if let swatch {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(swatch.gradient)
                        .frame(width: 10, height: 10)
                }
                Text(title)
            }
        }
    }
}
