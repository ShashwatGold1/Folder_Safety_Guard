# verify-e2e.ps1 — RUN ELEVATED. The whole life of guard on this PC, for real:
# install (Program Files + SYSTEM task) -> init x2 -> background guard locks new files/folders ->
# limited-process attacks -> edit/resume -> skip -> delete -> move folder -> help/typos ->
# update to a newer version -> uninstall -> reinstall restores from _guard.json -> uninstall.
$ErrorActionPreference = 'Continue'
$src    = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo   = Split-Path $src -Parent
$prefix = 'C:\Program Files\guard'
$root   = Join-Path $repo 'testing_env\e2e'
$A      = Join-Path $root 'Alpha'
$B      = Join-Path $root 'Beta'
$pass=0; $fail=0
function Check($n,$c){ if($c){Write-Host "  PASS  $n" -ForegroundColor Green;$script:pass++}else{Write-Host "  FAIL  $n" -ForegroundColor Red;$script:fail++} }
function Section($t){ Write-Host "`n== $t ==" -ForegroundColor Cyan }
function WaitFor([scriptblock]$c, [int]$sec = 15) { for ($i=0; $i -lt $sec*4; $i++) { if (& $c) { return $true }; Start-Sleep -Milliseconds 250 }; return $false }
function IsLocked($p) {
    $a = Get-Acl -LiteralPath $p
    return [bool]($a.Access | Where-Object { $_.AccessControlType -eq 'Deny' -and $_.IdentityReference -match 'ojhas' -and $_.FileSystemRights.ToString() -match 'Delete' })
}
function OwnerOf($p) { (Get-Acl -LiteralPath $p).Owner }
function Out-Of([string]$cmd) { (Invoke-GuardCommand $cmd 6>&1 | Out-String) }
function Watchers { @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*guard-watch.ps1*' }) }
# (installed code is dot-sourced at script level below: inside a function it would vanish on return)

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Write-Host 'NOT ELEVATED' -ForegroundColor Red; return }
$user = $id.Name

