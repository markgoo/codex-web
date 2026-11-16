@echo off
rem Double-click to stop both codex-web and nginx.
rem Shows what it stopped, then closes itself after a few seconds.
title Stopping codex-web
setlocal

echo Stopping codex-web + nginx...
echo.
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0CodexWeb.ps1" stop
echo.
echo This window closes in 5 seconds.
rem ping instead of timeout: timeout refuses to run when stdin is redirected.
ping -n 6 127.0.0.1 >nul 2>&1
exit /b 0
