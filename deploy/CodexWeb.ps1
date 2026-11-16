#!/usr/bin/env pwsh
# One entry point for the whole stack: codex-web (:8214) + nginx (:8443).
#
#   pwsh -File deploy/CodexWeb.ps1 start     # start what is not running, in order
#   pwsh -File deploy/CodexWeb.ps1 stop
#   pwsh -File deploy/CodexWeb.ps1 status    # ports, HTTP answers, recent log lines
#   pwsh -File deploy/CodexWeb.ps1 open      # open the LAN UI in the default browser
#   pwsh -File deploy/CodexWeb.ps1 restart
#
# Double-click deploy\CodexWeb.cmd for the windowless version (start + open).
# Everything started here is detached and hidden; output goes to scratch\logs\.
#
# Order matters: nginx proxies to 127.0.0.1:8214, so the server must answer
# before nginx is useful.

[CmdletBinding()]
param(
  [ValidateSet("start", "stop", "status", "open", "restart")]
  [string]$Action = "status",
  [string]$Repo = (Split-Path -Parent $PSScriptRoot),
  [string]$HostAddress = "127.0.0.1",
  [int]$Port = 8214,
  [int]$TimeoutSeconds = 120,
  # Debug aid: keep a minimised console in the taskbar instead of no window.
  [switch]$Minimized
)

$ErrorActionPreference = "Stop"
$logDir = Join-Path $Repo "scratch\logs"
$serverLog = Join-Path $logDir "codex-web.log"
$nginxLog = Join-Path $logDir "codex-web-nginx.log"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

function Test-Listening([int]$port) {
  return $null -ne (netstat -ano | Select-String ":$port\s" | Select-String "LISTENING" | Select-Object -First 1)
}

function Get-PwshPath {
  $candidate = Join-Path $PSHOME "pwsh.exe"
  if (Test-Path $candidate) { return $candidate }
  $found = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
  if ($found) { return $found }
  throw "pwsh.exe not found (PowerShell 7 required)"
}

