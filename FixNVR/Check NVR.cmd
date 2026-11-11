@echo off
title WireIt - Check NVR
cd /d "%~dp0"
net session >nul 2>&1
if errorlevel 1 (
  echo Asking Windows for administrator rights...
  rem 2.2.19 (sweep2): wait for the elevated window and end with ITS exit code; plain exit /b keeps that code
  powershell -NoProfile -Command "$a='%*'; try { if ($a.Trim()) { $p = Start-Process -FilePath '%~f0' -ArgumentList $a -Verb RunAs -Wait -PassThru -ErrorAction Stop } else { $p = Start-Process -FilePath '%~f0' -Verb RunAs -Wait -PassThru -ErrorAction Stop }; exit $p.ExitCode } catch { Write-Host 'Windows did not give administrator rights, so nothing ran.'; exit 5 }"
  exit /b
)
rem 2.2.19 (sweep2): keep the tool's exit code - the window still pauses, then this .cmd ends with that code (it used to end 0)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0FixNVR.ps1" -Mode Check %*
set "WIREIT_RC=%ERRORLEVEL%"
echo.
pause
exit /b %WIREIT_RC%
