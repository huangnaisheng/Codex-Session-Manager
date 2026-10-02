[CmdletBinding()]
param(
    [string]$Query,
    # Kept for compatibility with older commands; selection is now the default.
    [switch]$Delete,
    [switch]$Force,
    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex')
)

$ErrorActionPreference = 'Stop'

function Get-TextFromContent {
    param($Content)

    if ($null -eq $Content) { return $null }
    $parts = @($Content)
    $text = ($parts | ForEach-Object {
        if ($_ -is [string]) { $_ }
        elseif ($_.text) { $_.text }
    }) -join ''
    if ($text) {
        $text = [regex]::Replace($text, '(?s)<environment_context>.*?</environment_context>', '')
        $text = [regex]::Replace($text, '(?s)<[^>]+>\s*</[^>]+>', '')
        $text = $text.Trim()
        if ($text) { return $text }
    }
    return $null
}

function Get-SessionSummary {
    param([System.IO.FileInfo]$File)

    $sessionId = [IO.Path]::GetFileNameWithoutExtension($File.Name) -replace '^.*-([0-9a-f]{8}-[0-9a-f-]{27})$', '$1'
    $title = $null

    foreach ($line in Get-Content -LiteralPath $File.FullName) {
        try { $event = $line | ConvertFrom-Json } catch { continue }
        if (-not $sessionId -and $event.payload.session_id) { $sessionId = [string]$event.payload.session_id }
        if ($event.payload.session_id) { $sessionId = [string]$event.payload.session_id }

        $candidates = @(
            $event.payload,
            $event.payload.item,
            $event.payload.message
        )
        foreach ($candidate in $candidates) {
            if ($candidate -and $candidate.role -eq 'user') {
                $title = Get-TextFromContent $candidate.content
                if ($title) { break }
            }
        }
        if ($title) { break }
    }

    if (-not $title) { $title = '(No user title found)' }
    $title = (($title -replace '\s+', ' ').Trim())
    if ($title.Length -gt 120) { $title = $title.Substring(0, 120) + '...' }

    [pscustomobject]@{
        Id        = $sessionId
        Title     = $title
        LastWrite = $File.LastWriteTime
        File      = $File.FullName
    }
}

function Select-SessionsInteractive {
    param([object[]]$Items)

    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        $selection = Read-Host 'Enter numbers to delete (comma-separated), or all'
        if ($selection -eq 'all') { return @($Items) }
        $indexes = $selection -split ',' | ForEach-Object {
            $number = 0
            if ([int]::TryParse($_.Trim(), [ref]$number)) { $number }
        }
        return @($indexes | Where-Object { $_ -ge 1 -and $_ -le $Items.Count } | ForEach-Object { $Items[$_ - 1] })
    }

    $selected = New-Object 'System.Collections.Generic.HashSet[int]'
    $cursor = 0
    $top = 0
    $pageSize = [Math]::Max(5, [Console]::WindowHeight - 8)
    $originalCursorVisible = [Console]::CursorVisible
    [Console]::CursorVisible = $false

    try {
        while ($true) {
            $pageSize = [Math]::Max(5, [Console]::WindowHeight - 8)
            if ($cursor -lt $top) { $top = $cursor }
            if ($cursor -ge ($top + $pageSize)) { $top = $cursor - $pageSize + 1 }

            Clear-Host
            Write-Host 'Codex Session Manager - Select sessions to delete' -ForegroundColor Cyan
            Write-Host 'Up/Down move  Space select  A all  N none  Enter continue  Esc/Q cancel' -ForegroundColor DarkGray
            Write-Host ("Selected: {0}/{1}`n" -f $selected.Count, $Items.Count) -ForegroundColor Yellow

            $last = [Math]::Min($Items.Count - 1, $top + $pageSize - 1)
            for ($i = $top; $i -le $last; $i++) {
                $item = $Items[$i]
                $mark = if ($selected.Contains($i)) { '[x]' } else { '[ ]' }
                $prefix = if ($i -eq $cursor) { '>' } else { ' ' }
                $line = ('{0} {1} {2,3}. {3}  {4}' -f $prefix, $mark, ($i + 1), $item.LastWrite.ToString('yyyy-MM-dd HH:mm'), $item.Title)
                if ($i -eq $cursor) { Write-Host $line -ForegroundColor White -BackgroundColor DarkCyan }
                elseif ($selected.Contains($i)) { Write-Host $line -ForegroundColor Green }
                else { Write-Host $line }
            }

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow' { if ($cursor -gt 0) { $cursor-- } }
                'DownArrow' { if ($cursor -lt ($Items.Count - 1)) { $cursor++ } }
                'Spacebar' { if ($selected.Contains($cursor)) { [void]$selected.Remove($cursor) } else { [void]$selected.Add($cursor) } }
                'A' { for ($i = 0; $i -lt $Items.Count; $i++) { [void]$selected.Add($i) } }
                'N' { $selected.Clear() }
                'Escape' { return @() }
                'Q' { return @() }
                'Enter' {
                    if ($selected.Count -gt 0) {
                        return @($selected | Sort-Object | ForEach-Object { $Items[$_] })
                    }
                }
            }
        }
    }
    finally {
        [Console]::CursorVisible = $originalCursorVisible
        Clear-Host
    }
}

$sessionRoot = Join-Path $CodexHome 'sessions'
if (-not (Test-Path -LiteralPath $sessionRoot)) {
    throw "Session directory not found: $sessionRoot"
}

$sessions = @(Get-ChildItem -LiteralPath $sessionRoot -Recurse -Filter '*.jsonl' -File |
    Sort-Object LastWriteTime -Descending |
    ForEach-Object { Get-SessionSummary $_ })

if ($Query) {
    $sessions = @($sessions | Where-Object { $_.Title -like "*$Query*" })
}

if (-not $sessions) {
    Write-Host 'No matching sessions found.'
    exit 0
}

$chosen = @(Select-SessionsInteractive -Items $sessions)

if (-not $chosen) {
    Write-Host 'No sessions selected. Cancelled.' -ForegroundColor Yellow
    exit 0
}

Write-Host "`nThe following sessions will be deleted:" -ForegroundColor Yellow
$chosen | ForEach-Object { Write-Host ('- [{0}] {1}' -f $_.Id, $_.Title) }
if (-not $Force) {
    $answer = Read-Host 'Permanently delete these sessions? Type DELETE to continue'
    if ($answer -cne 'DELETE') {
        Write-Host 'Cancelled.'
        exit 0
    }
}

foreach ($session in $chosen) {
    & codex delete $session.Id --force
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Delete failed: $($session.Id)"
    } else {
        Write-Host "Deleted: $($session.Title)" -ForegroundColor Green
    }
}




