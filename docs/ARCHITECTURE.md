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
  back-off, the persisted snapshot cache, and launch at login. It also owns the
  one rule every surface asks about color: `alertLevel(for:)` maps a window's
  remaining percentage to one of four bands against three user-set thresholds,
  and `UsageAlertLevel.nsColor` in `UsageTheme.swift` is where those bands get
  their colors for both AppKit and SwiftUI.
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
   old (one minute for the manual Refresh button), doubled while the Mac is on
   battery;
3. after an HTTP 429, skips the provider for five minutes, doubling on each
   consecutive 429 up to one hour. A positive `Retry-After` is honoured;
   `Retry-After: 0`, which this endpoint sends, is treated as unknown.

The tick is skipped entirely while the display is asleep, and one refresh runs
on wake.

The 429 cooldown stops the timer but not a person: the menu's Refresh button
passes `force`, which is allowed through the cooldown once a minute. The
cooldown exists so unattended polling cannot spend a budget nobody is watching,
and someone standing at an open menu looking at a stale number is the case
where one request is worth it.

Snapshots, last-attempt times, and cooldowns are persisted, so a relaunch
continues the schedule instead of starting a fresh burst of requests. They are
also stamped with the account they belong to: `accountIdentity()` reads the id
the provider's own tooling left on disk, and a change to it clears that
provider's back-off, since the budget it was earned against belonged to a
different account.

## Failure behavior

- A request timeout terminates only the child Codex process.
- Parse and server failures are shown in the menu without terminating the app.
- If system-modal Touch Bar selectors are unavailable, the app uses only the
  public application Touch Bar path.
- Existing data remains visible when a later refresh fails.

## Checking the interface

The menu and the settings panes are SwiftUI, and both are hard to screenshot in
place — one lives inside an `NSMenu`, and capturing the other needs Screen
Recording permission. `RenderPreview.swift` renders them straight to PNG
instead, hosting each view in an offscreen window so text rasterizes. The
settings pane is also captured once inside a real titled window, theme frame
and all, since its title bar is part of what can go wrong:

```sh
"dist/Codex Usage Bar.app/Contents/MacOS/CodexUsageBar" --render-preview /tmp/out
```

It has to run from inside the bundle, since that is what puts it in the app's
own `UserDefaults` domain and gives it the real cached data to lay out. The
whole file is behind `#if DEBUG`, so it is absent from the release binary the
application bundle ships.

## Distribution

`build-app.sh` builds a SwiftPM release binary, compiles the asset catalog,
constructs an application bundle, and signs it. `scripts/release.sh` verifies
the bundle and creates a versioned zip plus SHA-256 checksum.
