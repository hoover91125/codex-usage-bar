# Touch Bar implementation

## Public API path

The application creates an `NSTouchBar` containing:

- five-hour usage and progress;
- weekly usage and progress;
- reset timestamps.

In `.both` content mode the reset item is narrower and shows only the 5-hour
resets, abbreviated per provider; with a single provider enabled it falls back
to the same text `.automatic` uses.

`.both` has a second layout behind the `touchBarBothCompact` preference. The
default builds one item per provider/window pair — four items, each repeating
its provider's name, which costs 480pt and leaves no room for reset times. The
compact layout groups by provider instead: the brand name is printed once per
item with both windows as columns beside it, so two items and a two-row reset
item fit in ~590pt. Each reset row names its provider and sits in the same
order as the items to its left.

Both `.both` layouts print the five-hour window as the language-neutral "5h"
(the form every translation of `touch_bar_reset` already uses) rather than the
localized `five_hour_short`: beside a three-digit percent the localized form is
61–76pt in the compact column's 11pt font, wider than any column that leaves
room for two per provider.

The compact layout's column and reset widths are measured at launch rather
than hardcoded (`widestLabel` in `TouchBar.swift`): every string the labels can
show is generated for every supported language — weekly prefixes, loading and
unavailable texts, and reset rows at a worst-case two-digit date in each
locale — and the widest `intrinsicContentSize` of a real label with the same
font and alignment sets the width, plus a few points of headroom. Measuring the
label rather than the string matters: a centered `NSTextField` needs ~4pt more
than its text and truncates below that, which is how a hand-picked width can
still clip. A new language or a longer translation is therefore picked up
without re-measuring, at the cost of item width; `.both`'s four-item layout
keeps its hand-sized constants, whose margins are recorded beside them.

Item widths are sized for the region left of the native Control Strip, not the
full strip (see `placement` below). There is no refresh button on the bar; the
menu bar popover owns that.

The bar is assigned to `NSApplication.touchBar` while Touch Bar display is
enabled. This path uses public AppKit APIs.

## Automatic presentation while Codex is frontmost

macOS does not provide a public API for one application to keep its full Touch
Bar visible while another application owns keyboard focus. To support the
requested behavior on Touch Bar MacBook Pro models, the app optionally invokes:

```text
presentSystemModalTouchBar:placement:systemTrayItemIdentifier:
dismissSystemModalTouchBar:
```

These AppKit selectors are undocumented. Calls are isolated behind runtime
availability checks. The feature is enabled only when:

1. Touch Bar display is enabled;
2. automatic Codex presentation is enabled;
3. the frontmost application bundle identifier is `com.openai.codex`;
4. both selectors exist in the current AppKit runtime.

The modal bar is dismissed when Codex is no longer frontmost.

## Control Strip tray icon and close box

`presentSystemModalTouchBar:placement:systemTrayItemIdentifier:` takes a
`placement` argument that decides how much of the strip the bar claims:

- `0` — the bar gets the region left of the native Control Strip, which stays
  in place and expands over the bar the way it does over any app's Touch Bar.
  This is the default.
- `1` — the bar takes over the whole strip and the Control Strip is
  unreachable while it is presented.

Neither value is documented, so the app reads it from `UserDefaults` and it can
be changed without a rebuild:

```sh
defaults write com.local.codexusagebar touchBarPlacement -int 1
```

Two further private entry points cover the `1` case, where the native controls
are otherwise unreachable. Both are inert at `placement` 0: the close box would
dismiss the bar with no notification and nothing to restore (the Control Strip
was never covered), which reads as the app having broken, and the tray icon
would cost a Control Strip slot for no benefit.

```text
DFRSystemModalShowsCloseBoxWhenFrontMost(BOOL)
DFRElementSetControlStripPresenceForIdentifier(NSString *, BOOL)
+[NSTouchBarItem addSystemTrayItem:] / removeSystemTrayItem:
```

The close box puts an ⓧ at the left edge of the presented bar; tapping it
returns the strip to the system. The tray item places a permanent icon in the
Control Strip that presents the usage bar again. Both are resolved at runtime
(`dlsym` for the DFRFoundation functions, `class_getClassMethod` for the
selectors) and are no-ops when absent.

The system dismisses the modal bar through the close box without notifying the
app, so `systemModalVisible` can be stale after a manual dismiss — and a
present call afterwards does not reliably bring the bar back, which is why the
close box is off unless the bar owns the whole strip. The tray button always
presents rather than toggling — one control per direction, no shared state to
keep in sync. A change to the item list also re-presents the bar (see
`rebuildDefaultItemIdentifiersIfNeeded`).

The tray icon is withdrawn in `teardown()` and `deinit`; a process that exits
without withdrawing it leaves a dead icon in the Control Strip until
ControlStrip/TouchBarServer restarts.

## Compatibility and review

- This behavior is not suitable for Mac App Store distribution.
- Apple may change or remove the selectors in any macOS release.
- Contributors must preserve the fallback and must not assume Touch Bar
  hardware exists.
- A failure of the optional path must never affect the menu bar usage display.
