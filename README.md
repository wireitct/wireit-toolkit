# WireIt Toolkit

Field scripts for WireIt CT techs (Windows PowerShell 5.1): find cameras, check/fix an NVR after an internet change, Hikvision official password-reset helper, network check.

This repository holds scripts only: no passwords, no keys, no customer data. Settings (config.json) stay on each PC.

The Toolkit on a PC reads `version.json` here at start, downloads the listed files from the pinned commit, checks every SHA-256, keeps the previous version for rollback, and runs offline when there is no internet.

## Site Check (remote camera check)

A read-only camera/NVR check for any Windows PC on a site's network (for example over AnyDesk or RustDesk). Nothing to install, it changes nothing.

- Download: https://wireit-toolkit-dl.wireitct.workers.dev/sitecheck/WireIt-SiteCheck.cmd (double-click, press Start check). Same link always gets the newest version.
- v1.1.0: can post the result to the site page. On the site page (with PIN) tap "Get upload code", then type the Site ID and the code into Site Check. Optional: leave both empty and nothing is sent.
- Source: the `sitecheck/` folder of this repo. No passwords or keys are stored in it.
