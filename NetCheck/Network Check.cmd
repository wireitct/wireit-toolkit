@echo off
title WireIt - Network check (read-only)
cd /d "%~dp0"
rem 2.2.19 (sweep2): keep the tool's exit code - the window still pauses, then this .cmd ends with that code (it used to end 0)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0NetCheck.ps1" -OutDir "%~dp0runs\NetCheck-%RANDOM%" %*
set "WIREIT_RC=%ERRORLEVEL%"
echo.
pause
exit /b %WIREIT_RC%
