#!/usr/bin/env pwsh
# Native Windows port of scripts/prepare + scripts/prepare_asar + the builds.
#
# The upstream scripts are bash and unpack the *macOS* Codex Desktop package.
# The bundle's JavaScript is platform neutral (that is how the Linux path works
# too); only packaged native modules differ, and prepare_asar already drops the
# one that matters (better-sqlite3, taken from the repo's own node_modules).
#
#   pwsh -File deploy/setup-windows.ps1                 # full build
#   pwsh -File deploy/setup-windows.ps1 -SkipInstall    # reuse node_modules
#   pwsh -File deploy/setup-windows.ps1 -SkipDownload   # reuse the cached zip
#   pwsh -File deploy/setup-windows.ps1 -SkipPatch      # reuse an already-patched asar
#
# Afterwards: node src/server/main.js --host 127.0.0.1 --port 8214

[CmdletBinding()]
param(
  [string]$AppVersion = "26.1007.30912",
  # better-sqlite3@12.9.0 ships prebuilt binaries for Node 20-25 only, and the
  # machine's Node 26 has none (and no C++ toolchain to compile one). So this
  # project gets its own portable Node, dropped in tools/ and never installed.
  [string]$NodeVersion = "22.23.5",
  [string]$NodeSha256 = "4a191082e9706866830379d577d2cc8a50c776fcd9436a8d061b063ed0d9a0e3",
  [switch]$SkipInstall,
  [switch]$SkipDownload,
  [switch]$SkipPatch
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

function Step($message) {
  Write-Host ""
  Write-Host "==> $message" -ForegroundColor Cyan
}

function Fail($message) {
  Write-Host "FAILED: $message" -ForegroundColor Red
  exit 1
}

# Defender/indexer can hold a freshly written file for a moment, which npm
# surfaces as EPERM on package-lock.json. Transient, so retry.
function Invoke-WithRetry {
  param(
    [scriptblock]$Action,
    [string]$What,
    [int]$Attempts = 3,
    [int]$DelayMs = 2000
  )
  for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    & $Action
    if ($LASTEXITCODE -eq 0) { return }
    if ($attempt -eq $Attempts) { Fail "$What failed after $Attempts attempts" }
    Write-Host "  $What failed (attempt $attempt), retrying..." -ForegroundColor Yellow
    Start-Sleep -Milliseconds $DelayMs
  }
}

# --- preflight -----------------------------------------------------------

Step "preflight"

foreach ($tool in @("git")) {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { Fail "$tool is not on PATH" }
}

# GNU patch / unzip ship with Git for Windows.
$gitUsrBin = "C:\Program Files\Git\usr\bin"
if (-not (Test-Path (Join-Path $gitUsrBin "patch.exe"))) {
  Fail "GNU patch not found at $gitUsrBin (install Git for Windows)"
}
$env:PATH = "$gitUsrBin;$env:PATH"

# --- portable node -------------------------------------------------------

$nodeDir = Join-Path $repo "tools\node-v$NodeVersion-win-x64"
$nodeExe = Join-Path $nodeDir "node.exe"
$npmCmd = Join-Path $nodeDir "npm.cmd"

if (-not (Test-Path $nodeExe)) {
  Step "fetch portable Node $NodeVersion into tools/"
  $zipName = "node-v$NodeVersion-win-x64.zip"
  $zipPath = Join-Path $repo "tools\$zipName"
  New-Item -ItemType Directory -Force -Path (Join-Path $repo "tools") | Out-Null

  if (-not (Test-Path $zipPath)) {
    curl.exe -L --fail --retry 3 -o $zipPath "https://nodejs.org/dist/v$NodeVersion/$zipName"
    if ($LASTEXITCODE -ne 0) { Fail "node download failed" }
  }

  # The hash can briefly fail right after curl exits: Defender and the indexer
  # hold the fresh file open. Retry instead of failing the build.
  $actual = ""
  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    try {
      $actual = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
      break
    } catch {
      Start-Sleep -Milliseconds 500
    }
  }
  if ($actual -eq "") { Fail "could not read $zipPath (still locked)" }
  if ($actual -ne $NodeSha256.ToLowerInvariant()) {
    Remove-Item $zipPath -Force
    Fail "node zip checksum mismatch (got $actual)"
  }

  # Windows' bundled bsdtar handles .zip; explicitly avoid the MSYS tar that Git
  # puts on PATH (it reads "C:\..." as a remote host).
  $bsdtar = Join-Path $env:SystemRoot "System32\tar.exe"
  & $bsdtar -xf $zipPath -C (Join-Path $repo "tools")
  if ($LASTEXITCODE -ne 0) { Fail "extracting node failed" }
  if (-not (Test-Path $nodeExe)) { Fail "unexpected node layout in zip" }
}

# Everything below runs on the portable Node, never on the system one.
$env:PATH = "$nodeDir;$env:PATH"
$nodeAbi = (& $nodeExe -p "process.versions.modules")
Write-Host "node $(& $nodeExe -p "process.version") (ABI $nodeAbi), npm $(& $npmCmd --version)"

