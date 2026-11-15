#!/usr/bin/env pwsh
# Manages the nginx front door for codex-web (Windows, unpacked in tools/).
#
#   pwsh -File deploy/nginx.ps1 status     # is it up, on which pid, which port
#   pwsh -File deploy/nginx.ps1 test       # config syntax check
#   pwsh -File deploy/nginx.ps1 start
#   pwsh -File deploy/nginx.ps1 reload     # after editing deploy/nginx.conf
#   pwsh -File deploy/nginx.ps1 stop
#
# nginx always runs with -p <its own directory>, because the config refers to
# mime.types, logs/error.log and logs/nginx.pid relative to its prefix.

[CmdletBinding()]
param(
  [ValidateSet("status", "test", "start", "reload", "stop")]
  [string]$Action = "status",
  [string]$Version = "1.30.6"
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$prefix = Join-Path $repo "tools\nginx-$Version"
$exe = Join-Path $prefix "nginx.exe"
$confPath = Join-Path $prefix "conf\nginx.conf"
$pidPath = Join-Path $prefix "logs\nginx.pid"

if (-not (Test-Path $exe)) {
  throw "nginx $Version not unpacked at $prefix (see deploy/README.md '拿 nginx')"
}

function Get-NginxPid {
  if (-not (Test-Path $pidPath)) { return $null }
  $value = (Get-Content $pidPath -Raw -ErrorAction SilentlyContinue).Trim()
  $parsed = 0
  if ([int]::TryParse($value, [ref]$parsed)) { return $parsed }
  return $null
}

function Get-ListenPort {
  if (-not (Test-Path $confPath)) { return $null }
  $match = Select-String -Path $confPath -Pattern '^\s*listen\s+(\d+)' | Select-Object -First 1
  if ($match) { return [int]$match.Matches[0].Groups[1].Value }
  return $null
}

function Get-ListenPorts {
  if (-not (Test-Path $confPath)) { return @() }
  Select-String -Path $confPath -Pattern '^\s*listen\s+(\d+)(\s+ssl)?' | ForEach-Object {
    $port = $_.Matches[0].Groups[1].Value
    if ($_.Matches[0].Groups[2].Success) { "$port(ssl)" } else { $port }
  }
}

function Invoke-Nginx([string[]]$Arguments) {
  & $exe -p "$prefix\" -c conf/nginx.conf @Arguments
  return $LASTEXITCODE
}

# deploy/nginx.conf keeps no absolute paths: @REPO@ is substituted here, so the
# same file works from any checkout location.
function Install-Conf {
  $template = Join-Path $PSScriptRoot "nginx.conf"
  if (-not (Test-Path $template)) { throw "missing $template" }
  $repoForNginx = $repo.Replace("\", "/")
  $rendered = (Get-Content $template -Raw).Replace("@REPO@", $repoForNginx)
  Set-Content -Path $confPath -Value $rendered -Encoding utf8
}

switch ($Action) {
  "status" {
    $nginxPid = Get-NginxPid
    $port = Get-ListenPort
    $alive = $false
    if ($nginxPid) {
      $alive = $null -ne (Get-Process -Id $nginxPid -ErrorAction SilentlyContinue)
    }
    $listening = $false
    if ($port) {
      $listening = $null -ne (netstat -ano | Select-String ":$port\s" | Select-String "LISTENING" | Select-Object -First 1)
    }
    Write-Host "prefix : $prefix"
    Write-Host "listen : $((Get-ListenPorts) -join ', ')"
    Write-Host "pid    : $(if ($nginxPid) { $nginxPid } else { 'none (no logs/nginx.pid)' })"
    Write-Host "master : $(if ($alive) { 'running' } else { 'not running' })"
    Write-Host "socket : $(if ($listening) { 'listening' } else { 'closed' })"
  }
  "test" {
    Install-Conf
    exit (Invoke-Nginx @("-t"))
  }
  "start" {
    Install-Conf
    $nginxPid = Get-NginxPid
    if ($nginxPid -and (Get-Process -Id $nginxPid -ErrorAction SilentlyContinue)) {
      throw "nginx is already running (pid $nginxPid); use 'reload' or 'stop' first"
    }
    if ($nginxPid) {
      # The pid file outlived its master (crash, kill, or a sandbox reaping the
      # process tree). nginx refuses to start with a stale pid file present.
      Write-Host "removing stale logs/nginx.pid (pid $nginxPid is gone)"
      Remove-Item $pidPath -Force -ErrorAction SilentlyContinue
    }
    # nginx keeps running after the launcher call returns, so do not wait on it.
    Start-Process -FilePath $exe -ArgumentList @("-p", "$prefix\", "-c", "conf/nginx.conf") -WindowStyle Hidden | Out-Null
    $port = Get-ListenPort
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
      Start-Sleep -Milliseconds 250
      if (netstat -ano | Select-String ":$port\s" | Select-String "LISTENING") {
        Write-Host "nginx listening on port $port"
        exit 0
      }
    }
    throw "nginx did not start listening on port $port (see $prefix\logs\error.log)"
  }
  "reload" {
    Install-Conf
    $code = Invoke-Nginx @("-t")
    if ($code -ne 0) { throw "config test failed; not reloading" }
    exit (Invoke-Nginx @("-s", "reload"))
  }
  "stop" {
    exit (Invoke-Nginx @("-s", "stop"))
  }
}
