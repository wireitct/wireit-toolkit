# WireIt Toolkit

Field scripts for WireIt CT techs (Windows PowerShell 5.1): find cameras, check/fix an NVR after an internet change, Hikvision official password-reset helper, network check.

This repository holds scripts only: no passwords, no keys, no customer data. Settings (config.json) stay on each PC.

The Toolkit on a PC reads `version.json` here at start, downloads the listed files from the pinned commit, checks every SHA-256, keeps the previous version for rollback, and runs offline when there is no internet.