# node_modules built by a different Node cannot be reused (native ABI).
$abiMarker = Join-Path $repo "node_modules\.dsh-node-abi"
if ((Test-Path (Join-Path $repo "node_modules")) -and -not $SkipInstall) {
  $recorded = if (Test-Path $abiMarker) { (Get-Content $abiMarker -Raw).Trim() } else { "" }
  if ($recorded -ne $nodeAbi) {
    Step "discard node_modules built for a different Node ABI ($recorded -> $nodeAbi)"
    Remove-Item -Recurse -Force (Join-Path $repo "node_modules")
  }
}

# --- dependencies --------------------------------------------------------

if (-not $SkipInstall) {
  Step "npm install (scripts skipped, dev deps omitted)"
  # --ignore-scripts: package.json's own "prepare" runs a bash script.
  # --omit=dev: electron is only needed for launch:unpacked.
  # --no-package-lock: Huorong (火绒) protects package.json / package-lock.json
  #   by name and denies npm's writes to them (EPERM). Without this flag npm
  #   cannot install at all here. Add the project folder to 火绒's trusted zone
  #   if you want the lock file maintained.
  # --cache: the shared %LOCALAPPDATA%\npm-cache is also write-denied in this
  #   setup, so keep the cache inside the repo (scratch/ is gitignored).
  Invoke-WithRetry -What "npm install" -Action {
    & $npmCmd install --ignore-scripts --omit=dev --no-package-lock --no-audit --no-fund --cache scratch/npm-cache
  }

  Step "rebuild better-sqlite3 (its install script was skipped above)"
  & $npmCmd rebuild better-sqlite3 --cache scratch/npm-cache --no-audit --no-fund
  if ($LASTEXITCODE -ne 0) {
    Fail @"
better-sqlite3 could not build for Node $NodeVersion.
  * If prebuild-install found no binary, try another -NodeVersion (20/22/24).
  * If it fell through to node-gyp, install Visual Studio Build Tools with the
    "Desktop development with C++" workload plus Python 3, then retry.
"@
  }

  Set-Content -Path $abiMarker -Value $nodeAbi -NoNewline
}

$bin = Join-Path $repo "node_modules\.bin"
foreach ($exe in @("asar.cmd", "prettier.cmd", "sharp.cmd")) {
  if (-not (Test-Path (Join-Path $bin $exe))) {
    Fail "missing $exe in node_modules/.bin - run without -SkipInstall"
  }
}

# --- download + extract --------------------------------------------------

$zipPath = Join-Path $repo "scratch\downloads\ChatGPT-$AppVersion.zip"

if (-not $SkipDownload) {
  Step "download Codex Desktop $AppVersion"
  New-Item -ItemType Directory -Force -Path (Split-Path $zipPath) | Out-Null
  if (-not (Test-Path $zipPath)) {
    $url =
      "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-darwin-arm64-$AppVersion.zip"
    Write-Host $url
    curl.exe -L --fail --retry 3 -o $zipPath $url
    if ($LASTEXITCODE -ne 0) { Fail "download failed" }
  } else {
    Write-Host "cached: $zipPath"
  }
}
if (-not (Test-Path $zipPath)) { Fail "missing $zipPath" }
Write-Host ("zip size: {0:N1} MB" -f ((Get-Item $zipPath).Length / 1MB))

$asarPath = "scratch/ChatGPT.app/Contents/Resources/app.asar"

