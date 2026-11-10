@echo off
rem WireIt Toolkit 2.2.11: Restore Network - Reset chosen adapter to DHCP (no extra addresses; old settings saved first). Runs on its own.
echo Restore Network: Reset chosen adapter to DHCP (extra addresses off). Its old settings are saved first.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0RestoreNetwork.ps1" %*
echo.
pause
