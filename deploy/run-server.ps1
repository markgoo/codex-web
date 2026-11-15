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
  [string]$HostAddress = "127.0.0.1"
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

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
