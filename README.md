# Codex Session Manager

A small PowerShell utility for finding local Codex CLI sessions by title and cleaning them up through Codex's official delete command.

## Features

- Scans `.jsonl` session files under `%USERPROFILE%\.codex\sessions`.
- Extracts the first user message as a readable session title.
- Shows the title, last modified time, and session UUID together.
- Filters sessions by a title keyword.
- Provides an interactive terminal selector for deletion: arrow keys move, Space toggles, and Enter confirms the selection.
- Lists all selected sessions before deletion and requires typing `DELETE`.
- Runs `codex delete <UUID> --force` instead of modifying session files directly.

## Usage

```powershell
Set-Location 'D:\Study\codex\会话管理器'
.\codex-session-cleaner.ps1
.\codex-session-cleaner.ps1 -Query 'only reply ok'
```

The first command scans all sessions and immediately opens the visual selector. Use `-Query` when you want to narrow the list first. The old `-Delete` switch is still accepted for compatibility, but it is no longer needed.

In deletion mode, use the interactive selector:

- `Up` / `Down`: move the cursor
- `Space`: select or clear the highlighted session
- `A`: select all; `N`: clear all
- `Enter`: review the selected sessions
- `Esc` or `Q`: cancel

The script then asks for the uppercase confirmation word `DELETE`. When output is redirected or an interactive console is unavailable, it falls back to comma-separated numbers or `all`.

For trusted automation, skip the final confirmation prompt with `-Force`:

```powershell
.\codex-session-cleaner.ps1 -Query 'test session' -Force
```

Use a different Codex data directory:

```powershell
.\codex-session-cleaner.ps1 -CodexHome 'C:\AnotherUser\.codex'
```

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- Codex CLI installed and available as the `codex` command

## Safety

`codex delete` permanently removes a saved session. The selector always shows the selected sessions again and requires explicit confirmation unless `-Force` is supplied. Always verify the titles and UUIDs before confirming.

## License

MIT License. See [LICENSE](LICENSE).
