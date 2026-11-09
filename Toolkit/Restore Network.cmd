@echo off
rem WireIt Toolkit 2.2.11: Restore Network - this PC's network adapter back to normal (DHCP, no extra addresses). Runs on its own.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0RestoreNetwork.ps1" %*
echo.
pause
