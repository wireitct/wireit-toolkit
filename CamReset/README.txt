WireIt CamReset - camera password-reset tool (trial, Nov 2 2026)
=================================================================
Official vendor methods only. Nothing here guesses passwords, uses backdoors, or submits anything by itself.
New passwords go to Bitwarden only (never Drive, never WhatsApp).

FILES (this folder is portable: copy the whole folder to another PC and run Install once)
  Find Cameras.cmd      double-click: finds every Hikvision/Uniview camera on the network (read-only)
  Find-Cameras.ps1      the finder (SADP + ONVIF discovery, /24 network sweep, device date, Uniview default-password check)
  Make-Request.ps1      packages a Hikvision reset request after you export the XML in HiTools
  Install-CamReset.ps1  one-time setup, run as admin (firewall rules so camera replies are not blocked)
  config.json           company details used on the vendor forms (no passwords)
  out\                  scan results (devices.csv / devices.json / summary.txt, latest.json)
  requests\             one folder per camera: request.json + the exported XML.  requests\export = save exports here
  replies\              vendor reply emails + attachments (Encrypt.xml / key) dropped here by Tab
  camreset.log          what ran and when

MOVE TO ANOTHER PC
  1. Copy C:\WireIt\CamReset to the same path on the new PC.
  2. Install HiTools Delivery (official Hikvision tool) and EZTools 3.0 (official Uniview tool) if missing.
  3. Right-click PowerShell > Run as administrator:  cd C:\WireIt\CamReset ; powershell -ExecutionPolicy Bypass -File .\Install-CamReset.ps1

STEP 1 - FIND  (any brand)
  Plug the PC into the same network/switch as the cameras. Double-click "Find Cameras.cmd".
  For each camera it shows: brand, model, serial, IP, Hikvision "Start Time", device date, and the next step.
  - Hikvision "NOT ACTIVATED" = factory fresh, no reset needed: activate it in HiTools with a new password.
  - Uniview "Default password works" = no reset needed: log in with admin/123456 and set a new password.
  - Camera on another IP scheme: HiTools still sees it; the finder says so.
  It also re-checks open requests: if a Hikvision camera rebooted since its XML was exported, it says the request is dead.
  Nov 3 2026: it also SWEEPS this PC's own /24 (ping + ports 80/554/8000/7001, about 5-10 s, never wider than a /24),
  so cameras that miss the discovery answers still show up ("Found by the network sweep: answers on 80/554, maker guess
  Uniview (from MAC)"). Non-cameras (DW server on 7001, switches, PCs) are listed under "Other things on the network".
  The sweep never logs in. Options: -NoSweep, -NoMulticast, -SweepTargets 10.1.61.0/24, config "sweep": false.
  Uniview shows "Not tried" when no default-password try happened (try off, -NoLogin, or found only by the sweep);
  "Locked" only appears after a real try was refused.

STEP H - HIKVISION (US web form, XML method)
  H1. Open HiTools Delivery. Tick the camera in the device list.
  H2. Reset Password > Import/Export Key > Export XML File. Save into C:\WireIt\CamReset\requests\export
      (HiTools can also export several cameras at once).
  H3. Run Make-Request.ps1 (or tell Tab "exported"). It files the XML with the camera's serial, model and start time.
  H4. Tab fills https://www.hikvision.com/us-en/support/password-reset/ and stops BEFORE Submit.
      Moshe OKs the exact text. Customer cameras also need the customer's written OK. Then the picture code is typed and it is sent.
  H5. DO NOT unplug, power-cycle or reboot the camera until the key is imported. The XML/key is good for 48 hours.
  H6. Reply arrives in moshe@wireitct.com (Encrypt.xml or a key). Tab saves it to replies\.
  H7. HiTools > tick the camera > Reset Password > Reset via XML File (or Import/Export Key > Import File) > pick the reply file
      > enter the new password Tab gives you > OK.  Tab saves that password to Bitwarden (WireIt CT > Sites).
  Faster option for installers: HiTools "Reset via QR Code" + Hik-Partner Pro > Online Support Case (needs the HPP login).
  NVRs: resetting an NVR can also reset its connected cameras' passwords in one go (option in the reset dialog).

STEP U - UNIVIEW (bulk "Temporary Password" request)
  U1. Find Cameras already tried admin/123456 once per camera per day.
  U2. Locked ones need the 20-character serial (label, or EZTools 3.0 > Export Device List) and the DEVICE date (the finder reads it).
  U3. Tab fills Uniview's Excel template (Email / Country / Business Type / SN / Device Date) and, after Moshe's OK, uploads it at
      https://oecms.uniview.com/ProductReset/ProductResetImport ("Temporary Password Bulk Reset").
  U4. globalsupport@uniview.com replies (usually within ~2 business hours). The temp password only works on that device date.
  U5. Camera web page (or NVR screen) > Forgot Password > enter the temporary password > set the new password. Tab saves it to Bitwarden.

SAFETY
  - Read-only discovery. The only login attempt is ONE try of Uniview's factory default per camera per day.
  - Firewall rules added by Install (remove with Install-CamReset.ps1 -Uninstall):
    "WireIt CamReset - SADP discovery replies (UDP 37020)", "WireIt CamReset - camera discovery replies (PowerShell, local network)",
    "WireIt CamReset - HiTools Delivery", "WireIt CamReset - HiTools hscan".
    Without them Find Cameras prints: "If Windows asks about the firewall, press Allow - or run Install once as admin so it never asks."
  - Tests (mocks on 127.0.0.x only): powershell -ExecutionPolicy Bypass -File tests\Test-FindCameras.ps1
