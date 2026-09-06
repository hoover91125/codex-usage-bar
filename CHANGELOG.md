# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

- Claude usage alongside Codex, read from the Claude Code login on this Mac: five-hour and weekly windows, per-model weekly windows, extra-usage credits, and the subscription type.
- Per-provider enable switches and a choice of which provider the menu bar title shows.
- Touch Bar content modes for one or both providers, including a compact per-provider layout and a Control Strip placement option.
- A display setting that shows every percentage (menu bar, menu, Touch Bar) as either remaining or used, with progress bars following the same choice.
- Configurable alert thresholds: the remaining percentage at which a window turns orange and red, shown in used terms when the display is set to used. Defaults match the previous fixed 25% and 10%.

### Changed

- The compact two-provider Touch Bar layout no longer clips its labels in any language: the five-hour column and reset rows use "5h" instead of the localized long form, and the column and reset widths are measured at launch against the widest text every supported language can produce.
- Claude usage is taken from Claude Code's own cached copy in `~/.claude.json` whenever that is newer than what is shown, so no request is made while Claude Code refreshed it within the last five minutes.
- After an HTTP 429 from the Claude usage endpoint the app waits five minutes, doubling on each consecutive 429 up to one hour. `Retry-After: 0` is treated as unknown instead of as a one-minute cooldown.
- Snapshots and rate-limit state survive a relaunch, so restarting the app no longer sends an immediate burst of requests.

## [2.1.0] - 2026-08-31

### Added

- App-wide language switching with a system-default option.
- Simplified Chinese, Traditional Chinese, English, Japanese, Korean, and Spanish translations.
- Locale-aware date and time formatting in the usage menu and Touch Bar.

## [2.0.0] - 2026-08-30

### Added

- Native macOS menu bar usage display.
- Five-hour and weekly remaining quota with reset times.
- Configurable menu bar icon and text sizing.
- Launch-at-login support.
- Native menu presentation and settings window.
- Touch Bar usage progress, percentages, reset times, and refresh action.
- Optional automatic Touch Bar presentation while Codex is frontmost.

### Notes

- Usage data is read from the locally installed Codex app-server.
- Persistent Touch Bar presentation relies on an undocumented AppKit selector.
