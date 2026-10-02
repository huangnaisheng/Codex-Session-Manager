<#
.SYNOPSIS
    Bulk-edit the model bound to saved Codex sessions (threads.model).

.DESCRIPTION
    Codex records the model each session used in state_5.sqlite, table threads,
    column model. codex resume reads that value instead of the global model in
    config.toml, so changing the default leaves old sessions on the old model.
    This script rewrites the stored value.

    It refuses to change the model of a session that already has turns. Such a
    session replays stored history that only the model that produced it can
    resolve, so switching makes the provider answer invalid_request and the
    session stops working. Editing the database again does not repair it. Fork
    the session instead and keep the source. MODEL-BINDING.md has the
    measurements. -Force overrides the refusal.

    Empty sessions accept any model. Changing only -Effort while the model stays
    the same is also allowed.

    The app-server daemon caches thread metadata in memory and keeps
    state_5.sqlite open, so it has to be closed first. The script checks by trying
    to open the database files with FileShare.None, and refuses to run while any
    of them is held. It does not check process names:
    codex-windows-sandbox-service.exe starts with Windows, survives signing out,
    and never touches thread metadata.

    state_5.sqlite is backed up before anything is modified.

.PARAMETER Model
    Target model name, for example gpt-6.1-sol

.PARAMETER Effort
    Optional. Also set the reasoning effort: low / medium / high / minimal

.PARAMETER Id
    Optional. Restrict the change to these session ids. Without it, every session
    whose model differs from the target is rewritten.

.PARAMETER DryRun
    List the sessions that would change without writing anything.

.PARAMETER Force
    Skip the database handle probe, and rewrite sessions that already have turns
    despite the refusal above. Both are dangerous.

.EXAMPLE
    .\fix-thread-model.ps1 -Model gpt-6.1-sol -DryRun
    .\fix-thread-model.ps1 -Model gpt-6.1-sol -Effort high
    .\fix-thread-model.ps1 -Model gpt-6.1-sol -Id 01a0f31c-18c5-7fe1-8889-8326ca8a28ba

.EXAMPLE
    # Moving a session that already has turns, without touching the database.
    codex exec fork 01a0f31c-18c5-7fe1-8889-8326ca8a28ba -m gpt-6.1-sol --skip-git-repo-check "<prompt>"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Model,
    [ValidateSet('low', 'medium', 'high', 'minimal')][string]$Effort,
    [string[]]$Id,
    [switch]$DryRun,
    [switch]$Force,
    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex')
)

$ErrorActionPreference = 'Stop'

# ---------- 1. Locate the database ----------
$dbPath = Join-Path $CodexHome 'state_5.sqlite'
if (-not (Test-Path -LiteralPath $dbPath)) {
    $cand = Get-ChildItem -LiteralPath $CodexHome -Filter 'state_*.sqlite' -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
    if (-not $cand) { throw "No state_*.sqlite found, check -CodexHome: $CodexHome" }
    $dbPath = $cand.FullName
}
Write-Host "Database: $dbPath" -ForegroundColor Cyan

# ---------- 2. Occupancy probe ----------
# The signal is the file handle, not the process name:
# codex-windows-sandbox-service runs from boot but never touches thread metadata,
# while the app-server daemon keeps state_*.sqlite open even with no window shown.
$holders = @()
foreach ($suffix in @('', '-wal', '-shm')) {
    $f = "$dbPath$suffix"
    if (-not (Test-Path -LiteralPath $f)) { continue }
    try {
        $fs = [IO.File]::Open($f, 'Open', 'Read', 'None')
        $fs.Close()
    } catch {
        $holders += [IO.Path]::GetFileName($f)
    }
}

