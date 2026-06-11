# Security Policy

## How Cookie Monster handles your credentials

- It reads the **Claude Code OAuth access token** from your macOS login keychain
  (`Claude Code-credentials`) **read-only**. It never writes to or modifies the
  keychain, and never refreshes your token.
- The token is sent **only** to `https://api.anthropic.com/api/oauth/usage` — the
  same endpoint Claude Code uses for `/usage`. It is sent nowhere else and is never
  written to disk.
- The diagnostic log at `~/.cookie-monster/cookie-monster.log` contains only
  timestamps, HTTP status codes, and usage percentages — **never** the token or the
  raw API response.
- There are no third-party servers, analytics, or telemetry.

## Reporting a vulnerability

Please report security issues **privately** using GitHub's
[Report a vulnerability](https://github.com/davidpflugpeil/cookie-monster/security/advisories/new)
(Security → Advisories) rather than opening a public issue. We'll respond as quickly
as we can.

## Supported versions

The latest release is supported. Older versions are not maintained.
