#!/usr/bin/env pwsh
# Starts codex-web bound to loopback only. Put nginx (deploy/nginx.conf) in
# front of it for LAN access plus login; never expose this port directly.
#
#   pwsh -File deploy/run-server.ps1                 # 127.0.0.1:8214
#   pwsh -File deploy/run-server.ps1 -Port 9000
#
# The server must run on the portable Node build: better-sqlite3 here is a
# native module compiled for Node 22 (ABI 127) and will not load under Node 26.

[CmdletBinding()]
param(
  [int]$Port = 8214,
  [string]$HostAddress = "127.0.0.1",
  # On this machine a codex.exe spawned by node cannot write the user's real
  # %USERPROFILE%\.codex ("os error 5" creating tmp\arg0-windows, then "failed to
  # initialize sqlite state runtime"). The app-server then exits, the desktop
  # shell pauses on a native dialog, and the page stays blank. A home inside the
  # repository works, so that is the default; -SharedHome goes back to the real
  # one (which is what the official desktop app keeps using).
  [switch]$SharedHome
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

# Low-integrity tokens (sandboxed agents, some remote shells) cannot write the
# user's Codex home, and the app-server then dies with "os error 5 (拒绝访问)"
# while creating ~/.codex\tmp\arg0-windows, which shows up as a blank page.
# Print it so the log says why instead of leaving a paused app.
function Get-IntegrityLabel {
  $label = "unknown"
  try {
    $line = whoami /groups 2>$null | Select-String -Pattern 'S-1-16-(\d+)' | Select-Object -First 1
    if ($line) {
      switch ($line.Matches[0].Groups[1].Value) {
        "4096" { $label = "Low" }
        "8192" { $label = "Medium" }
        "12288" { $label = "High" }
        "16384" { $label = "System" }
        default { $label = "S-1-16-$($line.Matches[0].Groups[1].Value)" }
      }
    }
  } catch {
    $label = "unknown"
  }
  return $label
}

$integrity = Get-IntegrityLabel
Write-Host "session   : integrity=$integrity  user=$env:USERNAME"
if ($integrity -eq "Low") {
  Write-Warning "Low-integrity session: the Codex app-server will be denied writes under $env:USERPROFILE\.codex and the UI will stay blank."
  Write-Warning "Start this from Explorer or a normal PowerShell window instead."
}

# --- codex home -------------------------------------------------------------
#
# The app-server keeps its state (threads, sqlite, tmp\arg0-windows) in
# $CODEX_HOME. On this host new codex.exe processes spawned by node are denied
# writes there, which kills the app-server before it can answer anything, so the
# browser only ever sees the loading logo. A home inside the repository is
# writable, so it becomes the default; the credential and config are copied over
# on every start (the login stays in sync with Codex, which keeps using the real
# home).
$codexHome = Join-Path $repo "scratch\codex-home"
if ($SharedHome) {
  Write-Host "codex home: $env:USERPROFILE\.codex (shared with Codex; known to pause on this host)"
} else {
  New-Item -ItemType Directory -Force -Path $codexHome | Out-Null
  $userHome = Join-Path $env:USERPROFILE ".codex"
  foreach ($name in @("auth.json", "config.toml", "installation_id")) {
    $source = Join-Path $userHome $name
    if (-not (Test-Path $source)) { continue }
    $target = Join-Path $codexHome $name
    # auth.json is refreshed every start (login changes); config.toml only when
    # missing, so local edits in the isolated home survive restarts.
    if ($name -eq "auth.json" -or -not (Test-Path $target)) {
      Copy-Item $source $target -Force
    }
  }
  $env:CODEX_HOME = $codexHome
  Write-Host "codex home: $codexHome (isolated: own chat history, credential copied from Codex)"
}

$node = Join-Path $repo "tools\node-v22.23.5-win-x64\node.exe"
if (-not (Test-Path $node)) {
  throw "portable node missing: $node (run deploy/setup-windows.ps1 first)"
}

# Prefer the build deploy/setup-windows.ps1 produces. src/server is only a
# fallback: on machines where the security software blocks writes under src/,
# that tree holds whatever an older build left behind ("build" there failed).
$entry = Join-Path $repo "scratch\server\main.js"
if (-not (Test-Path $entry)) {
  $entry = Join-Path $repo "src\server\main.js"
}
if (-not (Test-Path $entry)) {
  throw "server build missing: run deploy/setup-windows.ps1"
}

# The app package this project unpacks is the macOS build, so it ships no
# Windows Codex CLI and its bundled lookup finds nothing. The desktop app then
# cannot read the organization network settings the app-server provides: it
# pauses on a native dialog ("Organization settings could not be loaded") that
# no browser can click, and the page stays blank. Point it at the locally
# installed CLI instead.
function Find-CodexCli {
  if ($env:CODEX_CLI_PATH -and (Test-Path $env:CODEX_CLI_PATH)) {
    return (Resolve-Path $env:CODEX_CLI_PATH).Path
  }

  $npmRoot = Join-Path $env:APPDATA "npm\node_modules\@openai\codex"
  if (Test-Path $npmRoot) {
    $native = Get-ChildItem -Path $npmRoot -Recurse -Filter "codex.exe" -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -match "vendor[\\/].+[\\/]bin[\\/]codex\.exe$" } |
      Select-Object -First 1
    if ($native) { return $native.FullName }
  }

  $onPath = Get-Command "codex.exe" -ErrorAction SilentlyContinue
  if ($onPath) { return $onPath.Source }

  return $null
}

$codexCli = Find-CodexCli
if (-not $codexCli) {
  throw @"
No Codex CLI found (the bundled app package is the macOS build and has no Windows CLI).
  * install it:  npm install -g @openai/codex
  * or set CODEX_CLI_PATH to a codex.exe
Without it the app cannot read its organization settings and serves a blank page.
"@
}
$env:CODEX_CLI_PATH = $codexCli

# Some endpoint protection denies this Node binary writes to %TEMP%, where the
# upload endpoint creates its scratch directory. Keep that inside the repo.
$tmp = Join-Path $repo "scratch\tmp"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$env:TEMP = $tmp
$env:TMP = $tmp

Write-Host "codex-web: http://${HostAddress}:$Port  (loopback only)"
Write-Host "codex cli: $codexCli"
& $node $entry --host $HostAddress --port $Port
