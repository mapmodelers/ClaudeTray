@echo off
rem Starts Tray for Claude (the icon appears next to the clock). On its first start the tray also adds
rem "Tray for Claude" to the Start menu (Windows search) and a shortcut with its icon in this folder.
start "" powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0ClaudeTray.ps1"
