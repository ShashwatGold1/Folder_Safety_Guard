# elev-clean.ps1 — RUN ELEVATED. Gives ownership back and removes locks so the folder can go.
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\guard-core.ps1"
$log = "C:\Users\ojhas\Desktop\Folder_Safety_Guard\testing_env\elev-clean.log"
$folder = "C:\Users\ojhas\Desktop\Folder_Safety_Guard\testing_env\owntest"
$user = "$env:COMPUTERNAME\ojhas"
"admin: $(Test-GuardAdmin)" | Set-Content $log
Unlock-GuardTree -Folder $folder -User $user | Out-Null
Set-GuardOwnerUser -Folder $folder -User $user | Out-Null
icacls $folder /reset /T /C *> $null
Remove-Item $folder -Recurse -Force -EA SilentlyContinue
"cleaned: $(-not (Test-Path $folder))" | Add-Content $log
"CLEAN DONE" | Add-Content $log