if (-not $SkipPatch) {
  Step "extract app.asar from the package"
  New-Item -ItemType Directory -Force -Path "scratch" | Out-Null
  # bsdtar (Windows) rather than MSYS unzip: the latter silently extracts only
  # the directory entry for "app.asar.unpacked/*", and the asar then fails to
  # read its unpacked native modules.
  $bsdtar = Join-Path $env:SystemRoot "System32\tar.exe"
  & $bsdtar -xf $zipPath -C "scratch/" `
    "ChatGPT.app/Contents/Resources/app.asar" `
    "ChatGPT.app/Contents/Resources/app.asar.unpacked"
  if ($LASTEXITCODE -ne 0) { Fail "extracting the app package failed" }

  Step "asar extract -> scratch/asar"
  if (Test-Path "scratch\asar") { Remove-Item -Recurse -Force "scratch\asar" }
  & (Join-Path $bin "asar.cmd") extract $asarPath "scratch/asar"
  if ($LASTEXITCODE -ne 0) { Fail "asar extract failed" }

  Step "copy browser assets"
  Copy-Item -Path "assets\*" -Destination "scratch\asar\webview\" -Recurse -Force

  Step "generate PWA icon"
  $pwaSource = "scratch/asar/webview/assets/app-f483cb0295ed.png"
  $pwaTarget = "scratch/asar/webview/assets/pwa-icon-512.png"
  if (Test-Path $pwaSource) {
    & (Join-Path $bin "sharp.cmd") -i $pwaSource -o $pwaTarget -f png resize 384 384 --fit inside -- flatten white -- extend 64 64 64 64 --background white -- removeAlpha
    if ($LASTEXITCODE -ne 0) {
      Write-Host "warning: PWA icon generation failed (non-fatal)" -ForegroundColor Yellow
    }
  } else {
    Write-Host "warning: $pwaSource missing, skipping PWA icon" -ForegroundColor Yellow
  }

  # The patches are diffs against *prettier-formatted* upstream sources, so this
  # formatting pass is what makes them apply at all.
  #
  # --ignore-path: prettier honours .gitignore by default, and every file here
  # lives under scratch/ (gitignored), so without an explicit empty ignore file
  # prettier silently skips everything and every patch then fails. Upstream's
  # bash script passes /dev/null for exactly this reason.
  Step "prettier: format every file the patches touch"
  $emptyIgnore = Join-Path $repo "scratch\.prettierignore-empty"
  New-Item -ItemType File -Force $emptyIgnore | Out-Null
  $targets = Get-ChildItem "patches\*.patch" | ForEach-Object {
    $file = $_.FullName
    Select-String -Path $file -Pattern '^\+\+\+ b/(.+)$' | ForEach-Object {
      "scratch/asar/" + $_.Matches[0].Groups[1].Value.Trim()
    }
  } | Sort-Object -Unique

  $existing = @($targets | Where-Object { Test-Path $_ })
  $missing = @($targets | Where-Object { -not (Test-Path $_) })
  if ($missing.Count) {
    Write-Host "warning: $($missing.Count) patch target(s) not in this package:" -ForegroundColor Yellow
    $missing | ForEach-Object { Write-Host "  $_" }
  }
  if (-not $existing.Count) { Fail "no patch targets found under scratch/asar" }

  $batchSize = 40
  for ($i = 0; $i -lt $existing.Count; $i += $batchSize) {
    $chunk = $existing[$i..([Math]::Min($i + $batchSize - 1, $existing.Count - 1))]
    & (Join-Path $bin "prettier.cmd") --ignore-path $emptyIgnore --ignore-unknown --write @chunk
    if ($LASTEXITCODE -ne 0) { Fail "prettier failed" }
  }

  Step "apply patches"
  # Same order as scripts/prepare_asar.
  $patches = @(
    "webview-remove-csp.patch",
    "webview-style.patch",
    "webview-preload.patch",
    "webview-favicon.patch",
    "webview-pwa.patch",
    "webview-thread-title.patch",
    "webview-initial-route.patch",
    "webview-electron-shim-close-sidebar.patch",
    "webview-prosemirror-inputmode.patch",
    "webview-use-atfs-for-local-files.patch",
    "webview-statsig-override-adapter.patch",
    "webview-statsig-bootstrap-retry.patch",
    "webview-prompt-search-param.patch",
    "sentry-disable-shell.patch",
    "sentry-disable-webview.patch",
    "preload-disable-device-check.patch",
    "webview-safe-header-left.patch",
    "app-host-json-rpc.patch",
    "app-host-browser-windows.patch"
  )

  # Absolute, forward-slash paths: MSYS patch (Git's usr/bin) resolves relative
  # paths against its own idea of the working directory and fails to open them.
  $asarDir = (Join-Path $repo "scratch/asar").Replace('\', '/')
  foreach ($name in $patches) {
    $path = (Join-Path $repo "patches/$name").Replace('\', '/')
    if (-not (Test-Path $path)) { Fail "missing patches/$name" }
    $output = & patch --batch --forward --strip 1 --directory $asarDir --input $path 2>&1
    if ($LASTEXITCODE -ne 0) {
      Write-Host ($output | Out-String) -ForegroundColor Red
      Write-Host "  ^ this patch did not apply; check for a .rej next to the file" -ForegroundColor Red
      Fail "$name"
    }
    Write-Host "ok  $name"
  }

  Step "drop the packaged better-sqlite3 (the repo provides a host build)"
  Remove-Item -Recurse -Force "scratch\asar\node_modules\better-sqlite3" -ErrorAction SilentlyContinue
}

# --- build ---------------------------------------------------------------

Step "build:browser (vite)"
& $npmCmd run build:browser
if ($LASTEXITCODE -ne 0) { Fail "build:browser failed" }

Step "build:server (tsc)"
# Output goes to scratch/server instead of next to the sources: the security
# software on this machine denies the Node process writes inside src/, patches/,
# assets/ and scripts/ (only new/untracked trees like scratch/ are writable).
# The layout is equivalent - both are two levels below the repo root, so the
# server's path.resolve(__dirname, "../../scratch/asar") still resolves.
$serverOut = Join-Path $repo "scratch/server"
Remove-Item -Recurse -Force $serverOut -ErrorAction SilentlyContinue
& (Join-Path $bin "tsc.cmd") --project src/server/tsconfig.json --rootDir src/server --outDir $serverOut
if ($LASTEXITCODE -ne 0) { Fail "build:server failed" }

Write-Host ""
Write-Host "done." -ForegroundColor Green
Write-Host "start it with (the portable node is required for the native module):"
Write-Host "  tools\node-v$NodeVersion-win-x64\node.exe scratch\server\main.js --host 127.0.0.1 --port 8214"
