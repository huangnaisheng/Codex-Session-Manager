[CmdletBinding()]
param(
    [string]$Query,
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

    if (-not $title) { $title = '(未找到用户标题)' }
    $title = (($title -replace '\s+', ' ').Trim())
    if ($title.Length -gt 120) { $title = $title.Substring(0, 120) + '...' }

    [pscustomobject]@{
        Id        = $sessionId
        Title     = $title
        LastWrite = $File.LastWriteTime
        File      = $File.FullName
    }
}

$sessionRoot = Join-Path $CodexHome 'sessions'
if (-not (Test-Path -LiteralPath $sessionRoot)) {
    throw "找不到会话目录: $sessionRoot"
}

$sessions = @(Get-ChildItem -LiteralPath $sessionRoot -Recurse -Filter '*.jsonl' -File |
    Sort-Object LastWriteTime -Descending |
    ForEach-Object { Get-SessionSummary $_ })

if ($Query) {
    $sessions = @($sessions | Where-Object { $_.Title -like "*$Query*" })
}

if (-not $sessions) {
    Write-Host '没有匹配的会话。'
    exit 0
}

for ($i = 0; $i -lt $sessions.Count; $i++) {
    $s = $sessions[$i]
    Write-Host (('[{0}] {1}  {2}' -f ($i + 1), $s.LastWrite.ToString('yyyy-MM-dd HH:mm'), $s.Title))
    Write-Host ('    UUID: {0}' -f $s.Id) -ForegroundColor DarkGray
}

if (-not $Delete) {
    Write-Host "`n只查看模式。按标题筛选示例: .\codex-session-cleaner.ps1 -Query '关键词'"
    exit 0
}

$selection = Read-Host "输入要删除的编号（可用逗号分隔，或输入 all）"
if ($selection -eq 'all') {
    $chosen = $sessions
} else {
    $indexes = $selection -split ',' | ForEach-Object { [int]$_.Trim() }
    $chosen = @($indexes | Where-Object { $_ -ge 1 -and $_ -le $sessions.Count } | ForEach-Object { $sessions[$_ - 1] })
}

if (-not $chosen) { throw '没有选择有效的会话编号。' }

Write-Host "`n将删除以下会话：" -ForegroundColor Yellow
$chosen | ForEach-Object { Write-Host ('- [{0}] {1}' -f $_.Id, $_.Title) }
if (-not $Force) {
    $answer = Read-Host '确认永久删除？输入 DELETE 继续'
    if ($answer -cne 'DELETE') {
        Write-Host '已取消。'
        exit 0
    }
}

foreach ($session in $chosen) {
    & codex delete $session.Id --force
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "删除失败: $($session.Id)"
    } else {
        Write-Host "已删除: $($session.Title)" -ForegroundColor Green
    }
}

