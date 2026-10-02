<#
.SYNOPSIS
Edits the model catalog that Codex ships inside codex.exe, so the /model picker
lists models the binary was never compiled with.

.DESCRIPTION
Codex does not read the /model list from your provider. The picker renders a
catalog that is compiled into the binary:

    codex-rs/models-manager/models.json   <- built from this file
    let bundled_models_response() = serde_json::from_str(include_str!("../models.json"))

include_str! embeds the file verbatim, so codex.exe contains the whole catalog as
one contiguous JSON literal. There is no config key that adds entries: profiles
and [model_providers.*] never appear in the picker (openai/codex#22160 was closed
as not planned). Rewriting that literal is the only way to change what /model
offers when you run against a third-party relay.

The literal is overwritten in place and kept at its exact original byte length,
because the compiled-in length constant and every following byte offset depend on
it. JSON ignores whitespace, so the rebuilt catalog is padded to fit.

Operations:
  -Drop   <slug>...              remove an entry
  -Rename <from=to>...           rename an entry, optionally renaming the label
  -Add    <clone|slug|label>...  clone an entry under a new slug
  -Show   <slug>...              make a hidden entry visible ("hide" -> "list")
  -Hide   <slug>...              hide a visible entry

.PARAMETER Target
Path to the codex.exe to patch. Defaults to the binary behind the `codex`
command installed by npm.

.PARAMETER Rename
"from=to" or "from=to=New Label".

.PARAMETER Add
"source|new-slug|New Label". The clone starts as an exact copy of the source
entry, so it inherits that model's instructions and metadata. Priority is
inherited too; use -Priority to change it.

.PARAMETER Priority
"slug=number". Applied after all other operations.

.PARAMETER Drop
Slug to remove.

.PARAMETER Show
Slug to expose in the picker. Hidden entries are still in the catalog, they just
carry "visibility": "hide".

.PARAMETER Hide
Slug to remove from the picker.

.PARAMETER DryRun
Print the resulting model list and stop. Never writes, never backs up. Running
with no operation flags lists the current catalog.

.PARAMETER NoBackup
Skip the .bak-model-catalog-<timestamp> copy of the binary.

.EXAMPLE
List what the binary currently ships:
  .\patch-model-catalog.ps1 -DryRun

.EXAMPLE
Swap the two entries a third-party relay does not serve for two it does:
  .\patch-model-catalog.ps1 -Rename 'gpt-6-luna=cursor-5.5=Cursor 5.5' -Rename 'gpt-5.6-luna=gpt-5.5-pro=GPT-5.5 Pro'

.EXAMPLE
Keep everything and append real entries instead:
  .\patch-model-catalog.ps1 -Drop gpt-daybreak-blue-latest -Drop gpt-daybreak-red-latest -Add 'gpt-5.5|cursor-5.5|Cursor 5.5'

.NOTES
Close Codex before running this. Windows keeps a running executable open for
reading only, so the rewrite fails with EBUSY while any codex.exe is alive,
including an open TUI session.

codex update replaces the binary and discards the patch. The catalog is covered
by the binary's Authenticode signature, so patching invalidates it; Windows still
loads the file. There is no way to grow the catalog by more bytes than the
existing literal occupies, which is why -Add needs room freed by -Drop.
#>
[CmdletBinding()]
param(
    [string]$Target,
    [string[]]$Rename = @(),
    [string[]]$Add = @(),
    [string[]]$Drop = @(),
    [string[]]$Show = @(),
    [string[]]$Hide = @(),
    [string[]]$Priority = @(),
    [switch]$DryRun,
    [switch]$NoBackup
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw 'node was not found on PATH; it is required to rewrite the catalog.'
}

if (-not $Target) {
    $candidates = Get-ChildItem -Path (Join-Path $env:APPDATA 'npm\node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\*\bin\codex.exe') -ErrorAction SilentlyContinue
    if (-not $candidates) {
        throw 'Could not find codex.exe under %APPDATA%\npm. Pass -Target explicitly.'
    }
    $Target = $candidates[0].FullName
}
if (-not (Test-Path -LiteralPath $Target)) {
    throw "Not found: $Target"
}
$Target = (Resolve-Path -LiteralPath $Target).Path

function Convert-Rename {
    param([string]$Spec)
    $parts = $Spec.Split('=')
    if ($parts.Count -lt 2 -or $parts.Count -gt 3 -or -not $parts[0] -or -not $parts[1]) {
        throw "Bad -Rename value '$Spec'. Expected 'from=to' or 'from=to=New Label'."
    }
    $entry = [ordered]@{ from = $parts[0]; to = $parts[1] }
    if ($parts.Count -eq 3) { $entry.display_name = $parts[2] }
    return $entry
}

