@echo off
rem Starts Tray for Claude (the icon appears next to the clock). The first time, it opens claude.ai to sign in.
rem It also adds "Tray for Claude" to the Start menu (Windows search) and a shortcut with its icon in this folder.
if not exist "%LOCALAPPDATA%\ClaudeTray\browser-profile" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ClaudeTray.ps1" -WebLogin
) else (
  start "" powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0ClaudeTray.ps1"
)
