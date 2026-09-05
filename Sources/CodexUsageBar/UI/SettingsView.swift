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
