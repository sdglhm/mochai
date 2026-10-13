# Contributing

Thanks for looking at MochAI. The useful change is a small one that keeps the app honest about what it knows.

## Build and test

You need macOS 14 or later and Xcode. No Apple Developer team is required.

```bash
xcodebuild -project MochAI.xcodeproj -scheme MochAI -destination 'platform=macOS' build
xcodebuild -project MochAI.xcodeproj -scheme MochAI -destination 'platform=macOS' test -only-testing:MochAITests
```

GitHub Actions runs the same build and the unit tests. UI tests are local: they launch the app with `--mochai-ui-testing`.

Run `MochAITests` before sending a change. The tests that matter cover state transitions, sleep aggregation, usage parsing, reset retries, resume policy, hook merge and removal, event deduplication, and persistence.

## Where a change belongs

Keep provider logic inside `MochAICore/Providers`. A new agent implements `AgentProvider` and maps its lifecycle events onto `NormalizedEvent`. Do not thread provider-specific branches through the menu or the dashboard.

The UI talks to `AppModel`. Domain models stay structs so tests can use an in-memory repository.

## Privacy rules

Hooks forward metadata only: provider, event type, session id, working directory, timestamp, and a tool category. Do not log prompts, file contents, command arguments, or credentials.

An allowance check may use a sign-in that is already on the machine. Keep that value in memory for the request. Do not write it to disk, UserDefaults, SwiftData, or the log.

Do not include API keys, session logs, prompts, or terminal output in an issue, a pull request, or a commit.

## Pull requests

- Describe the behavior you changed and why.
- Add or update a test when the change affects state, usage parsing, sleep, hooks, or resume.
- Leave unrelated files alone.
