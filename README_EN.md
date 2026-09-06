<p align="center">
  <img src="Resources/AppIcon-1024.png" width="128" height="128" alt="Codex Usage Bar icon">
</p>

<h1 align="center">Codex Usage Bar</h1>

<p align="center">See your remaining Codex and Claude usage in the macOS menu bar and Touch Bar.</p>

<p align="center"><a href="README.md">中文</a> · <a href="CHANGELOG.md">Changelog</a> · <a href="CONTRIBUTING.md">Contributing</a></p>

> [!IMPORTANT]
> This is an unofficial community project. It is not affiliated with, sponsored by, or endorsed by OpenAI or Anthropic. The local Codex app-server interface, the Claude usage endpoint, and persistent Touch Bar behavior may change without notice.

## Features

- Shows five-hour and weekly remaining usage in the menu bar, for Codex or Claude.
- Codex and Claude side by side: Claude usage comes from the Claude Code login on this Mac and includes per-model weekly windows such as Opus and Sonnet.
- Uses a native macOS menu for progress, reset times, credits, and resets.
- Configurable menu bar icon, icon size, and text size.
- Percentages shown as remaining or as used, with configurable orange and red alert thresholds for the menu and Touch Bar.
- Follows the system language by default, with in-app switching between Simplified Chinese, Traditional Chinese, English, Japanese, Korean, and Spanish.
- Optional launch at login. Codex refreshes every minute; Claude is requested at most every five minutes.
- Touch Bar progress, percentages, reset times, and manual refresh, for one provider or both.
- Optional automatic Touch Bar presentation while Codex is frontmost.
- No third-party dependencies and no separate API key.

## Requirements

- macOS 14.0 or later.
- For Codex: Codex desktop installed and signed in, or a compatible `codex` executable in a common installation path.
- For Claude: Claude Code signed in on this Mac (CLI or VS Code extension). Each provider can be switched off in Settings, so either one alone is enough.
- Touch Bar features require a Touch Bar-equipped MacBook Pro. The menu bar works on other Macs.

## Install

### GitHub Release

1. Download the latest `Codex-Usage-Bar-v*.zip`.
2. Extract it and move `Codex Usage Bar.app` to `/Applications`.
3. If Gatekeeper blocks the first launch, review and allow it in System Settings → Privacy & Security.

Community builds without Developer ID signing and notarization may display additional security warnings. Only run builds you trust.

### Build from source

```bash
git clone https://github.com/hoover91125/codex-usage-bar.git
cd codex-usage-bar
./build-app.sh dist
open "dist/Codex Usage Bar.app"
```

The default build is universal (`arm64` and `x86_64`). To build only for the current architecture:

```bash
CODEX_USAGE_ARCHS="$(uname -m)" ./build-app.sh dist
```

## How it works

### Codex

The app launches the locally installed:

```text
codex app-server --stdio
```

and sends the read-only `account/rateLimits/read` request. It does not read or store cookies, access tokens, or conversation content.

### Claude

Claude usage comes from the Claude Code login on this Mac:

1. The app first reads the usage that Claude Code itself caches in its config file `~/.claude.json` (`cachedUsageUtilization`), read-only. While that copy is less than five minutes old, no request is made at all.
2. When it is stale, the app reads Claude Code's access token from the macOS Keychain item `Claude Code-credentials` (or `~/.claude/.credentials.json`) and sends one read-only request to `https://api.anthropic.com/api/oauth/usage`. The token stays in memory only for that request; it is never written to disk or logged, and the refresh token is never read.

The endpoint is rate limited per account, and the budget is shared with Claude Code itself and any other tool that polls it. After an HTTP 429 the app waits five minutes, doubling on each consecutive 429 up to one hour.

The app contains no telemetry or third-party analytics. See [docs/PRIVACY.md](docs/PRIVACY.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Touch Bar compatibility

Normal content uses public `NSTouchBar` APIs. Automatic presentation while Codex is frontmost uses undocumented AppKit system-modal selectors after checking for them at runtime. Therefore it cannot be distributed through the Mac App Store and may stop working after a macOS update. The menu bar remains functional when the selector is unavailable.

See [docs/TOUCH_BAR.md](docs/TOUCH_BAR.md).

## Development and release

```bash
swift build
./build-app.sh dist
./scripts/release.sh
```

The build script uses ad-hoc signing by default. For public Developer ID builds:

```bash
CODE_SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
  ./scripts/release.sh
```

Keep certificates, passwords, and notarization credentials out of the repository.

## License and trademarks

Source code and original project assets are available under the [MIT License](LICENSE). See [NOTICE.md](NOTICE.md) for the unofficial-project and trademark notice.
