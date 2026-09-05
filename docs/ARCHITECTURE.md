# Architecture

Codex Usage Bar is a single-target Swift Package using AppKit, SwiftUI,
Combine, and ServiceManagement. It has no third-party dependencies.

## Data flow

```text
Codex Usage Bar
    │
    ├─ Codex ─── launches local `codex app-server --stdio`
    │              ├─ initialize
    │              └─ account/rateLimits/read
    │
    └─ Claude ── reads ~/.claude.json → cachedUsageUtilization   (no request)
                 └─ only when that copy is over 5 minutes old:
                    Keychain "Claude Code-credentials" → access token
                    GET https://api.anthropic.com/api/oauth/usage
              │
              ▼
      ProviderSnapshot (one per provider)
        ├─ NSStatusItem title
        ├─ SwiftUI detail view inside NSMenu
        └─ NSTouchBar items
```

## Main components

- `UsageProviderClient` is the per-provider protocol: `isInstalled()`,
  `cachedSnapshot()` (data the provider's own tooling left on disk; optional)
  and `fetch()`.
- `CodexUsageClient` locates the local Codex executable, speaks newline-delimited
  JSON-RPC over standard input/output, and parses the rate-limit response.
- `ClaudeUsageClient` sends the usage request and parses the response.
  `ClaudeCredentialStore` finds the Claude Code login in the Keychain or the
  credentials file. `ClaudeCodeUsageCache` reads Claude Code's cached copy of
  the same response from `~/.claude.json`.
- `UsageStore` owns observable state, preferences, refresh timing, rate-limit
  back-off, the persisted snapshot cache, and launch at login.
- `AppDelegate` owns the AppKit status item, native menu, settings window, and
  Touch Bar controller.
- `UsageTouchBarController` renders and updates the Touch Bar and observes which
  application is frontmost.
- `TouchBarSystemModal` isolates the optional undocumented AppKit selectors and
  checks their availability before use.

## Refresh timing

A 60-second tick checks eligibility, and each provider has its own floor. Codex
is a local subprocess and is fetched on every tick. Claude's endpoint is rate
limited per account, with the budget shared by every client signed in to the
account, so the store:

1. adopts Claude Code's on-disk copy whenever it is newer than what is shown,
   which costs no request;
2. sends its own request only when the data on screen is at least five minutes
   old (one minute for the manual Refresh button);
3. after an HTTP 429, skips the provider for five minutes, doubling on each
   consecutive 429 up to one hour. A positive `Retry-After` is honoured;
   `Retry-After: 0`, which this endpoint sends, is treated as unknown.

Snapshots, last-attempt times, and cooldowns are persisted, so a relaunch
continues the schedule instead of starting a fresh burst of requests.

## Failure behavior

- A request timeout terminates only the child Codex process.
- Parse and server failures are shown in the menu without terminating the app.
- If system-modal Touch Bar selectors are unavailable, the app uses only the
  public application Touch Bar path.
- Existing data remains visible when a later refresh fails.

## Distribution

`build-app.sh` builds a SwiftPM release binary, compiles the asset catalog,
constructs an application bundle, and signs it. `scripts/release.sh` verifies
the bundle and creates a versioned zip plus SHA-256 checksum.
