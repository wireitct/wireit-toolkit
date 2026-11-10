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

2.2.12 (Nov 9 2026, Codex P1-7): Restore Network (Toolkit) writes a pause file %ProgramData%\WireIt\wifiwatch.pause (line 1 "until=<UTC time>") while it works and while it checks the connection. While that file is fresh WifiWatch.ps1 does nothing: it checks it at the start and again right before every reconnect, adapter off/on and connect step. Switching an adapter back ON that an earlier run left off still happens. An expired pause file (or one more than 30 minutes ahead) is ignored, so a Restore Network that crashed never stops WifiWatch for good. Restore Network also waits for (or stops) a WifiWatch run that is already going. A site box only gets this once the new WifiWatch.ps1 is installed there (it is not part of the Toolkit update); until then Restore Network's task switch-off and stop are what keep the old copy out of the way.

2.2.13 (Nov 10 2026, Codex 2.2.12 #4): Restore Network no longer switches the "WireIt WifiWatch" task off at all (a run that was killed left it off for good). The pause is only the pause file above, which expires by itself. A task an earlier 2.2.12 Restore Network left switched off (its pause file still there) is switched back on by the next Restore Network run with admin rights; without admin it says "WifiWatch is OFF - turn it back on: Task Scheduler > WireIt WifiWatch > Enable".
