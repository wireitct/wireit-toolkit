@echo off
rem WireIt Toolkit: save the service-log upload key on THIS PC (encrypted for this PC only). Ask the office for the key.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0CamViews.ps1" -SetKey
pause
