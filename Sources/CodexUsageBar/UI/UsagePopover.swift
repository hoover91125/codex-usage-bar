import AppKit
import SwiftUI

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
                    Text(store.primarySnapshot?.plan?.uppercased() ?? store.tr("loading_account"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let snapshot = store.primarySnapshot {
                UsageWindowRow(store: store, titleKey: "five_hour_quota", window: snapshot.primary)
                UsageWindowRow(store: store, titleKey: "weekly_quota", window: snapshot.secondary)

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
            } else if let message = store.primaryErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let message = store.primaryErrorMessage, store.primarySnapshot != nil {
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

    private func creditLabel(_ snapshot: ProviderSnapshot) -> String {
        guard let credits = snapshot.credits else { return store.tr("credits_unavailable") }
        if credits.unlimited { return store.tr("credits_unlimited") }
        if let balance = credits.balance { return store.tr("credits_balance", balance) }
        return store.tr("credits_unavailable")
    }

    private var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local"
        return "v\(version) · build \(build)"
    }
}
