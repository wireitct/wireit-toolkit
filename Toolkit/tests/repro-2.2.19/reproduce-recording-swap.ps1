# Codex 2.2.19 review reproduction reproduce-recording-swap.ps1 (copied verbatim from the review evidence, Nov 11 2026). Only adaptation: the
# reviewer's output folder '/workspace/review-2219' is $env:REPRO2219_OUT (a fresh temp folder per run). Run by Test-Repro2219.ps1.
param([string]$Repo='/workspace/wireit-toolkit')
$m=Import-Module "$Repo/Toolkit/modules/NvrHealth/NvrHealth.psm1" -Force -PassThru
& $m {
 Set-NvrHealthOption LogDir ($env:REPRO2219_OUT + '/recording-swap-logs')
 $script:owner='ORIGINAL';$script:writes=@()
 $script:tracks=@{ORIGINAL=@{101='false';201='false'};OTHER=@{101='true';201='false'}}
 function script:TrackXml($id){'<Track><id>'+$id+'</id><Enable>'+$script:tracks[$script:owner][$id]+'</Enable><TrackSchedule><Record>true</Record></TrackSchedule></Track>'}
 function script:Http {
  param($Ip,$Method='GET',$Path,$Body,$ContentType,$Credential,$Headers,$Port,$Scheme,[switch]$NoLogBody,$Timeout,$BodyBytes,$OutFile,[switch]$SecretTransport)
  if($Path -eq '/ISAPI/System/deviceInfo'){return @{code=200;body=('<DeviceInfo><model>NVR</model><serialNumber>'+$script:owner+'</serialNumber><macAddress>'+$(if($script:owner -eq 'ORIGINAL'){'AA:BB:CC:00:00:01'}else{'AA:BB:CC:00:00:99'})+'</macAddress></DeviceInfo>')}}
  if($Method -eq 'PUT'){
   $id=[int]($Path -split '/')[-1];$script:writes+=($script:owner+' track '+$id);$script:tracks[$script:owner][$id]='true'
   if($script:owner -eq 'ORIGINAL'){$script:owner='OTHER'}
   return @{code=200;body='<ResponseStatus><statusCode>1</statusCode></ResponseStatus>'}
  }
  if($Path -eq '/ISAPI/ContentMgmt/record/tracks'){return @{code=200;body=('<TrackList>'+(TrackXml 101)+(TrackXml 201)+'</TrackList>')}}
  if($Path -like '/ISAPI/ContentMgmt/record/tracks/*'){return @{code=200;body=(TrackXml ([int]($Path -split '/')[-1]))}}
  return @{code=404;body=''}
 }
 $c=New-Object PSCredential('admin',(ConvertTo-SecureString 'Review123' -AsPlainText -Force))
 $r=Invoke-NvrFix -Fix recording -Ip '10.0.0.20' -Vendor Hikvision -Credential $c -BackupDir ($env:REPRO2219_OUT + '/recording-swap-backup') -Confirm {'YES'}
 "REPRO recording-recorder-swapped writes=$($script:writes -join ',') originalTrack201=$($script:tracks.ORIGINAL[201]) ok=$($r.ok) msg=$($r.msg)"
}
