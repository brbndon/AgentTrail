# AgentTrail

A local macOS app for browsing Codex coding-agent sessions.

## What it does

- Reads Codex session files from `~/.codex/sessions` and keeps imported data on this Mac.
- Search, filter, sort, and group sessions by project.
- Review conversation turns, tool calls, errors, commands, and recorded file changes.
- See active Codex sessions in the app and menu bar.

The shipping import currently supports Codex. Cursor and Grok Build parsers are present in the source but are not enabled in the app.

## Requirements

- macOS 15 or newer
- Xcode 16 or newer
- Swift 6

## Build and test

Open `AgentTrail.xcodeproj`, select the **AgentTrail** scheme and **My Mac**, then run the app. The project configuration is in `project.yml`; use XcodeGen only when changing project or target configuration.

Run the `AgentTrailTests` target in Xcode. Tests use sanitized fixtures and do not read or modify your real Codex history.

## Privacy

AgentTrail does not use a network service. It reads local session files and stores its library under `~/Library/Application Support/AgentTrail/`.

Session history can contain prompts, command output, and file paths. Treat raw payload previews, copied content, and screenshots as sensitive.