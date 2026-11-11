@echo off
rem WireIt Toolkit 2.2.11: Restore Network - Reset chosen adapter to DHCP (no extra addresses; old settings saved first). Runs on its own.
echo Restore Network: Reset chosen adapter to DHCP (extra addresses off). Its old settings are saved first.
rem 2.2.19 (sweep2): keep the tool's exit code - the window still pauses, then this .cmd ends with that code (it used to end 0)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0RestoreNetwork.ps1" %*
set "WIREIT_RC=%ERRORLEVEL%"
echo.
pause
exit /b %WIREIT_RC%
