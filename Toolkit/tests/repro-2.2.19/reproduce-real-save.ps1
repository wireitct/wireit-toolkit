# Codex 2.2.19 review reproduction reproduce-real-save.ps1 (copied verbatim from the review evidence, Nov 11 2026). Only adaptation: the
# reviewer's output folder '/workspace/review-2219' is $env:REPRO2219_OUT (a fresh temp folder per run). Run by Test-Repro2219.ps1.
param([string]$Repo='/workspace/wireit-toolkit')
$ErrorActionPreference='Continue'
. "$Repo/Toolkit/FixSiteCore.ps1"
. "$Repo/Toolkit/FixSiteDevices.ps1"
$dir=($env:REPRO2219_OUT + '/readonly-journal-dir')
New-Item -ItemType Directory -Force $dir|Out-Null
$path="$dir/state.json"
Remove-Item $path -ErrorAction SilentlyContinue
[IO.File]::WriteAllText("$path.tmp",'temporary file preexists and is writable')
$script:writes=0
$script:FsNetOps=@{
 state={ [pscustomobject]@{dhcp=$false;coexist='disabled';addrs=@([pscustomobject]@{ip='10.0.0.10';prefix=24;skip=$false});gw=@();unread=@()} }
 ident={ [pscustomobject]@{name='Ethernet';guid='guid-a'} }
 free={$true}
 addtemp={$script:writes++;'Preferred'}
}
try{
 & /bin/chmod 555 $dir
 $a=Add-FsTempIp '192.168.99' ([pscustomobject]@{ifIndex=5;name='Ethernet'}) $path
 "REPRO native-journal-move-denied returned=$a adapterWrites=$script:writes journalExists=$(Test-Path $path)"
}finally{ & /bin/chmod 755 $dir }