# Detached, own console (minimised), output appended to the log by a generated
# launcher.
#
# Hidden by default (no window at all). `-Minimized` keeps a console in the
# taskbar: useful when diagnosing whether a failure depends on having one.
function Start-Hidden([string]$label, [string]$scriptName, [string[]]$ExtraArgs = @()) {
  $launcher = Join-Path $logDir "$label.launcher.ps1"
  $log = Join-Path $logDir "$label.log"
  $target = Join-Path $Repo "deploy\$scriptName"
  $body = @"
`$ErrorActionPreference = 'Continue'
`$log = '$log'
"[{0}] starting $scriptName $($ExtraArgs -join ' ')" -f (Get-Date -Format s) | Out-File -Append -Encoding utf8 `$log
& '$target' $($ExtraArgs -join ' ') *>> `$log
"[{0}] $scriptName exited code=`$LASTEXITCODE" -f (Get-Date -Format s) | Out-File -Append -Encoding utf8 `$log
"@
  Set-Content -Path $launcher -Value $body -Encoding utf8
  $windowStyle = if ($Minimized) { "Minimized" } else { "Hidden" }
  Start-Process -FilePath (Get-PwshPath) `
    -ArgumentList @("-NoProfile", "-WindowStyle", $windowStyle, "-ExecutionPolicy", "Bypass", "-File", "`"$launcher`"") `
    -WindowStyle $windowStyle -WorkingDirectory $Repo | Out-Null
}

function Wait-Listening([int]$port, [int]$Seconds, [string]$what) {
  for ($i = 0; $i -lt ($Seconds * 4); $i++) {
    if (Test-Listening $port) { return $true }
    Start-Sleep -Milliseconds 250
  }
  Write-Warning "$what did not start listening on port $port within ${Seconds}s (see $logDir)"
  return $false
}

function Get-LanAddress {
  # Pick the address a phone would actually reach: the adapter that has a
  # default gateway. Virtual adapters (WSL/Hyper-V/Docker, usually 172.16/12)
  # have one too, so rank 192.168.* then 10.* above them.
  $candidates = @()
  try {
    $blocks = (ipconfig) -join "`n" -split "`r?`n(?=\S)"
    foreach ($block in $blocks) {
      if ($block -notmatch "Default Gateway[^:]*:\s*(\d+\.\d+\.\d+\.\d+)") { continue }
      foreach ($match in [regex]::Matches($block, "IPv4[^:]*:\s*(\d+\.\d+\.\d+\.\d+)")) {
        $candidates += $match.Groups[1].Value
      }
    }
  } catch {
    $candidates = @()
  }

  $candidates = $candidates |
    Where-Object { $_ -notlike "127.*" -and $_ -notlike "169.254.*" } |
    Select-Object -Unique

  $ranked = $candidates | Sort-Object -Property @{ Expression = {
        if ($_ -like "192.168.*") { 0 }
        elseif ($_ -like "10.*") { 1 }
        elseif ($_ -like "172.1[6-9].*" -or $_ -like "172.2*" -or $_ -like "172.3[01].*") { 3 }
        else { 2 }
      }
    }
  if ($ranked) { return @($ranked)[0] }

  # No gateway information available: last resort, first usable address.
  $any = (ipconfig | Select-String -Pattern "IPv4[^:]*:\s*(\d+\.\d+\.\d+\.\d+)" |
      ForEach-Object { $_.Matches[0].Groups[1].Value } |
      Where-Object { $_ -notlike "127.*" -and $_ -notlike "169.254.*" } |
      Select-Object -First 1)
  if ($any) { return $any }
  return "127.0.0.1"
}

function Get-HttpStatus([string]$url, [switch]$Tls) {
  $node = Join-Path $Repo "tools\node-v22.23.5-win-x64\node.exe"
  if (-not (Test-Path $node)) { return "unknown" }
  $script = if ($Tls) {
    "const https=require('node:https');const q=https.request({host:process.argv[1],port:process.argv[2],path:'/',rejectUnauthorized:false},r=>{console.log(r.statusCode);r.resume()});q.on('error',e=>console.log('ERR '+e.code));q.end();"
  } else {
    "const http=require('node:http');const q=http.request({host:process.argv[1],port:process.argv[2],path:'/'},r=>{console.log(r.statusCode);r.resume()});q.on('error',e=>console.log('ERR '+e.code));q.end();"
  }
  $uri = [uri]$url
  return (& $node -e $script $uri.Host $uri.Port 2>$null | Select-Object -First 1)
}

switch ($Action) {
  "start" {
    $started = @()
    $paused = $false

    if (Test-Listening $Port) {
      Write-Host "codex-web  : already listening on $HostAddress`:$Port"
    } else {
      Write-Host "codex-web  : starting (log: $serverLog)"
      Start-Hidden -label "codex-web" -scriptName "run-server.ps1" -ExtraArgs @("-Port", "$Port")
      if (-not (Wait-Listening $Port $TimeoutSeconds "codex-web")) { exit 1 }
      $started += "codex-web"

      # A listening port is not a working app: if the app-server cannot prepare
      # its Codex home, the desktop shell pauses behind a native dialog that a
      # browser can never answer, and every page stays blank. That happens when
      # the launcher itself runs in a restricted/sandboxed session, so say so
      # instead of reporting "ready".
      Start-Sleep -Seconds 10
      $early = Get-Content $serverLog -Tail 60 -ErrorAction SilentlyContinue
      if ($early -and ($early -match "Organization settings could not be loaded")) {
        Write-Warning "codex-web is up but PAUSED: 'Organization settings could not be loaded'."
        Write-Warning "The app-server could not prepare its Codex home (~/.codex/tmp)."
        Write-Warning "Start it from your own desktop session (double-click deploy\CodexWeb.cmd),"
        Write-Warning "not from a restricted shell/sandbox. See $serverLog."
        $paused = $true
      }
    }

    if (Test-Listening 8443) {
      Write-Host "nginx      : already listening on 8080/8443"
    } else {
      Write-Host "nginx      : starting (log: $nginxLog)"
      Start-Hidden -label "codex-web-nginx" -scriptName "nginx.ps1" -ExtraArgs @("start")
      if (-not (Wait-Listening 8443 60 "nginx")) { exit 1 }
      $started += "nginx"
    }

    $lan = Get-LanAddress
    Write-Host ""
    if ($paused) {
      Write-Host "NOT ready  : the server is listening but paused; pages will be blank."
    } else {
      Write-Host "ready      : https://${lan}:8443   (account: $(if (Test-Path (Join-Path $Repo 'deploy\htpasswd')) { (Get-Content (Join-Path $Repo 'deploy\htpasswd') | ForEach-Object { ($_ -split ':')[0] }) -join ', ' } else { 'none' }))"
    }
    Write-Host "local      : http://127.0.0.1:$Port"
    if ($started.Count -eq 0) { Write-Host "nothing was started; both were already up" }
  }

  "stop" {
    if (Test-Listening 8443 -or Test-Listening 8080) {
      Write-Host "nginx      : stopping"
      & (Join-Path $Repo "deploy\nginx.ps1") stop *> $null
      Start-Sleep -Milliseconds 800

      if (@(8080, 8443) | Where-Object { Test-Listening $_ }) {
        # `nginx -s stop` signals the master through a named event; if nginx was
        # started under a different privilege that is refused ("Access is
        # denied"), so fall back to the recorded master pid plus whatever still
        # holds the two ports (an orphaned worker keeps them bound).
        $pidFiles = Get-ChildItem (Join-Path $Repo "tools") -Directory -ErrorAction SilentlyContinue |
          Where-Object { $_.Name -like "nginx*" } |
          ForEach-Object { Join-Path $_.FullName "logs\nginx.pid" } |
          Where-Object { Test-Path $_ }
        foreach ($pidFile in $pidFiles) {
          $recorded = (Get-Content $pidFile -Raw -ErrorAction SilentlyContinue).Trim()
          if ($recorded -match "^\d+$") {
            try {
              Stop-Process -Id ([int]$recorded) -Force -ErrorAction Stop
              Write-Host "nginx      : stopped master pid $recorded"
            } catch {
              Write-Warning "nginx      : could not stop master pid ${recorded}: $($_.Exception.Message)"
            }
          }
          Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
        }
        foreach ($port in @(8080, 8443)) {
          $leftover = netstat -ano | Select-String ":$port\s" | Select-String "LISTENING" |
            ForEach-Object { ($_.Line -split "\s+")[-1] } | Sort-Object -Unique
          foreach ($processId in $leftover) {
            try {
              Stop-Process -Id ([int]$processId) -Force -ErrorAction Stop
              Write-Host "nginx      : stopped leftover pid $processId on port $port"
            } catch {
              Write-Warning "nginx      : port $port still held by pid ${processId}: $($_.Exception.Message)"
            }
          }
        }
      }
    } else {
      Write-Host "nginx      : not running"
    }

    if (Test-Listening $Port) {
      # Only the listener on our port, never "all node processes".
      $pids = netstat -ano | Select-String ":$Port\s" | Select-String "LISTENING" |
        ForEach-Object { ($_.Line -split "\s+")[-1] } | Sort-Object -Unique
      foreach ($processId in $pids) {
        try {
          Stop-Process -Id ([int]$processId) -Force -ErrorAction Stop
          Write-Host "codex-web  : stopped pid $processId"
        } catch {
          Write-Warning "codex-web  : could not stop pid ${processId}: $($_.Exception.Message)"
        }
      }
    } else {
      Write-Host "codex-web  : not running"
    }
  }

  "status" {
    $lan = Get-LanAddress
    $serverUp = Test-Listening $Port
    $nginxUp = Test-Listening 8443
    $serverLogTail = if (Test-Path $serverLog) { Get-Content $serverLog -Tail 60 -ErrorAction SilentlyContinue } else { @() }
    $pausedNow = ($serverLogTail -and ($serverLogTail -match "Organization settings could not be loaded"))
    Write-Host "codex-web  : $(if ($serverUp) { "listening on $HostAddress`:$Port" } else { 'not running' })$(if ($pausedNow) { '  [PAUSED - see log, start it from your desktop session]' })"
    if ($serverUp) { Write-Host "             http://127.0.0.1:$Port -> $(Get-HttpStatus "http://127.0.0.1:$Port")" }
    Write-Host "nginx      : $(if ($nginxUp) { 'listening on 8080/8443' } else { 'not running' })"
    if ($nginxUp) { Write-Host "             https://${lan}:8443 -> $(Get-HttpStatus "https://${lan}:8443" -Tls) (401 = waiting for login)" }
    foreach ($log in @($serverLog, $nginxLog)) {
      if (Test-Path $log) {
        Write-Host ""
        Write-Host "--- $(Split-Path -Leaf $log) (last 3) ---"
        Get-Content $log -Tail 3 | ForEach-Object { Write-Host "  $_" }
      }
    }
  }

  "open" {
    $lan = Get-LanAddress
    $url = if (Test-Listening 8443) { "https://${lan}:8443" } else { "http://127.0.0.1:$Port" }
    Write-Host "opening $url"
    Start-Process $url | Out-Null
  }

  "restart" {
    & $PSCommandPath stop
    Start-Sleep -Seconds 2
    & $PSCommandPath start
  }
}
