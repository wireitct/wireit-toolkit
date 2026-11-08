WireIt Toolkit  (C:\WireIt\Toolkit)                    version 2.1.0, 2026-11-06
==============================================================================
HOW TO USE (2.0)
  1. Double-click "WireIt Toolkit" on the desktop.
  2. Type the site (the Site ID on the QR sticker, like WI-061, or the address).
  3. Leave the camera settings as they are, or pick codec / frame rate / resolution / bitrate.
     They go ONLY on the cameras with a problem. Working cameras are not touched.
     To put them on every camera, tick "Apply settings to ALL cameras" (unticks itself after each run).
  4. Press the big green "Fix this site". Click Yes when Windows asks.
  5. Read the list of what is wrong and what it will change. Type YES to fix it all.
  6. Watch the checklist: a green check per camera. A red X says exactly what to go check.

SITE PASSWORD (2.0.3) - every site has its own password, nothing is shared between sites.
  - A site with no site password yet asks once: "Do you know the password?" Yes = type it; No = type the new
    one you want. The Toolkit never makes one up. Devices still on a factory password (cameras + NVR) get it; their NVR channels
    are updated and each picture is checked.
  - "Make every device use the site password" (tick, off unless you tick it): for sites you took over with
    mixed passwords. Every camera/NVR on a different password gets the site password, one at a time;
    a camera whose picture does not come back gets its old password back and is listed. YES + backups + undo.
  - Saved in Bitwarden as "<site> - site password" if Bitwarden's bw command is on this PC (logged in),
    otherwise kept encrypted on this PC and shown once with a Copy button - save it in Bitwarden.
  - "Site password..." button: show (with Copy), copy, save in Bitwarden, make one, or type the one in use.

