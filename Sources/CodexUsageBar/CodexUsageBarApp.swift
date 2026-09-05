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
        do {
            let snapshot = try CodexUsageClient.fetch()
            let primary = snapshot.primary?.remainingPercent.description ?? "n/a"
            let secondary = snapshot.secondary?.remainingPercent.description ?? "n/a"
            let resets = snapshot.credits?.resetCount ?? 0
            print("OK 5h=\(primary)% weekly=\(secondary)% resets=\(resets)")
            exit(EXIT_SUCCESS)
        } catch {
            fputs("ERROR \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
