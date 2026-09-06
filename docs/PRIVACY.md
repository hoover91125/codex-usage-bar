# Privacy

Codex Usage Bar is local-first and contains no telemetry, advertising, crash
reporting SDK, or third-party analytics. It shows usage for two providers,
Codex and Claude, and each can be switched off in Settings.

## Data the app reads

### Codex

The app starts a locally installed `codex app-server --stdio` process and sends
the read-only `account/rateLimits/read` request. The response may include:

- account plan type;
- remaining rate-limit percentages;
- rate-limit reset timestamps;
- credit balance and available reset count.

### Claude

Claude usage comes from the Claude Code login on this Mac, in two steps:

1. The app reads Claude Code's own config file, `~/.claude.json` (or
   `.claude.json` inside `CLAUDE_CONFIG_DIR`). Only the `cachedUsageUtilization`
   entry is used, plus the account id it is stamped with so numbers from a
   previous login are never shown. Nothing else in the file is read, and the
   file is never written. Claude Code refreshes that entry itself, so while it
   is less than five minutes old no request is made at all.
2. When that entry is missing or older than five minutes, the app reads Claude
   Code's OAuth access token from the macOS Keychain item
   `Claude Code-credentials` (through `/usr/bin/security`, falling back to the
   Security framework), or from `~/.claude/.credentials.json` when the Keychain
   item is absent, and sends a single read-only
   `GET https://api.anthropic.com/api/oauth/usage`.

Deciding whether to offer the Claude section at all needs only to know that a
login exists, so that check asks the Keychain for the item's attributes and not
its data. No secret is returned and no authorization decision is made.

Either way the data may include:

- subscription type (from the credentials, for example `max`);
- five-hour and weekly utilisation percentages and reset timestamps;
- per-model weekly windows (for example Opus or Sonnet);
- extra-usage credit settings and balance.

The access token is held in memory only for the duration of that request. It is
never written to disk, logged, or shown, and the refresh token is never read.

## Data the app stores

Preferences are saved with macOS `UserDefaults` under
`com.local.codexusagebar`:

- menu bar icon, icon size, and text size;
- which provider the menu bar title shows;
- whether each provider is enabled;
- Touch Bar display mode, content, compact layout, and placement;
- app language;
- alert thresholds, whether percentages read as remaining or used, whether the
  menu bar title takes an alert color, and whether progress bars draw the pace
  mark;
- `usageCacheV1`: the last snapshot from each provider, when each provider was
  last queried, and any rate-limit cooldown, so a relaunch shows the previous
  numbers instead of immediately sending new requests;
- `providerAccountIdentity`: the account id each provider was signed in as when
  its rate-limit state was written, so a cooldown earned by one account is not
  held against the next. For Claude this is the same `accountUuid` Claude Code
  keeps in `~/.claude.json`. It is an opaque identifier, not a credential.

Launch-at-login state is managed by Apple's `SMAppService`.

## Network behavior

The only network request the app makes itself is the Claude usage request
described above: at most once every five minutes, and only while the Claude
provider is enabled and Claude Code's cached copy is stale. On battery that
floor doubles to ten minutes, and nothing is requested at all while the display
is asleep. That endpoint is rate limited per account, and the budget is shared
with Claude Code itself and any other tool using it. After an HTTP 429 the app
waits five minutes, doubling on each consecutive 429 up to one hour, and honours
a positive `Retry-After`. The Refresh button in the menu may spend one attempt
inside that cooldown, no more than once a minute; automatic refreshes never do.

The local Codex process may communicate with OpenAI as part of its normal
signed-in operation. Clicking “Official Usage” asks macOS to open
`https://chatgpt.com/codex/settings/usage` or `https://claude.ai/settings/usage`
in the default browser.

## Credentials

The app does not request, copy, log, or persist Codex cookies, access tokens, or
API keys; that authentication remains owned by the installed Codex client. For
Claude it reads the existing access token as described above and nothing else:
it never signs in, refreshes, or revokes tokens.

## Removing local data

Quit the app, disable launch at login, remove the application, and delete its
preferences if desired:

```bash
defaults delete com.local.codexusagebar
```