if ($holders -and -not $Force) {
    Write-Host "`nThe database is still in use, refusing to write (a daemon would overwrite it):" -ForegroundColor Red
    $holders | ForEach-Object { Write-Host "  $_" }
    Write-Host "`nCodex-related processes still running:" -ForegroundColor Yellow
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -match '^codex' } |
        ForEach-Object { Write-Host ("  PID {0,-7} {1}" -f $_.Id, $_.ProcessName) }
    Write-Host "`nSign out, or end the app-server daemon, then run again. The sandbox service can stay." -ForegroundColor Yellow
    Write-Host "Or override a single session on resume: codex resume <session-id> -m $Model" -ForegroundColor Yellow
    # throw, not exit: `exit` tears down the whole host, so a caller that invoked
    # this script would die with it and lose its own buffered output.
    throw 'state_5.sqlite is in use; nothing was written.'
}
if ($holders) {
    Write-Host "Warning : -Force skipped the probe, the database is still in use" -ForegroundColor Yellow
} else {
    Write-Host "Handles : database handles free, safe to write" -ForegroundColor DarkGray
}

# ---------- 3. Backup ----------
# The backup happens inside the node step, after the safety guard and before the
# write, so a refused or previewed run leaves no .bak files behind.

# ---------- 4. Generate the node script ----------
$js = @'
const { DatabaseSync } = require('node:sqlite');
const fs = require('fs');
const cfg = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));

let db = new DatabaseSync(cfg.dbPath);
db.exec('PRAGMA busy_timeout=10000');

const all = db.prepare(
  'SELECT id, model, reasoning_effort, archived, cwd, tokens_used, first_user_message, substr(coalesce(title, first_user_message, \'\'), 1, 46) t FROM threads ORDER BY updated_at_ms DESC'
).all();

const ids = (cfg.ids || []).filter(Boolean).map(s => String(s).toLowerCase());
const want = ids.length ? new Set(ids) : null;
const targets = all.filter(r =>
  want ? want.has(String(r.id).toLowerCase()) : r.model !== cfg.model
);

// A session that already has turns replays its stored history on resume. That
// history carries reasoning items whose payload the projection dropped, so it is
// only resolvable by the model that produced it. Rewriting the model makes the
// provider reject the replay. See MODEL-BINDING.md.
const hasHistory = r =>
  Number(r.tokens_used) > 0 || String(r.first_user_message || '').trim() !== '';
const unsafe = targets.filter(r => hasHistory(r) && String(r.model) !== cfg.model);

console.log('');
console.log(all.length + ' sessions total, ' + targets.length + ' to change:');
console.log('-'.repeat(76));
for (const r of targets) {
  const eff = cfg.effort ? r.reasoning_effort + ' -> ' + cfg.effort : r.reasoning_effort;
  const tag = unsafe.includes(r) ? '   [has turns, model would change]' : '';
  console.log('  ' + r.id);
  console.log('    ' + String(r.model).padEnd(14) + ' -> ' + cfg.model.padEnd(14) + '   effort: ' + eff + tag);
  console.log('    ' + JSON.stringify(r.t));
}
if (want) {
  const missing = [...want].filter(x => !all.some(r => String(r.id).toLowerCase() === x));
  if (missing.length) console.log('\nIds not found: ' + missing.join(', '));
}

if (!targets.length) { console.log('\nNothing to change.'); db.close(); process.exit(0); }

// A preview never writes, so it previews everything. The refusal below is for
// real runs only.
if (cfg.dryRun) {
  if (unsafe.length) {
    console.log('');
    console.log('[DRY RUN] ' + unsafe.length + ' of these have turns, so a real run would');
    console.log('refuse them without -Force. Fork those instead:');
    console.log('  codex exec fork <id> -m ' + cfg.model + ' --skip-git-repo-check "<prompt>"');
  }
  console.log('\n[DRY RUN] Nothing written.');
  db.close();
  process.exit(0);
}

