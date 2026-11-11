WireIt "Fix NVR"  (C:\WireIt\FixNVR)            version 1.1, 2026-11-02
===========================================================================
Gets an NVR app back online after the internet service changed, without a truck roll.
Fixes the 3 usual causes:
  1. New router = new IP scheme -> NVR (static) and switch cameras are stuck on the old scheme.
  2. DNS removed from the NVR.
  3. Platform access (Hik-Connect / Uniview EZCloud) unticked.
Windows PowerShell 5.1 only, nothing to install. Runs on ANY Windows PC on the site network:
the customer's PC through our remote page (https://service.wireitct.com/remote/ -> RustDesk) or a tech laptop.

ADDRESS STANDARD (v1.1, Moshe Nov 2 2026)
  Router DHCP range  .100 - .254   (.100 - .253 on Xfinity; Comcast Business: change the start .10 -> .100)
                     REQUIRED install step. Xfinity home: turn on Admin Tool online access in the Xfinity app first.
                     eero / Deco / Google Nest: app only. eero and TP-Link Deco default to a /22 mask: check it.
                     Can't get into the router? Reserve the NVR's address in the router/app instead, and type
                     "reserved" when NVR Snapshot asks for the DHCP range.
  NVR                .20 static (.19 / .18 if taken), mask + gateway = router, DNS 8.8.8.8 / 1.1.1.1
  Switch cameras     .21 - .99 static, camera Dn -> .20+n (D1 = .21, D12 = .32); a camera already inside .21-.99
                     keeps its number if it is free
  Other WireIt gear  .10 - .19 (access control, switches)
  Before using any address the tool checks nothing answers on it. If this PC got its own address below .100 from
  the router, the router's range was not changed: the tool prints the exact router step for that router.

THE 3 BUTTONS (double-click; Windows asks for admin rights once)
  Check NVR.cmd     Look only. Finds the NVR + cameras on ANY IP scheme, shows what is wrong and the exact plan.
  Fix NVR.cmd       Same, then type YES once to apply. Verifies the app is online and every camera is back.
  NVR Snapshot.cmd  At install: saves the known-good record (MAC / IP / serial / channel map, NO passwords)
                    into the site's Google Drive folder (Docs) and checks the install standard.
                    Asks (optional) for the router model and its DHCP range so Fix NVR knows them later.

WHAT A FIX DOES (in this order, only after YES)
  - Moves each switch camera that the NVR uses from the old scheme to the new one
    (keeps its last number if it is already inside .21-.99, e.g. .64 -> .64, otherwise camera Dn -> .20+n).
  - Updates the NVR's camera list to the new camera addresses.
  - Turns platform access on.
  - Moves the NVR to .20 (or .19/.18 if taken), static, gateway = new router, DNS 8.8.8.8 / 1.1.1.1.
    If the NVR asks for a restart, it is restarted (about 2 minutes).
  - Waits for Hik-Connect to show ONLINE and counts cameras online.
  Cameras on the NVR's own PoE ports (192.168.254.x) are never touched.
  Devices on the old scheme that are NOT in the NVR's camera list are listed and left alone.
  With a snapshot from install, everything goes back to the exact same last numbers.
  A NEW internet box starts with its factory DHCP range (often the whole .2-.254), so after moving the NVR
  the tool prints the ROUTER STEP for that router: set it to hand out .100 and up.
  An NVR already on the right scheme but at an old high address (e.g. .250) is left where it is (a note says so).

