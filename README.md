# MochAI

Your tiny supervisor for AI coding agents.

MochAI lives in the macOS menu bar. It watches the coding agents installed on this Mac, keeps the Mac awake only while one is actually working, and can continue an interrupted Claude or Codex session after a usage limit resets.

[![Build](https://github.com/sdglhm/mochai/actions/workflows/build.yml/badge.svg)](https://github.com/sdglhm/mochai/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Source: https://github.com/sdglhm/mochai

![MochAI mascot](branding/mochai-mascot.png)

## Features

- Claude Code and Codex supervision through local lifecycle hooks and process inspection
- Cursor counts as working while its Agents window, or the `cursor-agent` process, is busy. An open Cursor window by itself does not
- Allowances and reset times for Claude, Codex, Cursor, OpenCode Go, and Antigravity, when that tool can actually report them
- Keep-awake that holds idle system sleep and leaves the display free to sleep
- A green mark on the menu bar, and beside the agent name, while one is working
- Quota naps: sleep prevention stops when an agent is waiting on a limit
- Reset notifications, with notify, ask, or automatic resume for Claude and Codex
- Session continuation with `claude --resume` and `codex resume`
- Optional token cost: a this-month estimate for Claude and Codex, and the spend Cursor reports for the current cycle
- A local agent queue, history, and project policies
- Several agents at the same time, with one shared sleep assertion

## Build

MochAI is a native macOS 14 or later app. It has no Dock icon unless you turn one on. The project uses ad-hoc signing, so an Apple Developer team is not required.

```bash
xcodebuild -project MochAI.xcodeproj -scheme MochAI -destination 'platform=macOS' build
```

The product is `MochAI.app`, bundle identifier `app.mochai.MochAI`. GitHub Actions builds this same app on every push and pull request, runs the unit tests, and uploads the app as a build artifact.

On first launch, onboarding can install the Claude and Codex hooks. MochAI reads the existing config, writes a timestamped backup under `~/Library/Application Support/MochAI/backups`, merges only its own hook entries, and restores the backup if the result does not validate. Removing an integration deletes only commands that contain `mochai-hook`.

The hook helper is copied to `~/Library/Application Support/MochAI/bin/mochai-hook`. Events arrive on a Unix socket at `~/Library/Application Support/MochAI/mochai.sock`. If MochAI is not listening, the helper writes a small JSON file and exits successfully so it never blocks the agent. There is no network listener.

Launch at login uses `SMAppService`. The app does not check for updates on its own.

## Privacy

MochAI runs on this Mac. It does not upload prompts, repository contents, source code, or terminal output, and it does not write provider credentials to its own disk or logs.

An allowance check uses the sign-in already on this Mac and sends it only to that provider's own usage service, in memory, for that request. Antigravity is different: its allowance is read from the local process, and only while Antigravity is already open. MochAI does not launch it, and it does not use a Google login or browser cookies.

Hooks forward metadata only: provider, event type, session id, working directory, timestamp, and a tool category. Command names are stored only if you turn that setting on. The default is off.

MochAI does not ask for Claude or ChatGPT browser cookies.

## Allowance and resume

MochAI shows a number only when a provider reported it. It does not invent a percentage.

**Claude and Codex.** The allowance comes from the sign-in already on this Mac. That sign-in is sent only to the provider's own usage service, kept in memory for the request, and is not saved. MochAI stores the percentages and reset times. It does not read prompts out of session logs. If the live report is unavailable, Claude uses the figures recorded after a reply, and Codex uses the latest `rate_limits` object in its session logs.

A Claude report can include the 5-hour window, the weekly window, and a separate Sonnet or Opus window when the account has one. A Codex report can include the 5-hour window, the weekly window, and an extra model pool, such as Spark, when Codex reports one.

**Cursor.** Cursor does not write its allowance into a local file. When Cursor is installed and signed in, MochAI asks Cursor for the monthly Cursor-models pool, the other-models pool, and on-demand spend when that cap exists. The sign-in stays in memory for the request. Cursor counts as working while its Agents window, or the `cursor-agent` process, is busy. An open Cursor window by itself does not. Cursor sessions continue in the Cursor app.

**OpenCode Go.** The row appears when the OpenCode CLI or a saved key is on this Mac. MochAI asks `opencode.ai` for the 5-hour, weekly, and monthly allowances. The key stays in memory for that request.

**Antigravity.** The row appears when the app or `agy` is installed. The allowance is read from the local process only while Antigravity is already open. MochAI does not launch it, and it does not use a Google login or browser cookies.

**Token cost.** This can be turned off in Settings. Claude and Codex show a this-month estimate from token counts already recorded on this Mac. Cursor shows the spend it reports for the current cycle. Prompt text is not kept. OpenCode Go and Antigravity do not show a dollar amount.

**Continuing a session.** Codex uses `codex resume`, with the session id when one was captured. If it was not, MochAI opens Codex in the project and says that resume needs confirmation. Automatic resume is refused when the repository is missing, its origin changed, the session was cancelled, the provider is disabled, another resume is already in flight, usage still looks limited, or the executable does not validate. A project marked sensitive asks first, unless that project explicitly chooses automatic resume. MochAI never adds `--dangerously-skip-permissions`. If the reset time passes but usage still cannot be confirmed, MochAI notifies you and does not resume on its own.

## Development

```bash
xcodebuild -project MochAI.xcodeproj -scheme MochAI -destination 'platform=macOS' test -only-testing:MochAITests
```

UI tests launch the accessory app with `--mochai-ui-testing` and open onboarding, the dashboard, or settings.

```text
MochAI.app     Menu bar, settings, and extra windows
MochAICore     Sessions, sleep, providers, hooks, persistence, and UI
mochai-hook    Sanitizes provider hook input and forwards it locally
```

Providers implement `AgentProvider`. Claude and Codex own detection, usage, resume, and hook installation. Cursor, OpenCode Go, and Antigravity contribute allowance, and Cursor is also watched from its agent process. The UI talks to `AppModel`, not to provider files.

Sleep is one assertion for every qualifying session. Waiting for a person, a permission prompt, a quota reset, or a finished task releases it. Persistence is SwiftData (`MochAISchemaV1`) plus `UserDefaults` for settings. Domain models stay structs, so tests can use an in-memory repository without the GUI.

Regenerate the app icon from the mascot:

```bash
swiftc -framework AppKit -o /tmp/mochai-icon scripts/generate-icon.swift
/tmp/mochai-icon MochAI/Assets.xcassets/AppIcon.appiconset branding/mochai-mascot.png
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Keep provider logic inside `MochAICore/Providers`. Hooks stay metadata-only. Do not put API keys, session logs, or prompts in an issue or pull request.

## Security

See [SECURITY.md](SECURITY.md). Report a vulnerability through [GitHub Security Advisories](https://github.com/sdglhm/mochai/security/advisories/new). Do not open a public issue that contains a credential, a prompt, or a session log.

## Credits

Provider marks for Claude, OpenAI, Cursor, and OpenCode are from [Simple Icons](https://simpleicons.org) (CC0). The MochAI mascot and the Antigravity mark are original.

Claude, Codex, Cursor, OpenCode, and Antigravity are products of their respective owners. MochAI is not affiliated with them.

## License

[MIT](LICENSE). Copyright © 2026 Lahiru Himesh Madusanka.
