# AgentTrail

AgentTrail is a local macOS viewer for understanding what coding agents did inside a project. The current app is intentionally Codex-first: it reads Codex JSONL session history from `~/.codex/sessions`, normalizes useful conversation and tool events, and keeps all imported data on the Mac.

## Current experience

- Loads the 30 most recently updated Codex threads on launch.
- Sorts threads newest-first by source modification time.
- Loads older history in explicit pages of up to 30 threads; the button shows how many older sessions remain in the next page.
- Searches the loaded sessions, with a clear recovery action when search or filters match nothing.
- Groups each globally newest-first page by project and shows total imported thread counts without loading full session histories.
- Uses Codex `session_meta` and `turn_context` records to identify the workspace.
- Uses canonical `user_message` and `agent_message` records (event messages or completed items) for clean task titles and conversation steps, without repeating the mirrored response messages.
- Links tool results back to their call IDs (including across incremental refreshes) so commands, tool names, failures, and exit codes are easier to diagnose.
- Normalizes direct and nested Codex command, patch, file-change, and MCP completion records into concise semantic steps.
- Stores normalized metadata in SwiftData and raw event payloads in private local files.
- Loads raw payload previews only when their inspector disclosure is expanded.
- Persists private, derived Codex checkpoints so growing active sessions resume at the last complete JSONL record.
- Watches `~/.codex/sessions` for active-session updates.
- Shows a menu bar extra for Codex sessions whose history files were written in the last three minutes.
- Holds an exclusive lease on the shared Application Support library so installed, disk-image, and Xcode builds cannot import into it concurrently.

Grok Build and Cursor parsers still exist in the source tree, but the shipping workflow does not scan them while their formats and UX are being stabilized.

## Requirements

- macOS 15 or newer
- Xcode 16 or newer
- Swift 6

## Development

Open `AgentTrail.xcodeproj`, select the **AgentTrail** scheme and **My Mac**, then run the app. The checked-in Xcode project is generated from `project.yml`; use XcodeGen when changing target or file membership configuration.

Run the `AgentTrailTests` target before distributing a build. Sanitized compatibility fixtures live under `AgentTrailTests/Fixtures/Codex`; tests copy them into temporary directories and never read or modify the real Codex history.

## Data and privacy

AgentTrail does not use a network service. It reads local session files and writes its library under:

```text
~/Library/Application Support/AgentTrail/
```

Raw payload previews can include prompts, command output, and file paths from the original session. Treat exported screenshots or copied payloads as potentially sensitive.

The `Checkpoints` subfolder contains normalized copies of imported session data and is protected with owner-only permissions. It is derived cache state, not a second source of truth; incompatible or invalid checkpoints are ignored and rebuilt from the read-only Codex session file.

Installed, disk-image, and Xcode development copies use this same library. Launch Services prevents ordinary duplicate launches; if another copy still starts (for example, an older build or an explicit development launch), the newer copy stays read-only, explains the conflict, and offers to bring the owning copy forward. Quit the owning copy before switching builds; AgentTrail never resets the library to resolve an ownership conflict.

## How Codex import works

1. Enumerate regular, non-symlink `.jsonl` files under `~/.codex/sessions`.
2. Sort them by modification date, newest first.
3. Import only the currently requested page count (30, 60, 90, and so on).
4. Skip unchanged files. For a growing file, validate its device/inode and prefix digests, then resume at the last complete record.
5. Reset the derived checkpoint after truncation, replacement, or prefix changes; defer malformed trailing partial records until they are complete.
6. Prefer `session_meta` for the session start time and workspace path.
7. Prefer canonical Codex conversation events and suppress duplicated injected context messages.
8. Preserve each selected raw JSONL record in the local payload store for detailed inspection.

Malformed complete records degrade one session instead of blocking the whole library. A partial trailing record is left uncheckpointed until a later append completes it. A file that changes during its two-pass read is retried on a later refresh rather than being saved as a mixed snapshot.

## Near-term roadmap

- Add opt-in export with automatic secret and home-path redaction.
- Re-enable Grok Build and Cursor only after their pagination, metadata, and regression coverage match the Codex path.
