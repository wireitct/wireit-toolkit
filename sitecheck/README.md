# WireIt Site Check (remote)

Read-only camera/NVR check you run on **any Windows 10/11 PC at the site** (for example over AnyDesk/RustDesk).
No install, no admin rights, nothing left running after you close it. It changes nothing on any device.

## Run it (3 steps)
1. On the site PC, download **WireIt-SiteCheck.cmd**:
   https://wireit-toolkit-dl.wireitct.workers.dev/sitecheck/WireIt-SiteCheck.cmd
   (If the browser asks, choose **Keep**. If Windows shows "Windows protected your PC", click **More info -> Run anyway**.)
2. Double-click it. The "WireIt Site Check" window opens.
3. Type the NVR address and password (optional, but needed to name the offline channels) and press **Start check**.
   About 1 minute later it shows, in big text, which cameras are down and the likely cause.

No-download option (paste into Start -> Run, or a PowerShell window):

    powershell -NoProfile -ExecutionPolicy Bypass -c "[Net.ServicePointManager]::SecurityProtocol='Tls12';&([scriptblock]::Create((irm https://wireit-toolkit-dl.wireitct.workers.dev/sitecheck/main/SiteCheck.ps1)))"

## What it checks
- This PC's network (wired/Wi-Fi only; VPNs and Tailscale are skipped).
- Finds cameras/NVRs: Hikvision SADP, ONVIF WS-Discovery (Dahua, Uniview, others), ping sweep, ARP, ports 80/443/554/8000/37777.
- 20 pings to every device: loss % and latency (median/max).
- IP conflicts (one address answering from two MAC addresses), devices on a different IP scheme than the NVR,
  and devices that answered on the previous run on this PC but not now.
- With the NVR password: the NVR's own channel list (Hikvision ISAPI `/ISAPI/ContentMgmt/InputProxy/channels/status`,
  Dahua `LogicDeviceManager.cgi?action=getCameraState`), so every offline camera is named by channel #, IP and name.
  GET requests only, one login try (no lockout). The password is never saved or logged.

## What the results mean
| What it sees | Likely cause |
|---|---|
| Camera pings fine, NVR gets no video | Camera frozen or settings changed -> reboot it (PoE off 10 s); firmware if it repeats |
| Nothing answers at the camera's IP | No power/link: PoE switch port, cable, switch power, or dead camera |
| 3+ cameras with no power/link at once | One shared switch/PoE switch (or its power/UPS) |
| Pings with loss | Flaky cable/jack/switch port |
| Camera IP behind the NVR's PoE ports | Only the NVR sees it: check that PoE port/cable/camera |
| Two MACs on one IP | IP conflict |
| Different IP scheme | Camera can't be reached by the NVR; re-address it |

## Files it writes
A `SiteCheck-reports` folder next to the .cmd: `SiteCheck-<time>.txt` (readable), `.json` (for the site page), `last-scan.json` (for "missing since last time").
**Copy results** puts the text report on the clipboard.

## Console / tests
    powershell -ExecutionPolicy Bypass -File SiteCheck.ps1 -NoWindow [-Nvr <ip> -AskPassword]
    powershell -ExecutionPolicy Bypass -File SiteCheck.ps1 -SelfTest          # sample report from built-in test data
    powershell -ExecutionPolicy Bypass -File tests\Test-SiteCheck.ps1         # 32 mock tests

Posting results to the WireIt site page is built in but **off** until the site page side is ready.

## Put the result on the site page (v1.1.0)
1. A WireIt tech opens the site page (QR + PIN) -> Cameras -> "Remote check" -> **Get upload code** (6 letters, good 2 hours, 5 uploads).
2. In Site Check type the **Site ID** (e.g. WI-061) and the **upload code**, then press Start check.
3. When it finishes, the status line says "Results posted to the site page." The tech sees it under "Last checks".
Only channel numbers, IPs and states are sent: never the NVR password, user name or camera names. Without the two boxes nothing is sent.
