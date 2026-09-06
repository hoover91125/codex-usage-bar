import SwiftUI

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
            Section(store.tr("section_services")) {
                ForEach(UsageProvider.allCases) { provider in
                    let installed = store.installedProviders.contains(provider)
                    Toggle(provider.displayName, isOn: providerEnabledBinding(provider))
                        .disabled(!installed)
                    if !installed {
                        Text(missingCaption(provider))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Picker(store.tr("menu_bar_source"), selection: menuBarSourceBinding) {
                    ForEach(store.enabledProviders) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .disabled(store.enabledProviders.isEmpty)
            }

            Section(store.tr("section_language")) {
                Picker(store.tr("language"), selection: $store.appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language == .system ? store.tr("system_default") : language.nativeName)
                            .tag(language)
                    }
                }
            }

            Section(store.tr("section_display")) {
                Picker(store.tr("display_mode"), selection: $store.usageDisplayMode) {
                    Text(store.tr("display_mode_remaining")).tag(UsageDisplayMode.remaining)
                    Text(store.tr("display_mode_used")).tag(UsageDisplayMode.used)
                }

                // Thresholds are stored as remaining percent; in `.used` mode
                // they are shown flipped ("used ≥ 75%") so the slider reads in
                // the same terms as every number on screen. The store keeps
                // red at or below orange, so dragging one slider past the
                // other drags the other along. No `step` here: a stepped
                // Slider draws a tick per step, and 21 ticks across 0–100 is
                // clutter — the 5% snapping lives in `thresholdBinding`
                // instead, and the suffix shows the exact value.
                settingSlider(
                    title: store.tr("alert_warning"),
                    value: thresholdBinding(\.warningRemainingPercent),
                    range: 0...100,
                    step: nil,
                    suffix: thresholdSuffix(store.warningRemainingPercent)
                )

                settingSlider(
                    title: store.tr("alert_critical"),
                    value: thresholdBinding(\.criticalRemainingPercent),
                    range: 0...100,
                    step: nil,
                    suffix: thresholdSuffix(store.criticalRemainingPercent)
                )

                Text(store.tr("alert_description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                // in the other mode — hiding it would make the Touch Bar
                // section change height as the picker above changes.
                Toggle(store.tr("touch_bar_both_compact"), isOn: $store.touchBarBothCompact)
                    .disabled(!TouchBarSystemModal.isAvailable || store.touchBarContent != .both)

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
        .frame(width: 440, height: 640)
    }

    /// A threshold slider in the terms of the current display mode: the
    /// stored remaining percent as-is, or its used-percent mirror. Snaps to
    /// multiples of `thresholdStep` on write, which is what makes the knob
    /// step even though the Slider itself is continuous (and tick-free).
    private static let thresholdStep = 5.0

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
        store.usageDisplayMode == .used ? "≥ \(100 - remaining)%" : "≤ \(remaining)%"
    }

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
    /// want snapping without ticks do it in their binding.
    @ViewBuilder
    private func settingSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double? = 1,
        suffix: String
    ) -> some View {
        HStack {
            Text(title)
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
    }
}
