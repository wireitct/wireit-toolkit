WireIt Toolkit  (C:\WireIt\Toolkit)                    version 1.4.0, 2026-11-03
==============================================================================
One window for the site tools. Double-click "WireIt Toolkit" on the desktop.
Works with no internet and without Tab. Windows PowerShell 5.1 only, nothing to install.
1.1.0: new look (WireIt header, colored job cards with icons, color-coded results), sharp on 150% screens.
  Same buttons and steps as before. If Windows cannot build the new look, the plain buttons are used.

THE BUTTONS (usual order on a site)
  1 Find cameras            read-only. Every Hikvision / Uniview camera and NVR, even on another IP scheme.
  2 Check NVR               read-only. What is wrong (IP scheme, DNS, app access) and the fix plan.
  3 Fix NVR                 shows the plan, changes things only after you type YES. Undo with 7.
  4 Reset passwords         unknown Hikvision password: reset file, Hikvision form, new password (see below).
  5 Network check           read-only. Cable speed and errors, pings every device.
  6 Save install snapshot   install day: known-good record of NVR + cameras (no passwords).
  7 Undo last fix           puts devices back the way the last Fix NVR found them.
  8 Save camera pictures    read-only. One picture per camera for the site page.
 RECORDER HEALTH (1.3.0) - type the recorder's IP; the password is typed hidden in the tool window
  9 Recording check         read-only. Every camera recording? Days of footage kept vs. the site's target,
                            hard drives + their health. Target: YKW sites 45 days, others 30
                            (config.json "daysToKeep"; or type the days in the box when you run it).
 10 Clock check             read-only. Recorder (and camera) clocks vs. real time, time server, US Eastern + DST.
 11 Fix clock (NTP)         CHANGES the time settings (time.nist.gov + US Eastern with daylight saving).
                            Shows the plan first; nothing changes unless you type YES (capitals) in its window.
                            Do it on site, with the customer's OK.
 12 Firmware check         read-only (security check). Firmware vs. the newest published + known security holes.
                            REPORTS ONLY - it never updates firmware. Updates are the boss's call.
  Works with Hikvision, Uniview, DW Spectrum and other ONVIF recorders. The firmware list comes with the
  Toolkit and is refreshed monthly by the daily NVR check (C:\WireIt\NvrHealth) when that PC has it.
  Results show in plain words on the right. "Copy results" copies them. Every run is saved in logs\.
  2, 3, 6, 7 open a blue tool window (Windows asks permission: Yes). Passwords are typed there, hidden.
  Passwords are never saved or logged. Optional: "Advanced..." under Job options > "Read NVR passwords from a
  Bitwarden export file" (the Toolkit offers to delete that file when you close it - it holds passwords unencrypted).
  "Site ID or address" box: the Site ID on the QR sticker (WI-061) or the address / site folder name (2336 Main St).
  Check/Fix/Snapshot use the folder name to find the site's Drive folder (a WI code does not work there yet).

SITE CAMERA LIST (1.4.0)
  Type the site in the box, then 1 Find cameras: the camera list (type, brand, model, serial, MAC, IP, firmware -
  NEVER a password) is saved to that site's page. ONE list per site, compared with the last scan:
    MISSING / NEW / CHANGED IP show in red at the top of the results; the same scan twice saves nothing
    ("No changes - site list already up to date"). A missing camera stays on the site page marked
    "Missing - not found in last scan" with ONE alert to the office; the office removes it there when it is gone for good.
  6 Save install snapshot also saves the known-good list (the baseline). No site typed = "Tip: type the site...".
  Uses the same upload key as 8 Save camera pictures ("Set upload key.cmd"). No internet: sent with the next scan.

4 RESET PASSWORDS (Hikvision, official method only)
  1 Pick the device (from the last Find cameras, or "Scan now").
    Factory-fresh device = no reset needed: activate it in HiTools with a password from step 5.
  2 HiTools > tick device > Reset Password > Import/Export Key > Export XML File > save in
    C:\WireIt\CamReset\requests\export ("Copy save folder"). The Toolkit sees the file and files it by itself.
    From now on the device must NOT reboot or lose power until the reset is done (48 hours max).
  3 "Open the Hikvision form", click each field button and paste. Upload: "Copy XML file path", paste in the
    File name box, Enter. Tick the statement, type the picture code, Submit.
  4 Hikvision emails moshe@wireitct.com (usually a few hours). Save the attachment and drag it onto the Toolkit.
  5 "Make a new password" > HiTools > Reset Password > Reset via XML File > pick the reply file
    ("Copy reply file path") > paste the password > OK. NVR: tick "also reset the connected cameras".
    Save the password in Bitwarden right away, then "Saved in Bitwarden - hide it".
  Other way: HiTools "Reset via QR Code" + the Hik-Partner Pro app (online support case), no email wait.
  Uniview: Find cameras already tries the factory password once; locked Uniview = CamReset README step U.

UPDATES
  At start the Toolkit checks https://raw.githubusercontent.com/wireitct/wireit-toolkit/main/version.json
  (a public list with no passwords or site data). A newer version is downloaded, every file's SHA-256 is
  checked, and only then swapped in; the replaced files are kept in previous\. Offline or any error = it just
  runs the version it has. Updates may also refresh FixNVR, CamReset and NetCheck scripts; config.json files
  are never touched. "Go back to the previous version" (bottom of the window) undoes the last update.
  To stop updates: config.json "autoUpdate": false.

FILES
  WireItToolkit.ps1 (window)  ToolkitCore.ps1 (logic)  WireIt Toolkit.cmd (start)  Install-Toolkit.ps1
  config.json (form details, update address - no passwords)  version.json  wireit.ico  wireit-logo.png
  logs\  previous\  tests\Test-Toolkit.ps1 (60 checks, no devices, no windows)
  It runs: ..\CamReset (Find-Cameras.ps1, Make-Request.ps1), ..\FixNVR (FixNVR.ps1), ..\NetCheck (NetCheck.ps1)

MOVE TO A NEW PC (e.g. the new EliteDesk)
  1. Copy the whole C:\WireIt folder to C:\WireIt on the new PC (USB stick or network). Keep the folder names.
  2. Install HiTools Delivery (free, hikvision.com > Support > Tools) if it is not there.
  3. Start > type PowerShell > right-click > Run as administrator, then:
       cd C:\WireIt\Toolkit
       powershell -ExecutionPolicy Bypass -File .\Install-Toolkit.ps1
     It makes the desktop + Start menu icon, unblocks the scripts, adds the camera-discovery firewall rules,
     and lists anything missing.
  4. Optional check: powershell -ExecutionPolicy Bypass -File .\tests\Test-Toolkit.ps1   (should end "0 failed")
  On a customer PC: copy the folder, run "WireIt Toolkit.cmd" directly, delete the folder afterwards.
