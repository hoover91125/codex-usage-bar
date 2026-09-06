# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

- Claude usage alongside Codex, read from the Claude Code login on this Mac: five-hour and weekly windows, per-model weekly windows, extra-usage credits, and the subscription type.
- Per-provider enable switches and a choice of which provider the menu bar title shows.
- Touch Bar content modes for one or both providers, including a compact per-provider layout and a Control Strip placement option.
- A display setting that shows every percentage (menu bar, menu, Touch Bar) as either remaining or used, with progress bars following the same choice.
- Configurable alert thresholds: the remaining percentage at which a window turns orange and red, shown in used terms when the display is set to used. Defaults are 30% and 10% remaining, and the settings page draws the three bands as a preview strip that moves with the sliders.
- A pace mark on every progress bar: a hairline at the point an even burn would have reached by now, so being ahead of schedule is visible without a second number. A window burning noticeably fast also gets a rate badge beside its percentage.
- The menu bar title takes the alert color once a window falls past a threshold. It keeps the system's own color at rest, so it still dims along with an inactive menu bar.
- Extra-usage spend is read from the newer `spend` money objects as well as the older `extra_usage` credit fields.
- The menu says when a rate-limited provider will next be retried automatically.

### Changed

- Claude usage is taken from Claude Code's own cached copy in `~/.claude.json` whenever that is newer than what is shown, so no request is made while Claude Code refreshed it within the last five minutes.
- After an HTTP 429 from the Claude usage endpoint the app waits five minutes, doubling on each consecutive 429 up to one hour. `Retry-After: 0` is treated as unknown instead of as a one-minute cooldown.
- Snapshots and rate-limit state survive a relaunch, so restarting the app no longer sends an immediate burst of requests.
- Checking whether a Claude login exists no longer spawns a subprocess: it is an attributes-only Security framework query, which resolves in milliseconds and never touches the token. Reading the token itself still uses the `security` command, which measured far faster than the framework call for that, with the framework read kept as a fallback.
- Claude's refresh interval doubles on battery, and refreshing pauses entirely while the display sleeps.
- Signing in as a different Claude account clears that provider's rate-limit back-off, since the endpoint's budget is per account.
- The manual Refresh button may spend one attempt through a rate-limit cooldown, at most once a minute. Automatic refreshes still respect it in full.
- The menu is denser: each window is three lines rather than four, and the reset time is a countdown with the wall-clock time beside it. Per-model weekly limits are drawn by the same row as the headline windows instead of a smaller variant of their own, and drop the countdown when it would only repeat the weekly one. Account facts share a single footer line, which is hidden when there is nothing to put in it.
- The settings window is a sidebar of five panes (Services, Display, Menu Bar, Touch Bar, General) rather than one long scrolling form, each row carrying a tinted symbol so the panes are told apart by color.
- The compact two-provider Touch Bar layout no longer clips its labels in any language: the five-hour column and reset rows use "5h" instead of the localized long form, and the column and reset widths are measured at launch against the widest text every supported language can produce.

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
