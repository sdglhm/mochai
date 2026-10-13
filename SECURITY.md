# Security

MochAI is a local menu-bar app. It reads sign-ins that are already on this Mac so it can ask each provider for an allowance. Those values stay in memory for the request. They are not written to MochAI's disk or logs.

## Reporting a vulnerability

Use [GitHub Security Advisories](https://github.com/sdglhm/mochai/security/advisories/new).

Do not open a public issue, pull request, or discussion that contains:

- an API key, access token, or session cookie
- a prompt, a session log, or terminal output
- the contents of `~/.codex/auth.json`, `~/.claude/.credentials.json`, Cursor's local database, or an OpenCode auth file

Describe the impact and a way to reproduce it without those secrets. If a trace is necessary, redact it first.

## In scope

- Handling of provider sign-ins and local credentials
- The hook helper and the local Unix socket
- Resume commands, including anything that could add a permission-bypass flag
- Data written under `~/Library/Application Support/MochAI`

## Out of scope

- Vulnerabilities in Claude, Codex, Cursor, OpenCode, Antigravity, or macOS itself
- A missing allowance figure. MochAI leaves a number out when the provider did not report one

## What a build should not do

A change that logs command arguments, stores a token, or phones home for anything other than that provider's own usage service needs a security review before it is merged.
