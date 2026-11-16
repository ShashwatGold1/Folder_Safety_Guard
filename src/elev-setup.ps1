# elev-setup.ps1 — RUN ELEVATED. Proves the SYSTEM-ownership lock. Logs to a file.
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\guard-core.ps1"
$log = "C:\Users\ojhas\Desktop\Folder_Safety_Guard\testing_env\elev-setup.log"
$folder = "C:\Users\ojhas\Desktop\Folder_Safety_Guard\testing_env\owntest"
$user = "$env:COMPUTERNAME\ojhas"

"admin: $(Test-GuardAdmin)" | Set-Content $log
if (-not (Test-GuardAdmin)) { "NOT ELEVATED - aborted" | Add-Content $log; exit }

# fresh folder with a file
Remove-Item $folder -Recurse -Force -EA SilentlyContinue
New-Item -ItemType Directory $folder -Force | Out-Null
Set-Content "$folder\secret.png" 'top'

$o = Set-GuardOwnerSystem -Folder $folder -User $user
"setowner ok: $($o.Ok)" | Add-Content $log
$l = Lock-GuardTree -Folder $folder -User $user -Skip @()
"locked files: $($l.Locked)  folderOk: $($l.FolderOk)" | Add-Content $log

# who owns it now
$own = (Get-Acl $folder).Owner
"owner now: $own" | Add-Content $log
$fown = (Get-Acl "$folder\secret.png").Owner
"file owner now: $fown" | Add-Content $log
"SETUP DONE" | Add-Content $log