HIKVISION OFFICIAL PASSWORD RESET (2.1.0) - for a Hikvision NVR or camera nobody knows the password of
  No reset button, no power-cycle. Fix this site does it by itself, in this order, for the NVR and EVERY camera:
    1. Finds every Hikvision device on ANY IP range (SADP) and shows model, serial, MAC, IP, firmware, activated or not.
    2. Asks each device for its reset request file (the same step as SADP "Forgot password > Export file").
       A device is asked ONCE: asking again cancels the first file. The file is good 48 hours and only if the device does not restart.
    3. Opens Hikvision's official reset page (Edge or Chrome, in YOUR logged-in session) and fills it from config.json "form"
       (name, email, company, state, zip, role), types the serial and model and attaches the file.
       WHAT STILL NEEDS YOU: Hikvision's page shows a "slide the piece" / picture check. That is there to tell a person from a
       program and the Toolkit does not defeat it: you slide it and press Submit, one device at a time, ~20 seconds each.
       (Tried 6 Nov 2026: the browser service's built-in solver did not pass this slider, so there is no automatic option.)
    4. Hikvision emails the unlock file/key to the address in config.json (moshe@wireitct.com). The Toolkit watches that mailbox:
       "hikReset.mail.mode": "folder" = drop the files in the replies folder (Tab's mail watcher does this for WireIt),
       or "imap" (mail.user + an app password kept encrypted on this PC). Each reply is matched to its device by serial.
    5. Imports it the way SADP does (key exchange, then the new password encrypted with it + Hikvision's 8-character key),
       sets the SITE password, and believes it only after a real login with that password. If the device will not take it,
       it says so and tells you to finish that one in SADP (Forgot password > Import file) - never loops (at most 2 tries).
    6. Then the usual Fix this site: moves it to the WireIt IP plan, adds the cameras to the NVR (a plug-and-play NVR slot is
       switched to manual first), checks the picture. The temporary address on this PC is removed at the end.
  Safety: at most one bad login per device per 30 minutes (Hikvision locks a device after a few); passwords and keys are never
  written to a log; the request/answer state is in runs\HikReset\state.json and a run can be stopped and started again.
  Command line: HikReset.ps1 -Mode Run|Find|Export|Submit|Watch|Import|Status (-Only <serial/ip>, -Site "<site>").

NEW SITE, NOT LISTED (2.0.2): press the blue "New site (not listed)" beside the big button. Nothing to type.
  - It finds the router, the NVR and the cameras by itself (SADP, Dahua search, ONVIF/sweep, the NVR's channels)
    and names the site from what it sees, e.g. "New site 10.0.5.x 2026-11-04".
  - Passwords tried: the one saved for that camera, then the old factory default (Hikvision 12345 /
    Dahua admin / Uniview 123456) - all inside the same limit of tries, so nothing locks. No password is
    shared between sites (2.0.3). Devices still on the factory password (cameras + NVR) get the new site
    password, with their NVR channel updated and the picture checked.
  - The list says "New site (no saved list): found 1 NVR (...) and N cameras ..." first. "Missing" on a new site =
    a camera the NVR has a channel for but that has no video and does not answer.
  - Same rule as always: ONLY problem cameras change (wrong IP scheme, hung, no video, not activated...);
    working cameras are not touched; nothing happens until you type YES; backups + "Undo the last fix".
  - After the list it asks for the address (optional; Enter keeps the automatic name). The site list and its
    passwords are saved on this PC under that name. Next time pick it in the site box - or press New site again:
    it recognises the NVR and uses the saved site.

WHAT "FIX THIS SITE" DOES (no order to remember, safe to run again)
  - Knows what SHOULD be there: the site's list from its Drive folder (Docs\WireIt site list.json),
    else this PC's copy, else the Fix NVR install snapshot. No list yet: at the end it offers
    "Save this as the site's list" (cameras, IPs, NVR channels, switch ports - no passwords).
  - ONLY CAMERAS WITH A REAL PROBLEM ARE CHANGED (2.0.1): offline / no video on the NVR / hung /
    wrong IP scheme / not on the NVR / password unknown / locked / not activated / missing.
    A working camera gets NOTHING: no password, no settings, no I-frame, no address change.
    The list starts with "Changes only the N cameras listed below. M working cameras will not be touched."
    and working cameras are one "OK, not touched" line. A working camera on DHCP or outside .21-.99 is
    named ("Working, left as is") but not moved.
  - Two ticks (both off unless you tick them for that run; they untick after each run):
      "Apply settings to ALL cameras"        - the drop-downs go on working cameras too (only what you picked).
      "Make every device use the site password" - every camera and NVR on a different password gets this
          site's password, one at a time: new password -> its NVR channel updated -> picture checked.
          A picture that does not come back = that camera's old password is put back and it is reported.
    When ticked, the list's first line says how many working cameras are included.
  - Shows only problems. Missing cameras say which switch port to check.
  - WireIt IP scheme: router .100+, NVR .20, cameras .21-.99, other gear .10-.19.
  - Per camera being fixed, one at a time: backup of its settings first, the site password, the camera settings,
    move to the right IP scheme, back on the NVR, restart / power-cycle its switch port if it hangs,
    then waits until the NVR shows video and it holds for 20 seconds.
  - Camera settings (cameras being fixed): nothing picked = each camera keeps its own, except old/problem
    cameras (Dahua on a Hikvision NVR, firmware 2020 or older) get H.264 and Smart Codec off. I-frame = frame rate.
  - Passwords (2.0.3): EVERY SITE HAS ITS OWN PASSWORD - nothing is shared between sites. Tries the
    password that last worked on that camera, this site's password, ones typed at this site before, and
    the makers' factory passwords (new sites only) - at most 3 tries per camera. Unknown: one question;
    then the official Hikvision / Dahua reset with one plain step for you.
    A site with no site password yet asks once: "Do you know the password?" Yes = type it; No = type the new
    one you want (never made up by the Toolkit). Every device still on its factory
    password (cameras + the NVR) gets it, with its NVR channel updated and the picture checked.
    It goes into Bitwarden as "<site> - site password" when the Bitwarden command (bw) is on this PC and
    logged in; otherwise it stays encrypted on this PC (secrets\) and is offered for saving in Bitwarden.
    Save it there. Never in Drive, logs, plan files or messages.
  - Site password... (button): show it (Copy button), copy it, save it in Bitwarden, or type
    the one this site uses (or the new one you want).
  - Undo the last fix: puts every camera and the NVR back the way that run found them.
  - Just look (change nothing): the same list, no YES, nothing touched.
  - Every run: runs\FixSite-<date>\ (log, plan, backups, undo file).
  - The old numbered buttons are under "More tools (old buttons)".

OLDER NOTES (1.x)
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

CHECK THIS SITE / CAMERA DOCTOR (1.5.0)
  Check this site (read-only): Find cameras, saves the list to the site page, then checks the recorder
    (NVR or DW Spectrum server) and prints one summary with what would fix each problem. Nothing is changed.
  Recorder type box: auto / hikvision / uniview / dw. DW Spectrum: https on 7001, falls back to http.
  DW servers: "Offline in DW" list - each camera offline, not recording, or nothing recorded for 24 h, with
    its last recording and whether it still answers ping/ARP (cable/power vs camera/password problem).
  Camera doctor: ONE camera - why is it offline? Ping, ARP/MAC, web page, the recorder's view, then at most
    ONE login try (none if the camera already says it is locked). Saves logs\doctor-last.json.
  Find cameras also sweeps the PC's own network (/24) so cameras that miss the discovery still show up;
    Uniview shows "Not tried" when no login was tried. The installer adds the firewall rule so Windows
    does not ask (run Install once as admin).
  Window fits a 1024x768 screen (scrolls instead of cutting off).
  New in 1.5.0 and NOT yet tested on real equipment: the network sweep, DW offline list, Camera doctor.

FIX WHAT FAILED (1.6.0) - NOT YET TESTED ON REAL EQUIPMENT
  Button next to Camera doctor. Lists ONLY the fixes the last Check this site / Camera doctor found
  (last 24 hours). Each fix opens a tool window: shows the plan, saves a backup, changes nothing until
  you type YES (capitals). Passwords are typed there, hidden, never saved. Log: runs\Fix-<fix>-<time>\
  and logs\fix-history.txt.
    Turn recording back on   cameras whose recording is switched off (Hikvision NVR / DW)
    Restart the camera       ONE camera, max once an hour and twice a day
    Put the camera back      re-add a camera to its NVR channel (Hikvision NVR)
    Set the time server      same as 11 Fix clock
    Update firmware          ONE device, Hikvision, only with the SHA-256 from the maker's page; settings exported first
    Set the site password    ONE device (Hikvision), strong password typed twice
    Fix the camera password in DW   gives DW the camera's right password so DW stops locking it
  Undo: each run saves its backup in its runs folder. the "Go back to the previous version" button removes 1.6.0.

1.6.3 SMALL FIXES (from the YKW Elm live run of 1.6.2, Nov 3 2026)
- DW recording line names the cameras (DW name + IP) instead of DW's list numbers ("5, 30, 55...").
- Last-footage times in the recording details are shown in this PC's local time (they were UTC, 5 h off).
- Camera clocks behind a DW server: the cameras Find cameras just found are read WITHOUT a login (the standard
  ONVIF time read - no password is sent, nothing can lock). One summary line; only wrong clocks are listed.
  A wrong camera clock behind DW is fixed on the camera's page (or by DW) - no "Fix time" button for it.
- Firmware: cameras whose model is not in the reference list are one line ("N camera model(s) not in the
  reference list"), each one is in the log.
- "Restart the camera" is offered only for a camera that still has a network link (it reboots through its own
  web page). "Put the camera back on the NVR" is never offered on a DW server.
- A DW session is logged out at the end of every run (also when a check stops with an error), and recording,
  clock and firmware share ONE DW login (a working login used to be sent up to 3 times).
- Find cameras: "If Windows asks about the firewall, press Cancel; to add the firewall rule, run the Toolkit
  installer once as admin."
Not tested on real equipment yet (mock tests only): the no-login camera clock read on Uniview cameras, the DW logout.

1.6.2 FIX (YKW Elm live re-test of 1.6.1, Nov 3 2026)
- With a working DW login, "Check this site" stopped half way with "the file log.txt is being used by another
  process" (the Toolkit window reads the log while the check writes it). The log is now written shared, with a short
  retry, and can never stop a check; if it stays locked the rest goes to log-2.txt next to it.
- A check that stopped with a problem now says "Recorder: NOT CHECKED - the check stopped with a problem (...)"
  instead of "no answer or no login".

1.6.1 FIXES (after the YKW Elm live test, Nov 3 2026)
  - DW / recorder login refused or skipped: "Offline in DW: NOT CHECKED (login refused)" in amber - never
    "every camera online". Recording / clock / firmware that could not be read say NOT CHECKED too, and the
    result is never "all OK".
  - The recorder login is ONE try per run (recording, clock and firmware no longer each try again).
  - Leave the recorder password EMPTY to skip the login: nothing is sent, those parts show NOT CHECKED.
  - Clock that could not be read = "Clock: not checked". No "time needs fixing", no time-server fix offered.
  - Check this site uses the camera list Find cameras just made on this PC (last 30 minutes), even with no
    Site ID typed (then it counts them; with a Site ID it compares with the site list as before).
  - DW servers: firmware is report only (DW updates come from the DW installer) - no "Update firmware" fix.
  - Captions fit at 1024x768 (the font shrinks a little instead of cutting words).
  DW cloud-account login: NOT built - the Toolkit logs in to the local DW server only (use a local or
    read-only DW user).

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
  At start the Toolkit checks https://wireit-toolkit-dl.wireitct.workers.dev/version.json (since 2.0.4: WireIt's
  own Cloudflare download service, so the code on GitHub can be private; the Toolkit sends its download key,
  which only allows Toolkit downloads, plus the PC name and version so we can see which PCs have updated).
  While the GitHub repo is still public, raw GitHub is the fallback. A newer version is downloaded, every file's SHA-256 is
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
