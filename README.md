# Codex Session Manager

Two PowerShell scripts for working with the local session data the Codex CLI
stores under `%USERPROFILE%\.codex`.

- `codex-session-cleaner.ps1` lists saved sessions by title and deletes them
  through `codex delete`.
- `fix-thread-model.ps1` rewrites the model that saved sessions are bound to.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- Codex CLI on `PATH`
- Node.js 22.5+, needed by `fix-thread-model.ps1` for `node:sqlite`

Both scripts accept `-CodexHome` if your Codex data directory is not the default.

## Cleaning up sessions

The cleaner reads the `.jsonl` files under `.codex\sessions`, takes the first user
message from each as a title, and prints the title, last modified time and session
UUID. Deletion goes through `codex delete <UUID> --force`, so session files are
never edited directly.

```powershell
.\codex-session-cleaner.ps1
.\codex-session-cleaner.ps1 -Query 'only reply ok'
.\codex-session-cleaner.ps1 -Query 'test session' -Force
.\codex-session-cleaner.ps1 -CodexHome 'C:\AnotherUser\.codex'
```

Run it with no arguments to scan everything and open the selector. `-Query`
narrows the list by title keyword first. The old `-Delete` switch still works but
is no longer needed.

In the selector:

| Key | Action |
| --- | --- |
| `Up` / `Down` | move the cursor |
| `Space` | select or clear the highlighted session |
| `A` / `N` | select all / clear all |
| `Enter` | review the selection |
| `Esc` / `Q` | cancel |

It then prints the selection and asks for the word `DELETE`. If output is
redirected or there is no interactive console, it accepts comma-separated numbers
or `all` instead. `-Force` skips the prompt.

## Changing the model of saved sessions

Codex stores the model for each session in `state_5.sqlite`, in the `threads`
table. `codex resume` reads that value, not the global `model` in `config.toml`.
Changing the default therefore leaves existing sessions on their old model.
`fix-thread-model.ps1` rewrites the stored value.

```powershell
# Preview only
.\fix-thread-model.ps1 -Model gpt-6.1-sol -DryRun

# Rewrite every session not already on this model, and set reasoning effort
.\fix-thread-model.ps1 -Model gpt-6.1-sol -Effort high

# Rewrite specific sessions only
.\fix-thread-model.ps1 -Model gpt-6.1-sol -Id 01a0f31c-18c5-7fe1-8889-8326ca8a28ba
```

Preview with `-DryRun` first. Without `-Id`, every session whose model differs
gets rewritten, including ones you may have wanted to leave alone. If you pass
`-Effort`, `reasoning_effort` is overwritten too, which raises token usage on
those sessions.

Before writing, the script copies `state_5.sqlite` and its `-wal`/`-shm`
companions to `.bak-*` files. The update is one transaction and rolls back on
failure.

### Close the app-server daemon first

The daemon caches thread metadata in memory and keeps `state_5.sqlite` open. While
it is running it can write the old model back, and the new value would not show up
until a restart anyway.

The script checks by trying to open `state_5.sqlite`, `-wal` and `-shm` with
`FileShare.None`, and refuses to run if any of them is held. It does not look at
process names, because `codex-windows-sandbox-service.exe` starts with Windows,
survives signing out, and never touches thread metadata. That one can stay
running. `-Force` skips the check.

To release the handle, sign out of Windows, or end the `codex.exe app-server`
daemon and its `codex-code-mode-host.exe` child. Closing the GUI is not enough:
the daemon is left behind as an orphan when the app exits.

To fix one session without touching the database, resume it with an explicit
model:

```powershell
codex resume 01a0f31c-18c5-7fe1-8889-8326ca8a28ba -m gpt-6.1-sol
```

## Safety

`codex delete` removes a session permanently. The selector shows the selection
again and asks for confirmation unless `-Force` is given, so check the titles and
UUIDs before typing `DELETE`.

`fix-thread-model.ps1` writes to `state_5.sqlite` directly. It backs the file up
first and rolls back failed writes, but close Codex before running it and keep the
`.bak-*` files until you have checked the result.

## License

MIT License. See [LICENSE](LICENSE).
