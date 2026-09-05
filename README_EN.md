<p align="center">
  <img src="Resources/AppIcon-1024.png" width="128" height="128" alt="Codex Usage Bar icon">
</p>

<h1 align="center">Codex Usage Bar</h1>

<p align="center">See your remaining Codex usage in the macOS menu bar and Touch Bar.</p>

<p align="center"><a href="README.md">中文</a> · <a href="CHANGELOG.md">Changelog</a> · <a href="CONTRIBUTING.md">Contributing</a></p>

> [!IMPORTANT]
> This is an unofficial community project. It is not affiliated with, sponsored by, or endorsed by OpenAI. The local Codex app-server interface and persistent Touch Bar behavior may change without notice.

## Features

- Shows five-hour and weekly remaining usage in the menu bar.
- Uses a native macOS menu for progress, reset times, credits, and resets.
- Configurable menu bar icon, icon size, and text size.
- Follows the system language by default, with in-app switching between Simplified Chinese, Traditional Chinese, English, Japanese, Korean, and Spanish.
- Optional launch at login and automatic refresh every five minutes.
- Touch Bar progress, percentages, reset times, and manual refresh.
- Optional automatic Touch Bar presentation while Codex is frontmost.
- No third-party dependencies and no separate API key.

## Requirements

- macOS 14.0 or later.
- Codex desktop installed and signed in, or a compatible `codex` executable in a common installation path.
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

The app launches the locally installed:

```text
codex app-server --stdio
```

and sends the read-only `account/rateLimits/read` request. It does not read or store cookies, access tokens, or conversation content, and contains no telemetry or third-party analytics.

See [docs/PRIVACY.md](docs/PRIVACY.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

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
