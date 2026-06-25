@echo off
rem ASCII-only launcher. Do not put Chinese characters in this file.
rem Launch the GUI without keeping a console window.
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0scrcpy-helper.ps1"
