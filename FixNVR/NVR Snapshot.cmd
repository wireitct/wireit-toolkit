@echo off
title WireIt - NVR Snapshot (install record)
cd /d "%~dp0"
net session >nul 2>&1
if errorlevel 1 (
  rem 2.2.19 (sweep2): wait for the elevated window and end with ITS exit code; plain exit /b keeps that code
  powershell -NoProfile -Command "try { $p = Start-Process -FilePath '%~f0' -Verb RunAs -Wait -PassThru -ErrorAction Stop; exit $p.ExitCode } catch { Write-Host 'Windows did not give administrator rights, so nothing ran.'; exit 5 }"
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
rem 2.2.19 (sweep2): keep the tool's exit code - the window still pauses, then this .cmd ends with that code (it used to end 0)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0FixNVR.ps1" %ARGS%
set "WIREIT_RC=%ERRORLEVEL%"
echo.
pause
exit /b %WIREIT_RC%