function Convert-Add {
    param([string]$Spec)
    $parts = $Spec.Split('|')
    if ($parts.Count -lt 2 -or $parts.Count -gt 3 -or -not $parts[0] -or -not $parts[1]) {
        throw "Bad -Add value '$Spec'. Expected 'source|new-slug|New Label'."
    }
    $entry = [ordered]@{ clone = $parts[0]; slug = $parts[1] }
    if ($parts.Count -eq 3) { $entry.display_name = $parts[2] }
    return $entry
}

function Convert-Priority {
    param([string]$Spec)
    $parts = $Spec.Split('=')
    $value = 0
    if ($parts.Count -ne 2 -or -not [int]::TryParse($parts[1], [ref]$value)) {
        throw "Bad -Priority value '$Spec'. Expected 'slug=number'."
    }
    return [ordered]@{ slug = $parts[0]; priority = $value }
}

$recipe = [ordered]@{
    exe    = $Target
    drop   = @($Drop)
    rename = @($Rename | ForEach-Object { Convert-Rename $_ })
    add    = @($Add | ForEach-Object { Convert-Add $_ })
    show   = @($Show)
    hide   = @($Hide)
    priority = @($Priority | ForEach-Object { Convert-Priority $_ })
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$work = Join-Path ([IO.Path]::GetTempPath()) ("codex-model-catalog-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null

$jsPath = Join-Path $work 'patch.js'
$recipePath = Join-Path $work 'recipe.json'
$recipe['dryRun'] = $true
$recipe | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $recipePath -Encoding utf8

$script:nodeSource = @'
'use strict';
const fs = require('fs');
const cfg = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));

const buf = fs.readFileSync(cfg.exe);

// The catalog is the only JSON object in the image that looks like a model
// catalog. Scan every candidate rather than trusting the first byte match, and
// match the key rather than one particular whitespace layout, so an already
// patched binary (compact JSON) can be patched again.
const WS = [0x20, 0x09, 0x0a, 0x0d];
function locate(buf) {
  const needle = Buffer.from('"models"', 'utf8');
  for (let at = buf.indexOf(needle); at !== -1; at = buf.indexOf(needle, at + 1)) {
    let p = at + needle.length;
    while (p < buf.length && WS.indexOf(buf[p]) !== -1) p++;
    if (buf[p] !== 0x3a) continue;
    let start = at;
    while (start > 0 && buf[start] !== 0x7b) start--;
    let depth = 0, inStr = false, esc = false, end = -1;
    for (let i = start; i < buf.length; i++) {
      const c = buf[i];
      if (inStr) {
        if (esc) esc = false;
        else if (c === 0x5c) esc = true;
        else if (c === 0x22) inStr = false;
        continue;
      }
      if (c === 0x22) { inStr = true; continue; }
      if (c === 0x7b || c === 0x5b) depth++;
      else if (c === 0x7d || c === 0x5d) { depth--; if (depth === 0) { end = i; break; } }
    }
    if (end < 0) continue;
    let parsed;
    try { parsed = JSON.parse(buf.slice(start, end + 1).toString('utf8')); } catch (e) { continue; }
    if (!parsed || !Array.isArray(parsed.models)) continue;
    if (!parsed.models.length || typeof parsed.models[0].slug !== 'string') continue;
    return { start: start, end: end, parsed: parsed };
  }
  return null;
}

const found = locate(buf);
if (!found) {
  console.error('No model catalog found inside ' + cfg.exe + '. Is this a Codex binary?');
  process.exit(3);
}

const start = found.start;
const blobLen = found.end - found.start + 1;
const catalog = found.parsed;
const log = [];

const find = function (slug) { return catalog.models.find(function (m) { return m.slug === slug; }); };

for (const slug of cfg.drop) {
  const i = catalog.models.findIndex(function (m) { return m.slug === slug; });
  if (i < 0) { log.push('drop ' + slug + ': NOT FOUND'); continue; }
  catalog.models.splice(i, 1);
  log.push('drop ' + slug);
}

for (const r of cfg.rename) {
  const m = find(r.from);
  if (!m) { log.push('rename ' + r.from + ': NOT FOUND'); continue; }
  if (find(r.to) && find(r.to) !== m) { log.push('rename ' + r.from + ': target ' + r.to + ' already exists'); continue; }
  m.slug = r.to;
  if (r.display_name) m.display_name = r.display_name;
  log.push('rename ' + r.from + ' -> ' + r.to);
}