function Attack([string]$folder, [string]$target, [string]$tag) {
    $log = Join-Path $env:TEMP "guard-attack-$tag.log"
    Remove-Item $log -Force -EA SilentlyContinue
    $arg = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$src\attack-limited.ps1`" -Folder `"$folder`" -Log `"$log`" -Target `"$target`""
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $pr  = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName 'guard-attack-test' -Action $act -Principal $pr -Force | Out-Null
    Start-ScheduledTask -TaskName 'guard-attack-test'
    WaitFor { (Test-Path $log) -and ((Get-Content $log -Raw) -match 'DONE') } 40 | Out-Null
    Unregister-ScheduledTask -TaskName 'guard-attack-test' -Confirm:$false -EA SilentlyContinue
    $r = @('NO LOG'); if (Test-Path $log) { $r = Get-Content $log }
    $r | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
    return $r
}

# ---------------------------------------------------------------------------
Section 'clean start'
if (Test-Path $prefix) { Write-Host '  guard is already installed here - uninstall it first' -ForegroundColor Red; return }
Check 'no stray background guard before start' (@(Watchers).Count -eq 0)
Watchers | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }
Remove-Item "$env:ProgramData\guard" -Recurse -Force -EA SilentlyContinue
if (Test-Path $root) { icacls $root /reset /T /C *> $null; Remove-Item $root -Recurse -Force -EA SilentlyContinue }
icacls (Join-Path $repo 'testing_env') /reset *> $null
$stray = @(Get-ChildItem (Join-Path $repo 'testing_env') -Filter _guard.json -Recurse -Force -EA SilentlyContinue)
Check 'no leftover _guard.json in testing_env' ($stray.Count -eq 0)
New-Item -ItemType Directory "$A\sub" -Force | Out-Null
New-Item -ItemType Directory $B -Force | Out-Null
'a1' | Set-Content "$A\amazon-checkout.png"; 'a2' | Set-Content "$A\godaddy-dns.png"; 'a3' | Set-Content "$A\sub\inner.png"
'b1' | Set-Content "$B\tax-2025.pdf"; 'b2' | Set-Content "$B\invoice.pdf"

# ---------------------------------------------------------------------------
Section 'install (real: Program Files + SYSTEM task)'
$o = & "$repo\install.ps1" -Source $src -NoElevate 6>&1 | Out-String
Write-Host $o -ForegroundColor DarkGray
Check 'installed successfully' ($o -match 'installed successfully')
Check 'all 5 modules + guard.cmd in Program Files' ((@('guard.ps1','guard-shell.ps1','guard-core.ps1','guard-config.ps1','guard-watch.ps1','guard.cmd') | Where-Object { -not (Test-Path "$prefix\$_") }).Count -eq 0)
Check 'no test files installed' (-not (Test-Path "$prefix\test-core.ps1") -and -not (Test-Path "$prefix\attack-limited.ps1"))
$t = Get-ScheduledTask -TaskName guard -EA SilentlyContinue
Check 'task "guard" runs as SYSTEM at logon' ($t -and $t.Principal.UserId -match 'SYSTEM' -and $t.Triggers[0].CimClass.CimClassName -match 'Logon')
Check 'PATH has Program Files\guard' (([Environment]::GetEnvironmentVariable('Path','Machine') -split ';') -contains $prefix)
Check 'background guard started' (WaitFor { @(Watchers).Count -ge 1 } 15)
$w = Watchers | Select-Object -First 1
Check 'background guard runs as SYSTEM' ($w -and ((Invoke-CimMethod -InputObject $w -MethodName GetOwner).User -eq 'SYSTEM'))
Check 'exactly one background guard' (@(Watchers).Count -eq 1)
Check 'heartbeat written' (WaitFor { Test-Path "$env:ProgramData\guard\watch-status.json" } 15)

# ---------------------------------------------------------------------------
Section 'init two folders (installed code)'
. "$prefix\guard-shell.ps1"; $ErrorActionPreference = 'Continue'; $script:User = Get-GuardUser; $script:Cfg = Load-GuardConfig
Check 'status says running' ((Get-WatchState).Text -eq 'running')
$o = Out-Of "init $A"; Write-Host $o -ForegroundColor DarkGray
Check 'init A: success line' ($o -match 'Alpha folder is successfully protected')
$o = Out-Of "init $B"
Check 'init B: success line' ($o -match 'Beta folder is successfully protected')
Check 'config.json lists 2 folders' (@((Get-Content "$env:ProgramData\guard\config.json" -Raw | ConvertFrom-Json).folders).Count -eq 2)
Check 'A: owner SYSTEM, file owner SYSTEM' ((OwnerOf $A) -match 'SYSTEM' -and (OwnerOf "$A\amazon-checkout.png") -match 'SYSTEM')
Check 'A: subfolder locked + owned by SYSTEM' ((IsLocked "$A\sub") -and (OwnerOf "$A\sub") -match 'SYSTEM')
Check 'A: file in subfolder locked' (IsLocked "$A\sub\inner.png")
Check 'both _guard.json hidden + locked' ((IsLocked "$A\_guard.json") -and (IsLocked "$B\_guard.json") -and ((Get-Item "$A\_guard.json" -Force).Attributes -match 'Hidden'))
Check 'init again: already protected' ((Out-Of "init $A") -match 'already protected')
Check 'status block renders' ((Show-Status 6>&1 | Out-String) -match 'Beta')

# ---------------------------------------------------------------------------
Section 'background guard (SYSTEM) locks new things'
'new' | Set-Content "$A\screenshot-new.png"
Check 'new file locked within 10 s' (WaitFor { IsLocked "$A\screenshot-new.png" } 10)
Check '... and owned by SYSTEM' ((OwnerOf "$A\screenshot-new.png") -match 'SYSTEM')
New-Item -ItemType Directory "$A\later" -Force | Out-Null; 'x' | Set-Content "$A\later\deep.png"
Check 'new subfolder locked within 10 s' (WaitFor { IsLocked "$A\later" } 10)
Check 'file inside new subfolder locked' (WaitFor { IsLocked "$A\later\deep.png" } 10)
'part' | Set-Content "$A\download.crdownload"
Start-Sleep 3
Check '.crdownload left alone (Chrome can rename it)' (-not (IsLocked "$A\download.crdownload"))
Rename-Item "$A\download.crdownload" 'download.png'
Check 'finished download locked' (WaitFor { IsLocked "$A\download.png" } 10)

# ---------------------------------------------------------------------------
Section 'attack from a limited process (what an AI agent in a normal terminal has)'
$r = Attack $A 'amazon-checkout.png' 'a1'
Check 'attacker had no admin' ($r -contains 'admin: False')
Check 'every attack blocked (file, folder, ACL, owner, subfolder)' (-not ($r -match 'SUCCEEDED') -and ($r -match 'subfolder').Count -ge 3)
Check 'read + add still work' (($r -contains 'read file: ok') -and ($r -contains 'add new file: ok'))
Check 'attacker''s own new file locked by SYSTEM guard' (WaitFor { IsLocked "$A\agent-new.png" } 10)
$r = Attack $A 'agent-new.png' 'a2'
Check 'attacks on its own file blocked' (-not ($r -match 'SUCCEEDED'))
Check 'nothing lost in A' ((Test-Path "$A\amazon-checkout.png") -and (Test-Path "$A\sub\inner.png") -and (Test-Path "$A\agent-new.png"))

# ---------------------------------------------------------------------------
Section 'edit / resume'
Invoke-GuardCommand 'use 1' 6>&1 | Out-Null
Invoke-GuardCommand 'edit' 6>&1 | Out-Null
Check 'edit: file no longer locked' (-not (IsLocked "$A\godaddy-dns.png"))
Check 'edit A keeps the folder-above rule Beta still needs' (IsLocked $root)
'while editing' | Set-Content "$A\draft.png"
Start-Sleep 5
Check 'background guard leaves an edited folder alone' (-not (IsLocked "$A\draft.png"))
Check 'status shows UNLOCKED' ((Show-Status 6>&1 | Out-String) -match 'UNLOCKED')
Invoke-GuardCommand 'resume' 6>&1 | Out-Null
Check 'resume: draft locked' (IsLocked "$A\draft.png")
'after resume' | Set-Content "$A\after.png"
Check 'background guard locks again after resume' (WaitFor { IsLocked "$A\after.png" } 10)
Invoke-GuardCommand 'edit all' 6>&1 | Out-Null
Check 'edit all: both folders unlocked' (-not (IsLocked "$A\after.png") -and -not (IsLocked "$B\invoice.pdf"))
Invoke-GuardCommand 'resume all' 6>&1 | Out-Null
Check 'resume all: both locked' ((IsLocked "$A\after.png") -and (IsLocked "$B\invoice.pdf"))

# ---------------------------------------------------------------------------
Section 'skip'
Invoke-GuardCommand 'skip *.bak' 6>&1 | Out-Null
'b' | Set-Content "$A\notes.bak"
Start-Sleep 4
Check 'skip *.bak: new .bak not locked' (-not (IsLocked "$A\notes.bak"))
Check 'skip list shows it' ((Out-Of 'skip') -match '\*\.bak')
Invoke-GuardCommand 'skip remove *.bak' 6>&1 | Out-Null
Check 'skip remove: gone from list' (-not ((Out-Of 'skip') -match 'yours\s+\*\.bak'))

# ---------------------------------------------------------------------------
Section 'delete inside a protected folder'
$script:InputQueue = New-Object System.Collections.Queue; $script:InputQueue.Enqueue('1')
Invoke-GuardCommand 'delete godaddy' 6>&1 | Out-Null
Check 'delete godaddy: gone' (-not (Test-Path "$A\godaddy-dns.png"))
$script:InputQueue = New-Object System.Collections.Queue; $script:InputQueue.Enqueue('2')
Invoke-GuardCommand 'delete amazon' 6>&1 | Out-Null
Check 'answer no: kept' (Test-Path "$A\amazon-checkout.png")
$o = Out-Of 'delete zzzz'
Check 'no match: says so' ($o -match 'no file matches')

# ---------------------------------------------------------------------------
Section 'move folder'
Invoke-GuardCommand 'use 2' 6>&1 | Out-Null
$B2 = Join-Path $root 'Beta-moved'
$script:InputQueue = New-Object System.Collections.Queue; $script:InputQueue.Enqueue($B2)
$o = Out-Of 'move folder'; Write-Host $o -ForegroundColor DarkGray
Check 'moved on disk' ((Test-Path "$B2\invoice.pdf") -and -not (Test-Path $B))
Check 'still locked at new path' ((IsLocked "$B2\invoice.pdf") -and (IsLocked $B2))
Check 'config has new path' (@((Get-Content "$env:ProgramData\guard\config.json" -Raw | ConvertFrom-Json).folders | Where-Object { $_.path -eq $B2 }).Count -eq 1)
Check '_guard.json travelled' (Test-Path "$B2\_guard.json")
'n' | Set-Content "$B2\new-after-move.pdf"
Check 'background guard watches the new path' (WaitFor { IsLocked "$B2\new-after-move.pdf" } 12)

# ---------------------------------------------------------------------------
Section 'help, typos, cls'
Check 'help edit: long text' ((Out-Of 'help edit') -match 'If you forget, the next')
Check 'help all: every command' (((Out-Of 'help all') -match 'uninstall') -and ((Out-Of 'help all') -match 'skip'))
Check 'help nosuch: says no command' ((Out-Of 'help dleete') -match 'did you mean  delete')
Check 'typo: did you mean' ((Out-Of 'delet amazon') -match 'did you mean  delete')
Check 'help (plain) = command table' ((Out-Of 'help') -match 'Current folder')
Check 'list: shows files' ((Out-Of 'list') -match 'invoice.pdf')

# ---------------------------------------------------------------------------
Section 'update line + update to a newer version'
$fake = Join-Path $env:TEMP ('guard-fake-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory "$fake\src" -Force | Out-Null
foreach ($f in 'guard.ps1','guard-shell.ps1','guard-core.ps1','guard-config.ps1','guard-watch.ps1') { Copy-Item "$src\$f" "$fake\src\$f" }
Copy-Item "$repo\install.ps1" "$fake\install.ps1"
$core = (Get-Content "$fake\src\guard-core.ps1" -Raw -Encoding UTF8) -replace "GuardVersion = '1\.0'", "GuardVersion = '1.1'"
[IO.File]::WriteAllText("$fake\src\guard-core.ps1", $core, (New-Object Text.UTF8Encoding($true)))
$env:GUARD_SOURCE = "$fake\src"
Check 'sees newer version 1.1' ((Get-GuardRemoteVersion) -eq '1.1')
# pretend the background guard's 6-hourly check just saw 1.1 (it rewrites the file every 30 s, so retry)
$seen = WaitFor {
    $st = Read-WatchStatus
    if ($st) { $st.latest = '1.1'; $st.alive = (Get-Date).ToString('o'); try { $st | ConvertTo-Json | Set-Content "$env:ProgramData\guard\watch-status.json" -EA Stop } catch { } }
    (Show-Status 6>&1 | Out-String) -match 'New version is available'
} 10
Check 'yellow update line appears' $seen
$before = (Watchers | Select-Object -First 1).ProcessId
$o = Out-Of 'update'; Write-Host $o -ForegroundColor DarkGray
Check 'updated successfully' ($o -match 'updated successfully')
Check 'installed core is 1.1' ((Get-Content "$prefix\guard-core.ps1" -Raw) -match "GuardVersion = '1\.1'")
Check 'background guard restarted (new process, still one)' (WaitFor { $ws = @(Watchers); $ws.Count -eq 1 -and $ws[0].ProcessId -ne $before } 20)
Check 'folders untouched by update' ((IsLocked "$A\amazon-checkout.png") -and (IsLocked "$B2\invoice.pdf"))
. "$prefix\guard-shell.ps1"; $ErrorActionPreference = 'Continue'; $script:User = Get-GuardUser; $script:Cfg = Load-GuardConfig
Check 'already newest: says so' ((Out-Of 'update') -match 'newest version \(1\.1\)')
$env:GUARD_SOURCE = ''
Check 'GitHub unreachable/missing: update says so, no crash' (((Out-Of 'update') -match "can't reach GitHub|newest version"))

# ---------------------------------------------------------------------------
Section 'uninstall'
$script:InputQueue = New-Object System.Collections.Queue; $script:InputQueue.Enqueue('no')
Check 'uninstall: anything but YES cancels' (((Out-Of 'uninstall') -match 'cancelled') -and (Test-Path $prefix))
$script:InputQueue = New-Object System.Collections.Queue; $script:InputQueue.Enqueue('YES')
$o = Out-Of 'uninstall'; Write-Host $o -ForegroundColor DarkGray
Check 'done. bye.' ($o -match 'done\. bye\.')
Check 'background guard stopped' (WaitFor { @(Watchers).Count -eq 0 } 15)
Check 'task removed' ($null -eq (Get-ScheduledTask -TaskName guard -EA SilentlyContinue))
Check 'Program Files\guard removed' (-not (Test-Path $prefix))
Check 'ProgramData\guard removed' (-not (Test-Path "$env:ProgramData\guard"))
Check 'PATH entry removed' (-not (([Environment]::GetEnvironmentVariable('Path','Machine') -split ';') -contains $prefix))
Check 'folders owned by you again' ((OwnerOf $A) -match 'ojhas' -and (OwnerOf "$A\amazon-checkout.png") -match 'ojhas' -and (OwnerOf "$B2\invoice.pdf") -match 'ojhas')
Check 'no lock left' (-not (IsLocked "$A\amazon-checkout.png") -and -not (IsLocked "$A\sub") -and -not (IsLocked $A))
Check '_guard.json kept as memory' ((Test-Path "$A\_guard.json") -and (Test-Path "$B2\_guard.json"))

# ---------------------------------------------------------------------------
Section 'reinstall finds the memory and restores'
$env:GUARD_ANSWERS = '1'
$o = & "$repo\install.ps1" -Source $src -NoElevate 6>&1 | Out-String
$env:GUARD_ANSWERS = ''
Write-Host $o -ForegroundColor DarkGray
Check 'installer found the memory' ($o -match 'memory\s+found in')
Check 'restore: 2 folders protected' ($o -match '2 folders are successfully protected')
Check 'restored: locked + SYSTEM again' ((IsLocked "$A\amazon-checkout.png") -and (IsLocked "$B2\invoice.pdf") -and (OwnerOf $A) -match 'SYSTEM')
Check 'config.json rebuilt with 2 folders' (@((Get-Content "$env:ProgramData\guard\config.json" -Raw | ConvertFrom-Json).folders).Count -eq 2)
$r = Attack $A 'amazon-checkout.png' 'a3'
Check 'after restore, attacks still blocked' (-not ($r -match 'SUCCEEDED') -and ($r -contains 'admin: False'))

# ---------------------------------------------------------------------------
Section 'remove all + final uninstall (leaves the PC clean)'
. "$prefix\guard-shell.ps1"; $ErrorActionPreference = 'Continue'; $script:User = Get-GuardUser; $script:Cfg = Load-GuardConfig
$script:InputQueue = New-Object System.Collections.Queue; $script:InputQueue.Enqueue('YES')
Invoke-GuardCommand 'remove all' 6>&1 | Out-Null
Check 'remove all: no folders left' ($script:Cfg.folders.Count -eq 0)
Check 'remove all: _guard.json deleted' (-not (Test-Path "$A\_guard.json") -and -not (Test-Path "$B2\_guard.json"))
$script:InputQueue = New-Object System.Collections.Queue; $script:InputQueue.Enqueue('YES')
Invoke-GuardCommand 'uninstall' 6>&1 | Out-Null
Check 'uninstalled again' (-not (Test-Path $prefix) -and $null -eq (Get-ScheduledTask -TaskName guard -EA SilentlyContinue))
$canDel = $true; try { Remove-Item $root -Recurse -Force -ErrorAction Stop } catch { $canDel = $false }
Check 'test folders delete normally' ($canDel -and -not (Test-Path $root))
Check 'testing_env has no deny left' (-not (IsLocked (Join-Path $repo 'testing_env')))
Check 'no background guard left running' (@(Watchers).Count -eq 0)
Check 'ProgramData\guard gone' (-not (Test-Path "$env:ProgramData\guard"))
Remove-Item $fake -Recurse -Force -EA SilentlyContinue

$color='Green'; if($fail){$color='Red'}
Write-Host "`n$pass passed, $fail failed" -ForegroundColor $color
