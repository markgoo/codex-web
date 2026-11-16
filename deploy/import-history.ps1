#!/usr/bin/env pwsh
# Copies the chat history Codex already has into codex-web's isolated home, so
# the web UI can list those conversations again.
#
#   pwsh -File deploy/import-history.ps1            # rollouts only (~400 MB)
#   pwsh -File deploy/import-history.ps1 -Full      # + sqlite indexes (~3.2 GB)
#   pwsh -File deploy/import-history.ps1 -WhatIfOnly # show what would be copied
#
# Stop codex-web first (CodexWeb Stop) so the import is not racing the server;
# the desktop app can stay open (its session logs are append-only).
#
# This is a snapshot, not a sync: afterwards the web home and %USERPROFILE%\.codex
# keep separate histories. Nothing here writes to the source home.

[CmdletBinding()]
param(
  [switch]$Full,
  [switch]$WhatIfOnly,
  [string]$SourceHome = (Join-Path $env:USERPROFILE ".codex"),
  [string]$TargetHome = (Join-Path (Split-Path -Parent $PSScriptRoot) "scratch\codex-home")
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $SourceHome)) { throw "source home not found: $SourceHome" }
if (-not (Test-Path $TargetHome)) { throw "target home not found: $TargetHome (start codex-web once first)" }

# Rollout transcripts: this is what the thread list is built from.
$items = @(
  @{ Path = "sessions"; Directory = $true },
  @{ Path = "archived_sessions"; Directory = $true },
  @{ Path = "session_index.jsonl"; Directory = $false }
)

# The app-server's own indexes; large, and only useful as a speed-up because it
# can rebuild from the rollouts. Copy them only when nothing is writing.
if ($Full) {
  $items += @(
    @{ Path = "state_5.sqlite"; Directory = $false },
    @{ Path = "state_5.sqlite-wal"; Directory = $false },
    @{ Path = "thread_history_1.sqlite"; Directory = $false },
    @{ Path = "thread_history_1.sqlite-wal"; Directory = $false }
  )
}

function Get-SizeMb([string]$path) {
  if (-not (Test-Path $path)) { return 0 }
  $item = Get-Item $path
  if ($item.PSIsContainer) {
    return ((Get-ChildItem $path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB)
  }
  return ($item.Length / 1MB)
}

$totalMb = 0
foreach ($item in $items) {
  $from = Join-Path $SourceHome $item.Path
  if (-not (Test-Path $from)) {
    Write-Host ("skip  {0,-28} (not present)" -f $item.Path)
    continue
  }
  $sizeMb = Get-SizeMb $from
  $totalMb += $sizeMb
  Write-Host ("{0,-6}{1,-28} {2,9:N1} MB" -f $(if ($WhatIfOnly) { "would" } else { "copy" }), $item.Path, $sizeMb)
  if ($WhatIfOnly) { continue }

  $to = Join-Path $TargetHome $item.Path
  if ($item.Directory) {
    New-Item -ItemType Directory -Force -Path $to | Out-Null
    # /E = subdirs incl. empty, /XO = don't overwrite newer files already there.
    $robocopy = Start-Process -FilePath "$env:SystemRoot\System32\robocopy.exe" `
      -ArgumentList @("`"$from`"", "`"$to`"", "/E", "/XO", "/NFL", "/NDL", "/NJH", "/NJS", "/NP", "/R:1", "/W:1") `
      -PassThru -Wait -WindowStyle Hidden
    # robocopy: 0-7 are success codes, >=8 is a real failure.
    if ($robocopy.ExitCode -ge 8) { throw "robocopy failed for $($item.Path) (exit $($robocopy.ExitCode))" }
  } else {
    Copy-Item $from $to -Force
  }
}

# The thread list itself lives in state_5.sqlite; the rollouts above only carry
# the bodies, which is why a rollouts-only import shows just the pinned chats.
# VACUUM INTO keeps the snapshot consistent even while Codex writes.
$node = Join-Path (Split-Path -Parent $PSScriptRoot) "tools\node-v22.23.5-win-x64\node.exe"
$vacuum = Join-Path $PSScriptRoot "vacuum-copy.mjs"
$indexSource = Join-Path $SourceHome "state_5.sqlite"
$indexTarget = Join-Path $TargetHome "state_5.sqlite"
if ((Test-Path $node) -and (Test-Path $indexSource)) {
  if ($WhatIfOnly) {
    Write-Host ("would  {0,-28} {1,9:N1} MB (thread index)" -f "state_5.sqlite", (Get-SizeMb $indexSource))
  } else {
    & $node $vacuum $indexSource $indexTarget
    if ($LASTEXITCODE -ne 0) {
      throw "could not snapshot the thread index - stop codex-web (CodexWeb Stop) and run again"
    }
    # The index stores absolute rollout paths; without rewriting them the app
    # resumes a chat by opening the original file, which fails with os error 5.
    & $node (Join-Path $PSScriptRoot "relocate-threads.mjs") $indexTarget $SourceHome $TargetHome
    if ($LASTEXITCODE -ne 0) { throw "could not rewrite the imported rollout paths" }
  }
} else {
  Write-Host "skip  state_5.sqlite              (portable node or index missing)"
}

Write-Host ""
if ($WhatIfOnly) {
  Write-Host ("dry run: {0:N1} MB would be copied from {1} to {2}" -f $totalMb, $SourceHome, $TargetHome)
} else {
  Write-Host ("copied ~{0:N1} MB into {1}" -f $totalMb, $TargetHome)
  Write-Host "restart codex-web (CodexWeb Start) and the old conversations should be listed again."
}