HOW IT REACHES DEVICES ON THE OLD SCHEME
  Hikvision devices answer Hikvision's network-wide search (SADP) whatever their IP. Uniview and others are
  found by a 20-second passive listen (Windows' built-in pktmon) and the NVR's own camera list.
  The PC then gets a temporary extra address on the old scheme (e.g. 192.168.1.253): memory-only,
  removed at the end even on error or Ctrl+C, a reboot also clears it, and a safety task removes it after
  30 minutes if the window was closed. The next run also cleans up anything a crashed run left.
  A temporary firewall rule for the search replies is added and removed the same way.

PASSWORDS
  Asked once per run with hidden typing (NVR password; camera password = Enter if the same).
  Or pick from a Bitwarden export:  -BitwardenExport C:\path\export.json [-BitwardenItem "name"]
  (unencrypted .json export; delete it right after). Passwords are never stored, logged, or sent anywhere
  except to the device itself. One login try per device: a wrong password is never retried (no lockouts).

SAFETY
  - Devices are only READ until you type YES. Check mode never changes a device.
  - Full log of every request (passwords blanked) + before.json / plan.json / rollback.json / after.json in
    runs\<mode>-<time>\.
  - Undo:  powershell -ExecutionPolicy Bypass -File FixNVR.ps1 -Mode Rollback -RollbackFile "runs\Fix-...\rollback.json"
    2.2.18: Undo (and every change in Fix) first reads the device at the address and changes it only when it reports the MAC saved
    for it. A different device there, a device that does not say its MAC, or an old address now used by another device = "NOT restored",
    nothing is sent, and the run ends "NOT RESTORED" (never "Done."). A move counts only when the settings read back match.
  - Official interfaces only: Hikvision ISAPI + SADP search (read), ONVIF (open standard), Uniview LiteAPI.
  - "Done." only when the check after the fix read every NVR and found platform access online and every camera
    online. Anything it could not read (wrong NVR password, NVR not answering, camera status) is a red NOT CHECKED
    line and the run ends NOT DONE - never "looks right". Fix the login or what is listed and run again.
  - At the end the PC's own connection is checked (an address from the router and a default route, waiting up to
    about 30 s for the lease). If it is not back, the run says FAILED - Run again and keeps its record, so the
    next run (or the safety task) puts it back.

UNIVIEW STATUS (read this)
  - Uniview cameras on a switch are moved with ONVIF (standard, on by default on Uniview).
  - Uniview NVR: the tool READS it (model/serial/IP/channels from Uniview's LiteAPI). Changing a Uniview NVR's
    IP/DNS/cloud setting automatically is OFF until tested on a real Uniview NVR; until then the tool prints
    the exact by-hand steps and keeps the old-scheme address up so you can do them from the same PC.
    After a successful test, run with -AllowUnverifiedUniview (and fill uniview.cloud_path in config.json).

OPTIONS (PowerShell)
  .\FixNVR.ps1 -Mode Check|Fix|Snapshot|Rollback|Cleanup
     -Site "<Drive site folder>"   use/save the snapshot in that site folder
     -Snapshot <file>              use a specific snapshot
     -OldSubnet 192.168.1          force the old scheme if the search cannot see it
     -Nvr 192.168.1.250            NVR's current IP if known
     -NoLogin                      discovery only (no logins)
     -MoveUnlisted                 also move old-scheme cameras that are not on an NVR's camera list (lone camera, no NVR login)
     -SniffSeconds 0               skip the passive listen
     -RouterModel "Xfinity XB8" -DhcpRange "100-254"   (Snapshot) record the router + its range ("reserved" if reserved)
  config.json: nvr_hosts (20,19,18), camera_block_start/end (21/99), camera_channel_base (20: Dn -> .20+n),
  router_dhcp_start (100), dns1/dns2, temp_ip_hosts, waits, snapshot folders.

MOVE / INSTALL ON ANOTHER PC
  Copy the whole FixNVR folder (anywhere, e.g. C:\WireIt\FixNVR or a USB stick) and double-click a .cmd.
  Nothing else to install. Delete the runs\ folder whenever you like. On a customer PC, delete the folder after.

SPARE-CAMERA TEST (first real device)
  1. Plug the camera into the same switch as this PC. If it was factory reset, activate it in HiTools first.
  2. Check NVR.cmd  -> it should list the camera on its old scheme (e.g. 192.168.1.64) and plan a move.
  3. powershell -ExecutionPolicy Bypass -File FixNVR.ps1 -Mode Fix -MoveUnlisted  -> YES -> camera moves to the Dell's
     scheme, keeping .64 (inside .21-.99) or going to the first free address in .21-.99.
  4. Rollback with the printed command -> camera goes back. (With a test NVR, plug the camera into the NVR's channel list first
     and run without -MoveUnlisted: the NVR's list is updated too.)

TESTS
  tests\run_tests.py + tests\mock_devices.py: simulated Hikvision NVR/cameras + Uniview camera.
  python tests\run_tests.py powershell.exe   (59 checks: plan, fix, wrong password, rollback, snapshot, lone camera, router steps, ...)
