@echo off
cd /d "%~dp0"
rem 2.2.19 (sweep2): keep the tool's exit code - the window still pauses, then this .cmd ends with that code (it used to end 0)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Find-Cameras.ps1" %*
set "WIREIT_RC=%ERRORLEVEL%"
echo.
pause
exit /b %WIREIT_RC%
