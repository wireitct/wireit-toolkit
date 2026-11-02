@echo off
rem Opens the WireIt Toolkit window (no console window stays open).
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0WireItToolkit.ps1"
