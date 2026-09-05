# Security policy

## Supported version

Security fixes are provided for the latest published release.

## Reporting a vulnerability

Please do not disclose a suspected vulnerability in a public issue. Use
GitHub's private vulnerability reporting feature for the repository. Include:

- the affected version;
- reproduction steps;
- expected and actual behavior;
- any relevant crash log, with account and local path information removed.

## Security model

Codex Usage Bar launches the locally installed `codex app-server --stdio`
process and sends a read-only rate-limit request. It does not request, copy, or
store Codex account tokens.

For Claude it reads the access token that Claude Code already stores (Keychain
item `Claude Code-credentials`, or `~/.claude/.credentials.json`) and uses it
for a single read-only request to `https://api.anthropic.com/api/oauth/usage`.
The token stays in memory only for that request; it is never persisted, logged,
or refreshed, and the refresh token is never read. Claude Code's config file
`~/.claude.json` is read, never written, for its cached copy of the same data.
See [docs/PRIVACY.md](docs/PRIVACY.md) for details.