if (unsafe.length && !cfg.force) {
  console.log('');
  console.log('Refusing to rewrite ' + unsafe.length + ' session(s) that already have turns.');
  console.log('');
  console.log('Those sessions replay history produced on their current model. Changing the');
  console.log('stored model makes the provider reject that history with invalid_request, and');
  console.log('the session stops working. Editing threads.model does not repair the history,');
  console.log('so it cannot be undone by editing again.');
  console.log('');
  console.log('To carry a conversation to another model, fork it and keep the source:');
  console.log('');
  for (const r of unsafe) {
    console.log('  codex exec fork ' + r.id + ' -m ' + cfg.model + ' --skip-git-repo-check "<prompt>"');
  }
  console.log('');
  console.log('Empty sessions, and effort-only changes on an unchanged model, are unaffected.');
  console.log('See MODEL-BINDING.md. Pass -Force to write anyway.');
  db.close();
  process.exit(2);
}

if (unsafe.length) {
  console.log('');
  console.log('Warning: -Force is rewriting ' + unsafe.length + ' session(s) that already have turns.');
  console.log('Resuming those on ' + cfg.model + ' is expected to fail with invalid_request.');
}

// The write is now certain, so back up first. The read handle is closed so the
// copy cannot catch a half-written database. The stamp is second-resolution, so
// a second run inside the same second would reuse the file names and splice a
// main database and a WAL from different moments together; step past any
// existing name instead.
db.close();
const pad = n => String(n).padStart(2, '0');
const now = new Date();
const base = '' + now.getFullYear() + pad(now.getMonth() + 1) + pad(now.getDate()) +
             '-' + pad(now.getHours()) + pad(now.getMinutes()) + pad(now.getSeconds());
let stamp = base;
for (let i = 1; fs.existsSync(cfg.dbPath + '.bak-' + stamp); i++) stamp = base + '-' + (i + 1);
for (const suffix of ['', '-wal', '-shm']) {
  const src = cfg.dbPath + suffix;
  if (fs.existsSync(src)) {
    const dst = cfg.dbPath + '.bak-' + stamp + suffix;
    fs.copyFileSync(src, dst);
    console.log('Backup  : ' + dst.split(/[\\/]/).pop());
  }
}
console.log('');
db = new DatabaseSync(cfg.dbPath);
db.exec('PRAGMA busy_timeout=10000');

const updModel = db.prepare('UPDATE threads SET model = ? WHERE id = ?');
const updEffort = db.prepare('UPDATE threads SET reasoning_effort = ? WHERE id = ?');

let n = 0;
db.exec('BEGIN');
try {
  for (const r of targets) {
    updModel.run(cfg.model, r.id);
    if (cfg.effort) updEffort.run(cfg.effort, r.id);
    n++;
  }
  db.exec('COMMIT');
} catch (e) {
  db.exec('ROLLBACK');
  console.log('\nWrite failed and was rolled back: ' + e.message);
  db.close();
  process.exit(1);
}

console.log('\nUpdated ' + n + ' sessions.');
const after = db.prepare('SELECT model, COUNT(*) c FROM threads GROUP BY model ORDER BY c DESC').all();
console.log('Model distribution now:');
for (const r of after) console.log('  ' + String(r.c).padStart(3) + ' sessions  ' + r.model);
db.close();
'@

$jsPath = Join-Path $env:TEMP "codex-fix-model-$PID.js"
$cfgPath = Join-Path $env:TEMP "codex-fix-model-$PID.json"
Set-Content -LiteralPath $jsPath -Value $js -Encoding UTF8

@{
    dbPath  = $dbPath
    model   = $Model
    effort  = $Effort
    ids     = @($Id | Where-Object { $_ -and "$_".Trim() })
    dryRun  = [bool]$DryRun
    force   = [bool]$Force
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $cfgPath -Encoding UTF8

try {
    & node $jsPath $cfgPath
    $code = $LASTEXITCODE
} finally {
    Remove-Item -LiteralPath $jsPath, $cfgPath -Force -ErrorAction SilentlyContinue
}

if ($code -eq 2) { throw 'Refused: sessions that already have turns must be forked, not rewritten. See MODEL-BINDING.md.' }
if ($code -ne 0) { throw "node exited with code $code" }
if (-not $DryRun) {
    Write-Host "`nDone. Reopen Codex and these sessions will resume on $Model." -ForegroundColor Green
}
