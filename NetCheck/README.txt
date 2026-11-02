# NetCheck.ps1 - one-click read-only site network check (WireIt CT)

What it does (reads only, changes nothing):
- This PC's NIC: link speed, duplex, error/discard counters; 10-second broadcast/multicast count (loop detector).
- Ping sweep of the /24 (all hosts at once, 10 rounds): replies, loss, min/median/max latency, grouped into bands.
  Devices in the same latency band usually hang off the same switch/uplink.
- ARP table + MAC vendor (Hikvision, Ubiquiti, ...; "locally-administered" = some brands' f2-00-.. cameras).
- Ports 80/443/8000 per host.
- With a login: each Hikvision camera's model, serial, firmware, uptime (recent reboot = power/PoE drop),
  reported link speed/duplex, and WHO is pulling video from it right now (NVR IP, gateway = remote viewer).
  NVR (-Nvr): channel online/offline list. Optional -LogDays N: device log search.
- ONE login attempt per device; a refused login is never retried. Use -Exclude for devices with unknown passwords.

Run (Windows PowerShell 5.1, no installs):
  Set-ExecutionPolicy -Scope Process Bypass -Force   # this window only
  .\NetCheck.ps1                                      # no logins, auto subnet
  .\NetCheck.ps1 -User admin -Nvr 192.168.1.20 -Exclude 192.168.1.92,192.168.1.230
The password is asked for (hidden) - never put it in the script. Output: .\NetCheck-<time>\summary.txt, hosts.csv, raw\.

Reading the summary:
- PC link 10/100 Mbps on a gigabit NIC -> bad cable/jack or the switch port is in a 10 Mbps "Extend" mode.
- Gateway slower than ~5 ms from a wired PC -> congestion or a bad/half-duplex link between this PC and the router.
- Many devices reporting 10 Mbps -> look for a PoE switch with an Extend / CCTV / VLAN DIP switch turned on.
- NVR not answering the PC while cameras stream to it -> PC and NVR are separated (port isolation / VLAN mode).
- Broadcasts > ~200/s -> a loop. Uptimes that all start at the same minute -> that switch lost power then.

Drop into C:\WireIt\NetCheck on the site box. The WireIt Toolkit runs it with button 5 (no logins).