for (const a of cfg.add) {
  const src = find(a.clone);
  if (!src) { log.push('add ' + a.slug + ': clone source ' + a.clone + ' NOT FOUND'); continue; }
  if (find(a.slug)) { log.push('add ' + a.slug + ': already exists'); continue; }
  const copy = JSON.parse(JSON.stringify(src));
  copy.slug = a.slug;
  if (a.display_name) copy.display_name = a.display_name;
  catalog.models.push(copy);
  log.push('add ' + a.slug + ' (clone of ' + a.clone + ')');
}

for (const slug of cfg.show) {
  const m = find(slug);
  if (!m) { log.push('show ' + slug + ': NOT FOUND'); continue; }
  m.visibility = 'list';
  log.push('show ' + slug);
}

for (const slug of cfg.hide) {
  const m = find(slug);
  if (!m) { log.push('hide ' + slug + ': NOT FOUND'); continue; }
  m.visibility = 'hide';
  log.push('hide ' + slug);
}

for (const p of cfg.priority) {
  const m = find(p.slug);
  if (!m) { log.push('priority ' + p.slug + ': NOT FOUND'); continue; }
  m.priority = p.priority;
  log.push('priority ' + p.slug + ' = ' + p.priority);
}

const body = JSON.stringify(catalog);
const bodyLen = Buffer.byteLength(body, 'utf8');
if (bodyLen > blobLen) {
  console.error('REJECTED: the rebuilt catalog needs ' + bodyLen + ' bytes but the binary only has ' +
    blobLen + ' (' + (bodyLen - blobLen) + ' over). Free room with -Drop, or -Rename instead of -Add.');
  process.exit(4);
}

// Whitespace is not significant to JSON, so pad inside the object to hit the
// exact original length. Every byte offset after the literal stays put.
const out = body.slice(0, -1) + ' '.repeat(blobLen - bodyLen) + '}';
if (Buffer.byteLength(out, 'utf8') !== blobLen) {
  console.error('REJECTED: rebuilt catalog is not exactly ' + blobLen + ' bytes.');
  process.exit(4);
}
const verified = JSON.parse(out);
if (verified.models.length !== catalog.models.length) {
  console.error('REJECTED: rebuilt catalog did not survive a round trip.');
  process.exit(4);
}

const report = {
  binary: cfg.exe,
  catalogOffset: start,
  catalogBytes: blobLen,
  paddingBytes: blobLen - bodyLen,
  models: verified.models.map(function (m) { return m.slug + (m.visibility === 'list' ? '' : ' [hidden]'); }),
  changes: log
};

if (cfg.dryRun) {
  console.log(JSON.stringify(report, null, 2));
  process.exit(0);
}

buf.write(out, start, blobLen, 'utf8');
fs.writeFileSync(cfg.exe, buf);
console.log(JSON.stringify(report, null, 2));
'@

Set-Content -LiteralPath $jsPath -Value $script:nodeSource -Encoding utf8

Write-Output "Binary: $Target"
Write-Output ''

try {
    $preview = & node $jsPath $recipePath 2>&1
    $previewCode = $LASTEXITCODE
    if ($previewCode -ne 0) {
        $preview | Write-Output
        throw "Catalog edit refused (exit $previewCode). Nothing was written."
    }

    if ($DryRun) {
        $preview | Write-Output
        Write-Output ''
        Write-Output 'Dry run only. Nothing was written.'
        return
    }

    # Windows keeps a running image open for reading only, so the rewrite needs
    # exclusive access. Fail early with a usable message instead of a raw EBUSY.
    try {
        $probe = [IO.File]::Open($Target, 'Open', 'ReadWrite', 'None')
        $probe.Close()
    }
    catch {
        $holders = @(Get-Process -Name 'codex' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
        $hint = if ($holders.Count) { " Running codex processes: $($holders -join ', ')." } else { '' }
        throw "Cannot write $Target because another process holds it.$hint Close Codex, including any open TUI session, and run again."
    }

    if (-not $NoBackup) {
        $backup = "$Target.bak-model-catalog-$stamp"
        Copy-Item -LiteralPath $Target -Destination $backup -Force
        Write-Output "Backup: $backup"
    }

    $recipe['dryRun'] = $false
    $recipe | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $recipePath -Encoding utf8

    $result = & node $jsPath $recipePath 2>&1
    $code = $LASTEXITCODE
    $result | Write-Output
    if ($code -ne 0) {
        throw "Write failed (exit $code). Restore the binary from the backup if it was damaged."
    }
    Write-Output ''
    Write-Output 'Done. Run `codex debug models` to confirm; /model reads the same catalog.'
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
