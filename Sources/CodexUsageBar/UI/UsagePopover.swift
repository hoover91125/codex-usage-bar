import AppKit
import SwiftUI

struct UsageWindowRow: View {
    @ObservedObject var store: UsageStore
    let title: String
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
                Text(title)
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

/// One provider's block within the popover: header (name, plan, dashboard
/// link) plus its usage rows, extras, credits, and error — or, if the
/// provider isn't installed, a single muted line instead of a body.
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
        VStack(alignment: .leading, spacing: 16) {
            header

            if showUnavailable {
                Text(store.tr("provider_unavailable", provider.displayName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                body(for: snapshot)
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(.headline)
                if !showUnavailable {
                    Text(snapshot?.plan?.uppercased() ?? store.tr("loading_account"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                store.openDashboard(for: provider)
            } label: {
                Image(systemName: "safari")
            }
            .buttonStyle(.borderless)
            .help(store.tr("official_usage"))
        }
    }

    @ViewBuilder
    private func body(for snapshot: ProviderSnapshot?) -> some View {
        if let snapshot {
            UsageWindowRow(store: store, title: store.tr("five_hour_quota"), window: snapshot.primary)
            UsageWindowRow(store: store, title: store.tr("weekly_quota"), window: snapshot.secondary)

            // Server-supplied model names (e.g. Claude's per-model weekly
            // limits) are opaque and never localized.
            ForEach(Array(snapshot.extras.enumerated()), id: \.offset) { _, extra in
                UsageWindowRow(store: store, title: extra.name, window: extra.window)
            }

            Divider()

            HStack(spacing: 18) {
                Label(creditLabel(snapshot), systemImage: "creditcard")
                if let resetCount = snapshot.credits?.resetCount, resetCount > 0 {
                    Label(store.tr("reset_count", resetCount), systemImage: "arrow.counterclockwise.circle")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(store.tr("updated_at", store.formatDate(snapshot.fetchedAt, includeDate: false)))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let errorMessage, snapshot != nil {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func creditLabel(_ snapshot: ProviderSnapshot) -> String {
        guard let credits = snapshot.credits else { return store.tr("credits_unavailable") }
        if credits.unlimited { return store.tr("credits_unlimited") }
        if let balance = credits.balance { return store.tr("credits_balance", balance) }
        return store.tr("credits_unavailable")
    }
}

struct UsagePopover: View {
    @ObservedObject var store: UsageStore
    let onShowSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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

            HStack {
                Button {
                    store.refresh(force: true)
                } label: {
                    Label(store.tr("refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(store.isLoading)

                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
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

    private var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local"
        return "v\(version) · build \(build)"
    }
}
