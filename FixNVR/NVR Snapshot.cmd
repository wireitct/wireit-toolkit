@echo off
title WireIt - NVR Snapshot (install record)
cd /d "%~dp0"
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
set SITE=
set RMODEL=
set RRANGE=
set /p SITE=Site folder name (as in Google Drive, Enter to skip): 
set /p RMODEL=Router make/model, e.g. Xfinity XB8 (Enter to skip): 
set /p RRANGE=Router DHCP range, e.g. 100-254, or reserved (Enter to skip): 
set ARGS=-Mode Snapshot
if not "%SITE%"=="" set ARGS=%ARGS% -Site "%SITE%"
if not "%RMODEL%"=="" set ARGS=%ARGS% -RouterModel "%RMODEL%"
if not "%RRANGE%"=="" set ARGS=%ARGS% -DhcpRange "%RRANGE%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0FixNVR.ps1" %ARGS%
echo.
pause
