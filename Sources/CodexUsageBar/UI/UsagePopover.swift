import AppKit
import SwiftUI

/// One window: name and percentage on a single line, the bar under it, and the
/// countdown as a caption. Three lines rather than the four this used to take —
/// the reset time no longer needs a row of its own.
///
/// Every window in the popover is drawn by this, the per-model limits included:
/// they are the same kind of thing as the headline windows and looked like a
/// different product when they had their own smaller type and half-width bars.
/// `showsReset` is the one thing that varies, and only to drop a line that
/// would otherwise repeat the weekly reset verbatim.
private struct WindowRow: View {
    @ObservedObject var store: UsageStore
    let title: String
    let window: RateWindow?
    var showsReset = true

    private var color: Color { store.alertColor(for: window) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 4)
                if let window, let pace = store.paceText(window) {
                    // Only present when the burn is well off an even pace, so
                    // it reads as a flag rather than another static number.
                    Label(pace, systemImage: "flame.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(color)
                        .usageChip(tint: color)
                        .help(store.tr("pace_help"))
                }
                Text(window.map { store.displayPercentText($0) } ?? store.tr("unavailable"))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
                    .monospacedDigit()
            }

            UsageBar(
                percent: window.map { store.displayPercent($0) } ?? 0,
                paceMarkerPercent: window.flatMap { store.paceMarkerPercent($0) },
                color: color
            )

            if showsReset, let window, let caption = store.resetCaption(for: window) {
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One provider's block: header, its two headline windows, its per-model
/// gauges, and a footer line of account facts.
private struct ProviderSection: View {
    @ObservedObject var store: UsageStore
    let provider: UsageProvider

    private var snapshot: ProviderSnapshot? { store.snapshot(for: provider) }
    private var errorMessage: String? { store.errorMessage(for: provider) }
    private var isInstalled: Bool { store.installedProviders.contains(provider) }
    // Before the first install probe resolves, `isInstalled` is trivially
    // false for everything — that must read as "loading", not "missing".
    private var showUnavailable: Bool { store.installationProbed && !isInstalled }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if showUnavailable {
                Text(store.tr("provider_unavailable", provider.displayName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                content(for: snapshot)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(store.alertLevel(for: snapshot).color)
                .frame(width: 7, height: 7)

            Text(provider.displayName)
                .font(.system(size: 13, weight: .semibold))

            if let plan = snapshot?.plan, !plan.isEmpty {
                Text(plan.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .usageChip()
            } else if !showUnavailable && snapshot == nil {
                Text(store.tr("loading_account"))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if let fetchedAt = snapshot?.fetchedAt {
                Text(store.formatDate(fetchedAt, includeDate: false))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .help(store.tr("updated_at", store.formatDate(fetchedAt, includeDate: false)))
            }

            Button {
                store.openDashboard(for: provider)
            } label: {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help(store.tr("official_usage"))
        }
    }

    @ViewBuilder
    private func content(for snapshot: ProviderSnapshot?) -> some View {
        if let snapshot {
            VStack(alignment: .leading, spacing: 9) {
                WindowRow(store: store, title: store.tr("five_hour_quota"), window: snapshot.primary)
                WindowRow(store: store, title: store.tr("weekly_quota"), window: snapshot.secondary)
            }

            // Server-supplied model names (e.g. Claude's per-model weekly
            // limits) are opaque and never localized.
            if !snapshot.extras.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text(store.tr("section_models"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                    ForEach(Array(snapshot.extras.enumerated()), id: \.offset) { _, extra in
                        WindowRow(
                            store: store,
                            title: extra.name,
                            window: extra.window,
                            // These almost always reset with the weekly window
                            // they are scoped inside, so the countdown is only
                            // printed when it would say something different.
                            showsReset: extra.window.resetsAt != snapshot.secondary?.resetsAt
                        )
                    }
                }
            }

            metaLine(snapshot)
        } else if let errorMessage {
            errorBanner(errorMessage)
        }

        if let errorMessage, snapshot != nil {
            errorBanner(errorMessage)
        }
    }

    /// Account facts that change rarely: credits, Codex's reset count, and —
    /// only while it applies — when the automatic refresh will next try a
    /// provider it is backing off from.
    @ViewBuilder
    private func metaLine(_ snapshot: ProviderSnapshot) -> some View {
        let parts = metaParts(snapshot)
        if !parts.isEmpty {
            HStack(spacing: 10) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    Label(part.1, systemImage: part.0)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
        }
    }

    /// An account with no credits, no reset allowance and no cooldown has an
    /// empty footer rather than a row saying so three times over.
    private func metaParts(_ snapshot: ProviderSnapshot) -> [(String, String)] {
        var parts: [(String, String)] = []
        if let label = creditLabel(snapshot) {
            parts.append(("creditcard", label))
        }
        if let resetCount = snapshot.credits?.resetCount, resetCount > 0 {
            parts.append(("arrow.counterclockwise", store.tr("reset_count", resetCount)))
        }
        if let cooldown = store.cooldownEnds(for: provider),
           let relative = L10n.formatRelative(cooldown, language: store.appLanguage) {
            parts.append(("hourglass", store.tr("retry_after", relative)))
        }
        return parts
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 10.5))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.orange.opacity(0.12))
            )
    }

    private func creditLabel(_ snapshot: ProviderSnapshot) -> String? {
        guard let credits = snapshot.credits else { return nil }
        if credits.unlimited { return store.tr("credits_unlimited") }
        if let balance = credits.balance { return store.tr("credits_balance", balance) }
        return nil
    }
}

struct UsagePopover: View {
    @ObservedObject var store: UsageStore
    let onShowSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(store.toggledOnProviders.enumerated()), id: \.element) { index, provider in
                if index > 0 { Divider() }
                ProviderSection(store: store, provider: provider)
            }

            if let message = store.settingsErrorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            footer
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 9)
        .environment(\.locale, store.appLanguage.locale)
        .frame(width: usageMenuContentWidth)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                store.refresh(force: true)
            } label: {
                Label(store.tr("refresh"), systemImage: "arrow.clockwise")
            }
            .disabled(store.isLoading)

            if store.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 14)
            }

            Spacer(minLength: 0)

            if store.onBatteryPower {
                Image(systemName: "battery.50")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .help(store.tr("battery_note"))
            }

            Text(versionLabel)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

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
    }

    private var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "v\(version)"
    }
}
