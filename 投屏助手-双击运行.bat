@echo off
start "" conhost.exe --headless powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scrcpy-helper.ps1"
