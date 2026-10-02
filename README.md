# Codex Session Manager

Three PowerShell scripts for working with the local data the Codex CLI stores
under `%USERPROFILE%\.codex`.

- `codex-session-cleaner.ps1` lists saved sessions by title and deletes them
  through `codex delete`.
- `fix-thread-model.ps1` rewrites the model that saved sessions are bound to, and
  refuses to do so for sessions that already have turns.
- `patch-model-catalog.ps1` edits the model catalog compiled into `codex.exe`, so
  the `/model` picker can list models the binary was never built with.

[MODEL-BINDING.md](MODEL-BINDING.md) has the measurements behind that refusal.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- Codex CLI on `PATH`
- Node.js 22.5+, needed by `fix-thread-model.ps1` for `node:sqlite` and by
  `patch-model-catalog.ps1` for the binary rewrite

The session scripts accept `-CodexHome` if your Codex data directory is not the
default. `patch-model-catalog.ps1` takes `-Target` instead, and finds the binary
behind the `codex` command on its own.

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

Rewriting it is only safe for sessions that have no turns yet. A session that
already has turns replays stored history, and that history only resolves on the
model that produced it. Switch the model and the provider rejects the replay with
`invalid_request`, and the session stops working. Putting the old value back does
not repair it. The script refuses those sessions.

```powershell
# Preview. A dry run writes nothing and refuses nothing.
.\fix-thread-model.ps1 -Model gpt-6.1-sol -DryRun

# Rewrite every session not already on this model. Sessions with turns are refused.
.\fix-thread-model.ps1 -Model gpt-6.1-sol -Effort high

# Limit the run to specific sessions
.\fix-thread-model.ps1 -Model gpt-6.1-sol -Id 01a0f31c-18c5-7fe1-8889-8326ca8a28ba

# Write anyway, accepting that those sessions stop resuming
.\fix-thread-model.ps1 -Model gpt-6.1-sol -Id 01a0f31c-18c5-7fe1-8889-8326ca8a28ba -Force
```

Without `-Id`, every session whose model differs is a target. If you pass
`-Effort`, `reasoning_effort` is overwritten too. Changing only the effort, while
the model stays the same, is not a model change and is allowed.

Before writing, the script copies `state_5.sqlite` and its `-wal`/`-shm`
companions to `.bak-*` files. The update is one transaction and rolls back on
failure. A refused run never reaches the backup, so it leaves nothing behind.

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

Passing `-m` to `codex resume` runs into the same problem, because it also
changes the model of a session that already has history. Fork instead:

```powershell
codex exec fork 01a0f31c-18c5-7fe1-8889-8326ca8a28ba -m gpt-6.1-sol --skip-git-repo-check "<prompt>"
```

Keep the source session. A fork does not copy history, it references the source
rollout file, so deleting the source destroys the fork. `codex exec fork` needs a
prompt, so every headless fork spends one turn on the target model.

## Adding models to the `/model` picker

The picker does not read your provider. It renders a catalog compiled into
`codex.exe`:

```rust
// codex-rs/models-manager/src/lib.rs
serde_json::from_str(include_str!("../models.json"))
```

`codex debug models` prints that catalog. On 0.160.0 it holds 11 entries and 8 of
them are visible. The picker keeps only entries with `"visibility": "list"` and
`supported_in_api = true`, so a catalog entry is not the same thing as a picker
entry.

Nothing in `config.toml` adds one. `[profiles.*]` and `[model_providers.*]` never
appear in the picker (openai/codex#22160, closed as not planned), and neither does
the model list your provider serves from `/v1/models`. `-m`/`--model` and
`model = "..."` still accept any slug, they just do not list it.

There is a remote refresh path, cached in `.codex\models_cache.json` and gated on
a ChatGPT login or on the provider advertising an authoritative catalog plus
`features.api_key_model_discovery`. A third-party relay does not qualify:
`codex debug models -c features.api_key_model_discovery=true` returns
byte-identical output and writes no cache file.

`patch-model-catalog.ps1` rewrites the compiled-in catalog instead. The catalog
is one contiguous JSON literal in the image, and JSON ignores whitespace, so the
rebuilt catalog is padded back to its exact original byte length and every later
offset stays valid.

```powershell
# Print the current catalog. A dry run never writes and never backs up.
.\patch-model-catalog.ps1 -DryRun

# Trade entries the relay does not serve for entries it does.
.\patch-model-catalog.ps1 -Rename 'gpt-6-luna=cursor-5.5=Cursor 5.5','gpt-5.6-luna=gpt-5.5-pro=GPT-5.5 Pro'

# Real new entries, paid for by dropping ones you do not use.
.\patch-model-catalog.ps1 -Drop gpt-daybreak-blue-latest -Drop gpt-daybreak-red-latest -Add 'gpt-5.5|gpt-5.5-pro|GPT-5.5 Pro'
```

`-Rename`, `-Add`, `-Drop`, `-Show`, `-Hide` and `-Priority` are comma-separated
arrays, so write `-Drop a,b` rather than repeating `-Drop`. The catalog cannot
grow by more bytes than the literal already occupies, which is why `-Add` needs
room freed by `-Drop`; the script refuses the run if it does not fit. The rebuilt
catalog is re-parsed and length-checked before anything is written, and the
binary is copied to `.bak-model-catalog-<timestamp>` first.

Close Codex first. Windows keeps a running executable open for reading only, so
the write fails with `EBUSY` while any `codex.exe` is alive, including an open
TUI session. `codex update` replaces the binary and discards the patch. The patch
also invalidates the binary's Authenticode signature; Windows still loads it.

## Safety

`codex delete` removes a session permanently. The selector shows the selection
again and asks for confirmation unless `-Force` is given, so check the titles and
UUIDs before typing `DELETE`.

`fix-thread-model.ps1` writes to `state_5.sqlite` directly. It backs the file up
first and rolls back failed writes, but close Codex before running it and keep the
`.bak-*` files until you have checked the result. `-Force` does two things: it
overrides the refusal to rewrite sessions that already have turns, and it skips
the database handle check. Use it only for a case you have already reasoned
through.

## License

MIT License. See [LICENSE](LICENSE).
