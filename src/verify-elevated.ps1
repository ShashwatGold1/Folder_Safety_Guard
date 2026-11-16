# verify-elevated.ps1 — RUN ONLY WHEN ELEVATED. End-to-end real install + security checks + uninstall.
# Proves: SYSTEM becomes owner, user keeps Modify (not Full, so can't change the ACL), deny blocks delete.
$ErrorActionPreference = 'Continue'
$src = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$src\guard-core.ps1"
. "$src\guard-config.ps1"
$root  = "C:\Users\ojhas\Desktop\Folder_Safety_Guard\testing_env"
$folder = Join-Path $root 'owntest'
$user  = "$env:COMPUTERNAME\ojhas"
$pass=0; $fail=0
function Check($n,$c){ if($c){Write-Host "  PASS  $n" -ForegroundColor Green;$script:pass++}else{Write-Host "  FAIL  $n" -ForegroundColor Red;$script:fail++} }

if (-not (Test-GuardAdmin)) { Write-Host "NOT ELEVATED - open an admin terminal first" -ForegroundColor Red; return }
Write-Host "elevated: yes" -ForegroundColor Cyan

# --- part 1: SYSTEM ownership lock on a test folder ---
Write-Host "`n== SYSTEM-ownership lock ==" -ForegroundColor Cyan
Remove-Item $folder -Recurse -Force -EA SilentlyContinue
New-Item -ItemType Directory $folder -Force | Out-Null
Set-Content "$folder\secret.png" 'top'
Set-GuardOwnerSystem -Folder $folder -User $user | Out-Null
Lock-GuardTree -Folder $folder -User $user -Skip @() | Out-Null

$fileAcl = Get-Acl "$folder\secret.png"
Check "folder owner is SYSTEM"  ((Get-Acl $folder).Owner -match 'SYSTEM')
Check "file owner is SYSTEM"    ($fileAcl.Owner -match 'SYSTEM')
$userAces = $fileAcl.Access | Where-Object { $_.IdentityReference -match 'ojhas' }
$hasDenyDelete = $userAces | Where-Object { $_.AccessControlType -eq 'Deny' -and ($_.FileSystemRights.ToString() -match 'Delete') }
Check "user has an explicit Deny-Delete ACE" ($null -ne $hasDenyDelete)
$hasFull = $userAces | Where-Object { $_.AccessControlType -eq 'Allow' -and ($_.FileSystemRights.ToString() -match 'FullControl|ChangePermissions|TakeOwnership') }
Check "user does NOT have ChangePermissions/FullControl (can't alter the lock)" ($null -eq $hasFull)

# --- part 2: real install into Program Files + scheduled task ---
Write-Host "`n== real install ==" -ForegroundColor Cyan
& "$src\install.ps1" -Source $src -NoElevate | Out-Null
Check "guard.ps1 in Program Files" (Test-Path 'C:\Program Files\guard\guard.ps1')
Check "guard.cmd wrapper present"  (Test-Path 'C:\Program Files\guard\guard.cmd')
Check "scheduled task 'guard' exists" ($null -ne (Get-ScheduledTask -TaskName 'guard' -EA SilentlyContinue))
$task = Get-ScheduledTask -TaskName 'guard' -EA SilentlyContinue
Check "task runs as SYSTEM" ($task.Principal.UserId -match 'SYSTEM|S-1-5-18')
$mp = [Environment]::GetEnvironmentVariable('Path','Machine')
Check "Program Files\guard on machine PATH" ($mp -match 'Program Files\\guard')

# --- cleanup: uninstall + restore ownership + remove test folder ---
Write-Host "`n== cleanup ==" -ForegroundColor Cyan
Unregister-ScheduledTask -TaskName 'guard' -Confirm:$false -EA SilentlyContinue
$mp2 = ($mp -split ';' | Where-Object { $_ -notmatch 'Program Files\\guard' }) -join ';'
[Environment]::SetEnvironmentVariable('Path',$mp2,'Machine')
Remove-Item 'C:\Program Files\guard' -Recurse -Force -EA SilentlyContinue
Remove-Item 'C:\ProgramData\guard' -Recurse -Force -EA SilentlyContinue
Unlock-GuardTree -Folder $folder -User $user | Out-Null
Set-GuardOwnerUser -Folder $folder -User $user | Out-Null
icacls $folder /reset /T /C *> $null
Remove-Item $folder -Recurse -Force -EA SilentlyContinue
Check "test folder removed" (-not (Test-Path $folder))
Check "Program Files\guard removed" (-not (Test-Path 'C:\Program Files\guard'))

$color='Green'; if($fail){$color='Red'}
Write-Host "`n$pass passed, $fail failed" -ForegroundColor $color