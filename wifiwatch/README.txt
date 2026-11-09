WireIt WifiWatch - Wi-Fi auto-reconnect for site boxes (added to the Setup package Nov 5 2026; first used on SITEBOX 2, Nov 4 2026).

What it does: every minute (SYSTEM task "WireIt WifiWatch"), if Wi-Fi says "connected" but there is no internet
for 2 checks in a row, it disconnects and reconnects the same Wi-Fi network. Still down a minute later: it turns the
Wi-Fi adapter off and on. Then it retries every 10 minutes while it stays down.
While a wired Ethernet connection with a gateway is up it does nothing (just logs "ok (on Ethernet ...)").

Files (C:\WireIt\WifiWatch): WifiWatch.ps1, install-task.ps1, wifiwatch.log (rotates at 200 KB to wifiwatch.log.old), state.txt.
Install / repair: powershell -NoProfile -ExecutionPolicy Bypass -File C:\WireIt\WifiWatch\install-task.ps1
Remove: Unregister-ScheduledTask -TaskName 'WireIt WifiWatch' -Confirm:$false
Setup-SiteBox.ps1 installs it on every site box (Install-WifiWatch). Not on the office PC.

2.2.11 (Nov 9 2026): WifiWatch.ps1 switches the Wi-Fi adapter back on in try/finally, keeps a marker file (adapter-off.txt) while the adapter is off, and the next run switches it back on first if a run was stopped half-way. Kept here in the Toolkit repository with its tests (Toolkit\tests\Test-Fix2211.ps1); the site boxes still run the copy from the PC Setup package until it is installed there.
