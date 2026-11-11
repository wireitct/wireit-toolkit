@echo off
rem WireIt Toolkit: save the service-log upload key on THIS PC (encrypted for this PC only). Ask the office for the key.
rem 2.2.19 (sweep2): keep the tool's exit code - the window still pauses, then this .cmd ends with that code (it used to end 0)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0CamViews.ps1" -SetKey
set "WIREIT_RC=%ERRORLEVEL%"
pause
exit /b %WIREIT_RC%
