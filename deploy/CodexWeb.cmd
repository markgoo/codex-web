@echo off
rem Double-click me after a reboot: starts codex-web + nginx with no window,
rem then opens the UI. Status/logs: deploy\CodexWeb.ps1 status
start "" wscript "%~dp0CodexWeb.vbs"
