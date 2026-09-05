import SwiftUI

let usageDashboardURL = URL(string: "https://chatgpt.com/codex/settings/usage")!
let usageMenuContentWidth: CGFloat = 330

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
        var anyFailed = false

        for provider in UsageProvider.allCases {
            let client = usageProviderClient(for: provider)
            guard client.isInstalled() else {
                print("SKIP \(provider.rawValue) (not installed)")
                continue
            }

            do {
                let snapshot = try client.fetch()
                let primary = snapshot.primary?.remainingPercent.description ?? "n/a"
                let secondary = snapshot.secondary?.remainingPercent.description ?? "n/a"
                switch provider {
                case .codex:
                    let resets = snapshot.credits?.resetCount ?? 0
                    print("OK \(provider.rawValue) 5h=\(primary)% weekly=\(secondary)% resets=\(resets)")
                case .claude:
                    let plan = snapshot.plan ?? "n/a"
                    print("OK \(provider.rawValue) 5h=\(primary)% weekly=\(secondary)% plan=\(plan)")
                }
            } catch {
                anyFailed = true
                let message = (error as? UsageClientError)?.message(language: .system) ?? error.localizedDescription
                fputs("ERROR \(provider.rawValue) \(message)\n", stderr)
            }
        }

        exit(anyFailed ? EXIT_FAILURE : EXIT_SUCCESS)
    }
}
