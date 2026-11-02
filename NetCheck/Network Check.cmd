@echo off
title WireIt - Network check (read-only)
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0NetCheck.ps1" -OutDir "%~dp0runs\NetCheck-%RANDOM%" %*
echo.
pause
