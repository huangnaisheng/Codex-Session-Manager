# Codex Session Manager

Two PowerShell utilities for inspecting and editing the local session data the
Codex CLI keeps under `%USERPROFILE%\.codex`.

| Script | Purpose |
| --- | --- |
| `codex-session-cleaner.ps1` | Browse saved sessions by title and delete them through `codex delete` |
| `fix-thread-model.ps1` | Bulk-rewrite the model bound to saved sessions |

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- Codex CLI installed and available as the `codex` command
- Node.js 22.5+ for `fix-thread-model.ps1`, which uses the built-in `node:sqlite` module

Both scripts take `-CodexHome` if your Codex data directory is not the default.

## Cleaning up sessions

`codex-session-cleaner.ps1` scans the `.jsonl` files under `.codex\sessions`,
extracts the first user message from each as a readable title, and shows the
title, last modified time and session UUID together. Deletion runs
`codex delete <UUID> --force` instead of modifying session files directly.

```powershell
.\codex-session-cleaner.ps1
.\codex-session-cleaner.ps1 -Query 'only reply ok'
.\codex-session-cleaner.ps1 -Query 'test session' -Force
.\codex-session-cleaner.ps1 -CodexHome 'C:\AnotherUser\.codex'
```

The first command scans all sessions and immediately opens the visual selector.
Use `-Query` when you want to narrow the list by title keyword first. The old
`-Delete` switch is still accepted for compatibility, but it is no longer needed.

### Interactive selector

| Key | Action |
| --- | --- |
| `Up` / `Down` | Move the cursor |
| `Space` | Select or clear the highlighted session |
| `A` / `N` | Select all / clear all |
| `Enter` | Review the selected sessions |
| `Esc` / `Q` | Cancel |

The script then lists the selection again and asks for the uppercase confirmation
word `DELETE`. When output is redirected or an interactive console is unavailable,
it falls back to comma-separated numbers or `all`. For trusted automation, skip
the final confirmation prompt with `-Force`.

## Changing the model of saved sessions

Codex stores the model each session used in `state_5.sqlite`, table `threads`,
column `model`. Resuming an old session reads that value instead of the global
`model` in `config.toml` — which is why old sessions keep using an old model even
after you change the default. `fix-thread-model.ps1` rewrites it.

```powershell
# Preview only, nothing is written
.\fix-thread-model.ps1 -Model gpt-6.1-sol -DryRun

# Rewrite every session whose model differs, and set the reasoning effort too
.\fix-thread-model.ps1 -Model gpt-6.1-sol -Effort high

# Only specific sessions
.\fix-thread-model.ps1 -Model gpt-6.1-sol -Id 01a0f31c-18c5-7fe1-8889-8326ca8a28ba
```

Run `-DryRun` first. Without `-Id` the script rewrites *every* session whose model
differs from the target, which may include sessions you meant to leave alone. It
also overwrites `reasoning_effort` when `-Effort` is given, and raising the effort
increases token usage on those sessions.

Before writing anything it copies `state_5.sqlite`, together with its `-wal` and
`-shm` companions, to timestamped `.bak-*` files, and the update runs inside a
transaction that rolls back on failure.

### The app-server daemon must be closed first

The daemon caches thread metadata in memory and holds an open handle on
`state_5.sqlite`, so it would write the old model back over the change — and even
without that, the new value would not show up until a restart.

The guard is a **handle probe, not a process-name check**: the script tries to
open `state_5.sqlite` (plus `-wal`/`-shm`) with `FileShare.None` and refuses to
run while any of them is still held. The distinction matters because
`codex-windows-sandbox-service.exe` is an auto-start Windows service that signing
out does not stop, yet it never touches thread metadata and is safe to leave
running. `-Force` bypasses the probe.

To release the handle, sign out of Windows, or end the `codex.exe app-server`
daemon and its `codex-code-mode-host.exe` child. Closing the GUI is not enough:
the daemon is left behind as an orphan process when the app exits.

A single session can be changed without touching the database at all — resume it
with an explicit model and the next turn is recorded under that model:

```powershell
codex resume 01a0f31c-18c5-7fe1-8889-8326ca8a28ba -m gpt-6.1-sol
```

## Safety

`codex delete` permanently removes a saved session. The selector always shows the
selected sessions again and requires explicit confirmation unless `-Force` is
supplied. Always verify the titles and UUIDs before confirming.

`fix-thread-model.ps1` writes to `state_5.sqlite` directly. It backs the database
up first and rolls back on failure, but quit Codex before running it and keep the
`.bak-*` files until you have confirmed the result.

## License

MIT License. See [LICENSE](LICENSE).
