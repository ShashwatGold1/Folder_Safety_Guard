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

$envKey = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
function Set-TestFlag([bool]$on) {
    $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($envKey, $true)
    if ($on) { $k.SetValue('GUARD_TEST', '1') } else { $k.DeleteValue('GUARD_TEST', $false) }
    $k.Close()
}
function Raw-Path { $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($envKey); try { [string]$k.GetValue('Path','',[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } finally { $k.Close() } }
function Path-Kind { $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($envKey); try { $k.GetValueKind('Path') } finally { $k.Close() } }

# ---------------------------------------------------------------------------
Section 'an agent''s user env vars are ignored by elevated guard (review finding 1)'
Set-TestFlag $false
$probe = Join-Path $env:TEMP 'guard-probe.ps1'
@"
. '$src\guard-core.ps1'; . '$src\guard-config.ps1'; . '$src\guard-shell.ps1'
`$ErrorActionPreference = 'Continue'
'config=' + `$script:GuardConfigPath
'source=' + [string](Get-GuardTestEnv 'GUARD_SOURCE')
'answers=' + [string](Get-GuardTestEnv 'GUARD_ANSWERS')
'task=' + `$script:GuardTask
'relkey=' + (Get-GuardReleaseKey)
'relurl=' + (Get-GuardReleaseBase)
"@ | Set-Content $probe -Encoding UTF8
$env:GUARD_CONFIG = 'C:\evil\config.json'; $env:GUARD_SOURCE = 'C:\evil'; $env:GUARD_ANSWERS = 'YES'; $env:GUARD_TASK = 'evil'
$env:GUARD_RELEASE_KEY = 'EVILKEY'; $env:GUARD_RELEASE_URL = 'file:///C:/evil'
$o = powershell -NoProfile -ExecutionPolicy Bypass -File $probe 2>&1 | Out-String
$env:GUARD_CONFIG = ''; $env:GUARD_SOURCE = ''; $env:GUARD_ANSWERS = ''; $env:GUARD_TASK = ''; $env:GUARD_RELEASE_KEY = ''; $env:GUARD_RELEASE_URL = ''
Check 'GUARD_RELEASE_KEY ignored (an agent can not pick the release key)' ($o -notmatch 'EVILKEY')
Check 'GUARD_RELEASE_URL ignored' ($o -match 'relurl=https://raw\.githubusercontent\.com/')
Remove-Item $probe -Force
Check 'GUARD_CONFIG ignored' ($o -match [regex]::Escape("config=$env:ProgramData\guard\config.json"))
Check 'GUARD_SOURCE ignored' ($o -match 'source=\r?\n')
Check 'GUARD_ANSWERS ignored' ($o -match 'answers=\r?\n')
Check 'GUARD_TASK ignored' ($o -match 'task=guard')
Set-TestFlag $true   # this test itself needs GUARD_SOURCE / GUARD_ANSWERS; removed at the end
$env:GUARD_NOBROWSER = '1'   # edit must not open Explorer windows during the test

Section 'icacls errors come back as a result, never throw (review finding 9)'
. "$src\guard-core.ps1"; $ErrorActionPreference = 'Continue'
$threw = $false
try { $ErrorActionPreference = 'Stop'; $x = Invoke-Icacls @('C:\definitely-not-here', '/deny', 'Everyone:(DE)') } catch { $threw = $true } finally { $ErrorActionPreference = 'Continue' }
Check 'missing path: no exception, Ok = false' ((-not $threw) -and $x -and -not $x.Ok)

Section 'signed releases: a test key and a fake GitHub (file://) for install and update'
. "$src\guard-sign.ps1" -Lib; $ErrorActionPreference = 'Continue'
$relRoot = Join-Path $env:TEMP ('guard-e2e-rel-' + [guid]::NewGuid().ToString('N'))
$relRsa = New-Object Security.Cryptography.RSACng 2048
$relSign = { param([byte[]]$d) $relRsa.SignData($d, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1) }
$env:GUARD_RELEASE_KEY = [Convert]::ToBase64String($relRsa.ExportParameters($false).Modulus)
function Repo-Files { $h = @{}; foreach ($f in Get-GuardReleaseFiles) { $h[$f] = [IO.File]::ReadAllBytes((Join-Path $repo $f)) }; return $h }
function Publish([string]$Name, $Files, [string]$Ver, [string]$Commit) {
    $d = Join-Path $relRoot $Name; New-GuardReleaseFolder $d $Commit $Files $Ver $relSign
    $env:GUARD_RELEASE_URL = ([Uri]$d).AbsoluteUri; return $d
}
$c10 = ('10' * 20); [void](Publish 'v10' (Repo-Files) '1.0' $c10)
Check 'signed 1.0 release is visible' ((Get-GuardRemoteVersion) -eq '1.0')

Section 'the real TPM: a throwaway release key with a PIN (right PIN only: no lockout count)'
$tk = 'guard-release-e2e-' + [guid]::NewGuid().ToString('N').Substring(0, 6); $tpin = 'e2e test pin ' + [guid]::NewGuid().ToString('N').Substring(0, 8)
try {
    $tm = New-ReleaseKey $tk $tpin
    $tj = [Text.Encoding]::UTF8.GetBytes('{"name":"guard"}')
    $ts = Invoke-TpmSign $tk $tpin $tj
    Check 'TPM key: made as a machine key, 2048 bit' ((Test-ReleaseKeyExists $tk) -and ([Convert]::FromBase64String($tm).Length -eq 256))
    Check 'TPM key: its signature checks with its public half' (Test-GuardReleaseSig $tj $ts $tm)
    Check 'TPM key: the public half read back is the same' ((Get-TpmReleaseModulus $tk) -eq $tm)
    $k = [Security.Cryptography.CngKey]::Open($tk, (Get-SignProvider), (Get-SignOpenFlags)); $ex = $false
    try { [void]$k.Export([Security.Cryptography.CngKeyBlobFormat]::GenericPrivateBlob); $ex = $true } catch { } finally { $k.Dispose() }
    Check 'TPM key: the private half can not be copied out' (-not $ex)
} catch { Check ('TPM key test ran: ' + $_.Exception.Message) $false }
finally { try { Remove-ReleaseKey $tk } catch { } }
Check 'TPM key: deleted again' (-not (Test-ReleaseKeyExists $tk))

$rawBefore = Raw-Path

Section 'install.ps1 survives  irm | iex'
$bytes = [IO.File]::ReadAllBytes("$repo\install.ps1")
Check 'install.ps1 has no BOM' (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF))
Check 'install.ps1 is pure ASCII' (-not ($bytes | Where-Object { $_ -gt 127 } | Select-Object -First 1))
$sbText = [Text.Encoding]::UTF8.GetString($bytes)   # what irm hands to iex
$sb = $null; try { $sb = [scriptblock]::Create($sbText) } catch { }
Check 'parses as a script block with its param block' ($sb -and $sb.Ast.ParamBlock)

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
'a4' | Set-Content "$A\amazon-2.png"; 'a5' | Set-Content "$A\amazon-3.png"
'ro' | Set-Content "$A\readonly.png"; (Get-Item "$A\readonly.png").IsReadOnly = $true
New-Item -ItemType Directory "$A\pics", "$A\old" -Force | Out-Null
'p1' | Set-Content "$A\pics\p1.png"; 'p2' | Set-Content "$A\pics\p2.png"; 'o' | Set-Content "$A\old\o.png"
'b1' | Set-Content "$B\tax-2025.pdf"; 'b2' | Set-Content "$B\invoice.pdf"

# ---------------------------------------------------------------------------
Section 'install (real: Program Files + SYSTEM task)'
# no -Source: the files come from the signed (fake) release, hash-checked, like from GitHub
$o = & "$repo\install.ps1" -NoElevate 6>&1 | Out-String
Write-Host $o -ForegroundColor DarkGray
Check 'Guard is Installed Successfully.' ($o -cmatch 'Guard is Installed Successfully\.')
Check 'all 9 modules + guard.cmd in Program Files' ((@('guard.ps1','guard-shell.ps1','guard-core.ps1','guard-config.ps1','guard-watch.ps1','guard-badges.ps1','guard-sign.ps1','guard-check.ps1','guard-vault.ps1','guard.cmd') | Where-Object { -not (Test-Path "$prefix\$_") }).Count -eq 0)
Check 'no test files installed' (-not (Test-Path "$prefix\test-core.ps1") -and -not (Test-Path "$prefix\attack-limited.ps1"))
# (not $b: names ignore case, $b would overwrite $B, the Beta folder)
$dbl = @(Get-ChildItem "$prefix\*.ps1" | Where-Object { $fb = [IO.File]::ReadAllBytes($_.FullName); -not ($fb[0] -eq 0xEF -and $fb[1] -eq 0xBB -and $fb[2] -eq 0xBF) -or ($fb[3] -eq 0xEF -and $fb[4] -eq 0xBB -and $fb[5] -eq 0xBF) })
Check 'installed files: exactly one BOM each' ($dbl.Count -eq 0)
$t = Get-ScheduledTask -TaskName guard -EA SilentlyContinue
Check 'task "guard" runs as SYSTEM at logon' ($t -and $t.Principal.UserId -match 'SYSTEM' -and $t.Triggers[0].CimClass.CimClassName -match 'Logon')
Check 'PATH has Program Files\guard' ((Raw-Path) -split ';' -contains $prefix)
Check 'C:\Windows\guard.cmd starts this install' ((Get-Content "$env:SystemRoot\guard.cmd" -Raw) -like "*`"$prefix\guard.ps1`"*")
# an already-open terminal: its PATH is from before the install, guard still resolves
$found = & cmd.exe /c "set PATH=$env:SystemRoot\system32;$env:SystemRoot&& where guard" 2>$null
Check 'guard found in a terminal opened before the install' (@($found) -contains "$env:SystemRoot\guard.cmd")
Check 'install ends with  type:  guard' ($o -match 'type:\s+guard' -and -not ($o -match 'open a new terminal'))
Check 'PATH kept as REG_EXPAND_SZ, nothing else changed (review finding 10)' (((Path-Kind) -eq 'ExpandString') -and ((Raw-Path) -eq ($rawBefore.TrimEnd(';') + ';' + $prefix)))
Check 'background guard started' (WaitFor { @(Watchers).Count -ge 1 } 15)
$w = Watchers | Select-Object -First 1
Check 'background guard runs as SYSTEM' ($w -and ((Invoke-CimMethod -InputObject $w -MethodName GetOwner).User -eq 'SYSTEM'))
Check 'exactly one background guard' (@(Watchers).Count -eq 1)
Check 'heartbeat written' (WaitFor { Test-Path "$env:ProgramData\guard\watch-status.json" } 15)

# ---------------------------------------------------------------------------
Section 'init two folders (installed code)'
. "$prefix\guard-shell.ps1"; $ErrorActionPreference = 'Continue'; $script:User = Get-GuardUser; $script:Cfg = Load-GuardConfig
Check 'status says running' ((Get-WatchState).Text -eq 'running')
'part' | Set-Content "$A\cloud-only.png"; $cf = Get-Item "$A\cloud-only.png"; $cf.Attributes = $cf.Attributes -bor [IO.FileAttributes]::Offline
Check 'cloud-only file: init refuses' ((Out-Of "init $A") -match 'only in the cloud')
$cf.Attributes = 'Normal'; Remove-Item "$A\cloud-only.png" -Force
$o = Out-Of "init $A"; Write-Host $o -ForegroundColor DarkGray
Check 'init A: success line' ($o -cmatch 'Folder is Protected Successfully\.')
$o = Out-Of "init $B"
Check 'init B: success line' ($o -cmatch 'Folder is Protected Successfully\.')
Check 'config.json lists 2 folders' (@((Get-Content "$env:ProgramData\guard\config.json" -Raw | ConvertFrom-Json).folders).Count -eq 2)
Check 'A: owner SYSTEM, file owner SYSTEM' ((OwnerOf $A) -match 'SYSTEM' -and (OwnerOf "$A\amazon-checkout.png") -match 'SYSTEM')
Check 'A: subfolder locked + owned by SYSTEM' ((IsLocked "$A\sub") -and (OwnerOf "$A\sub") -match 'SYSTEM')
Check 'A: file in subfolder locked' (IsLocked "$A\sub\inner.png")
Check 'both _guard.json hidden + locked' ((IsLocked "$A\_guard.json") -and (IsLocked "$B\_guard.json") -and ((Get-Item "$A\_guard.json" -Force).Attributes -match 'Hidden'))
Check 'init again: already protected' ((Out-Of "init $A") -match 'already protected')
Check 'read-only file locked too (review finding 5)' (IsLocked "$A\readonly.png")
Check 'nested: init inside a protected folder refused (finding 4)' ((Out-Of "init $A\sub") -match 'already protected as part of')
Check 'nested: init of a folder holding one refused' ((Out-Of "init $root") -match 'holds the protected folder')
Check 'drive root refused' ((Out-Of 'init C:\') -match "whole drive")
Check 'Windows folder refused' ((Out-Of "init $env:SystemRoot\Temp") -match "can't be protected")
Check 'still exactly 2 folders' ($script:Cfg.folders.Count -eq 2)
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
$o = Out-Of 'edit todo'
Check 'edit <unknown word>: unlocks nothing, says how' (($o -match 'nothing was unlocked') -and (IsLocked "$A\godaddy-dns.png") -and (IsLocked $A))
Invoke-GuardCommand 'edit' 6>&1 | Out-Null
Check 'edit: file no longer locked' (-not (IsLocked "$A\godaddy-dns.png"))
Check 'edit A keeps the folder-above rule Beta still needs' (IsLocked $root)
'while editing' | Set-Content "$A\draft.png"
Start-Sleep 5
Check 'background guard leaves an edited folder alone' (-not (IsLocked "$A\draft.png"))
$st = Show-Status 6>&1 | Out-String
Check 'status shows UNLOCKED, editing' (($st -match 'UNLOCKED\s+editing') -and ($st -match 'not locking new files while editing') -and ($st -match 'next\s+resume  when done'))
$o = Out-Of 'resume'
Check 'resume says what changed' ($o -match 'full check\s+\d+ files found \(1 added while editing\)')
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
Invoke-GuardCommand 'skip *.log' 6>&1 | Out-Null
$sk = @($script:Cfg.folders[0].skip)
Check 'two skip patterns stay separate (review finding 8)' (($sk.Count -eq 2) -and ($sk -contains '*.bak') -and ($sk -contains '*.log'))
'l' | Set-Content "$A\run.log"; 'b2' | Set-Content "$A\more.bak"
Start-Sleep 4
Check 'both patterns work' (-not (IsLocked "$A\run.log") -and -not (IsLocked "$A\more.bak"))
Invoke-GuardCommand 'skip remove *.bak' 6>&1 | Out-Null
Check 'skip remove: only that one gone' ((@($script:Cfg.folders[0].skip) -join ',') -eq '*.log')
Invoke-GuardCommand 'skip remove *.log' 6>&1 | Out-Null

# ---------------------------------------------------------------------------
Section 'delete inside a protected folder'
$script:InputQueue = New-Object System.Collections.Queue; $script:InputQueue.Enqueue('1')
Invoke-GuardCommand 'delete godaddy' 6>&1 | Out-Null
Check 'delete godaddy: gone' (-not (Test-Path "$A\godaddy-dns.png"))
# picker: 3 matches (amazon-2, amazon-3, amazon-checkout), pick number 2 then yes (review finding 7)
$script:InputQueue = New-Object System.Collections.Queue; $script:InputQueue.Enqueue('2'); $script:InputQueue.Enqueue('1')
Invoke-GuardCommand 'delete amazon' 6>&1 | Out-Null
Check 'picker: number 2 deleted exactly amazon-3' (-not (Test-Path "$A\amazon-3.png") -and (Test-Path "$A\amazon-2.png") -and (Test-Path "$A\amazon-checkout.png"))
$script:InputQueue = New-Object System.Collections.Queue; $script:InputQueue.Enqueue('2')
Invoke-GuardCommand 'delete checkout' 6>&1 | Out-Null
Check 'answer no: kept' (Test-Path "$A\amazon-checkout.png")
# a delete that fails must not leave the file unlocked (review finding 6)
$h = [IO.File]::Open("$A\amazon-2.png", 'Open', 'Read', 'None')
$script:InputQueue = New-Object System.Collections.Queue; $script:InputQueue.Enqueue('1')
$o = Out-Of 'delete amazon-2'
$h.Close()
Check 'failed delete: says FAIL' ($o -match 'FAIL\s+amazon-2\.png\s+not deleted')
Check 'failed delete: file still there and locked again' ((Test-Path "$A\amazon-2.png") -and (IsLocked "$A\amazon-2.png"))
$o = Out-Of 'delete zzzz'
Check 'no match: says so' ($o -match 'no file matches')

# ---------------------------------------------------------------------------
Section 'folders inside: list, delete, copy, cut'
function Q { $script:InputQueue = New-Object System.Collections.Queue; foreach ($a in $args) { $script:InputQueue.Enqueue([string]$a) } }
Invoke-GuardCommand 'use 1' 6>&1 | Out-Null
$out = Join-Path $env:TEMP ('guard-out-' + [guid]::NewGuid().ToString('N'))
$o = Out-Of 'list'
Check 'list shows subfolders as folders' (($o -match 'pics\s+\S+ \S+\s+folder') -and ($o -match 'pics\\p1\.png'))
Check 'subfolder pics locked' ((IsLocked "$A\pics") -and (IsLocked "$A\pics\p1.png"))
Q 1; Invoke-GuardCommand 'delete old' 6>&1 | Out-Null
Check 'delete a folder: gone with what was inside' (-not (Test-Path "$A\old"))
Q $out 1 2; $o = Out-Of 'move p1'
Check 'copy a file out: copy is there' (Test-Path "$out\p1.png")
Check 'copy is yours: owner you, no lock' (((OwnerOf "$out\p1.png") -match 'ojhas') -and -not (IsLocked "$out\p1.png"))
Check 'original still protected' ((Test-Path "$A\pics\p1.png") -and (IsLocked "$A\pics\p1.png"))
Q $out 1; $o = Out-Of 'move pics'
Check 'cut a folder out: moved with its files' ((Test-Path "$out\pics\p2.png") -and -not (Test-Path "$A\pics"))
Check 'cut folder is yours: owner you, no locks' (((OwnerOf "$out\pics") -match 'ojhas') -and ((OwnerOf "$out\pics\p2.png") -match 'ojhas') -and -not (IsLocked "$out\pics") -and -not (IsLocked "$out\pics\p2.png"))
$gone = $true; try { Remove-Item $out -Recurse -Force -ErrorAction Stop } catch { $gone = $false }
Check 'moved-out items delete normally' $gone
Q "$A\sub"; $o = Out-Of 'move checkout'
Check 'move into the protected folder itself refused' ($o -match 'pick a folder outside')
Q $env:TEMP 2 'no'; $o = Out-Of 'move all'   # where to, copy, then anything but YES
Check 'move all: anything but YES cancels' (($o -match 'cancelled') -and (Test-Path "$A\amazon-checkout.png"))
Q 2; Check 'menu fallback: typed number' ((Select-Menu @('cut','copy') 6>$null) -eq 2)
Q copy; Check 'menu fallback: typed word' ((Select-Menu @('cut','copy') 6>$null) -eq 2)
$url = New-GuardIssueUrl -Command 'delete x' -Message 'boom happened' -Where 'at Cmd-Delete'
Check 'error report: pre-filled GitHub issue link' (($url -like 'https://github.com/ShashwatGold1/Folder_Safety_Guard/issues/new?title=guard%20error%3A%20boom*') -and ($url -match 'body=.*boom%20happened'))
Check 'error report: browser not opened in tests' (-not (Open-GuardIssue $url))

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
Section 'folder at a drive root: inherited CREATOR OWNER Full Control removed (review finding 2)'
$G = 'C:\guard-e2e-root'
if (Test-Path $G) { icacls $G /reset /T /C *> $null; Remove-Item $G -Recurse -Force }
New-Item -ItemType Directory $G | Out-Null; 'g' | Set-Content "$G\secret.png"
# Windows 11's C:\ no longer passes down CREATOR OWNER:F, but older systems and freshly formatted
# data drives (D:\) do, and some folders give Everyone Full Control. Recreate both here.
icacls $G /grant '*S-1-3-0:(OI)(CI)(IO)F' *> $null
icacls $G /grant '*S-1-1-0:(OI)(CI)F' *> $null
$before = (Get-Acl $G).Access | ForEach-Object { $_.IdentityReference.Value }
Check 'test folder has CREATOR OWNER:F and Everyone:F' (($before -match 'CREATOR OWNER') -and ($before -match 'Everyone'))
$o = Out-Of "init $G"
$acc = (Get-Acl $G).Access
Check 'no CREATOR OWNER left' (-not ($acc | Where-Object { $_.IdentityReference.Value -match 'CREATOR OWNER' }))
Check 'no group can change permissions or delete inside' (-not ($acc | Where-Object { $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -match 'Users|Everyone|INTERACTIVE' -and $_.FileSystemRights.ToString() -match 'FullControl|ChangePermissions|DeleteSubdirectories|Modify|Write' }))
$r = Attack $G 'secret.png' 'g1'
Check 'attacks blocked at drive root folder' (-not ($r -match 'SUCCEEDED') -and ($r -contains 'admin: False'))
Check 'agent''s new file there locked' (WaitFor { IsLocked "$G\agent-new.png" } 10)
# the agent makes its own subfolder + file and tries to delete inside it
$mk = Join-Path $env:TEMP 'guard-mk.ps1'
@"
New-Item -ItemType Directory '$G\mine' -Force | Out-Null; 'm' | Set-Content '$G\mine\m.png'
Start-Sleep 6
try { Remove-Item '$G\mine\m.png' -Force -EA Stop; 'del-inner: SUCCEEDED' } catch { 'del-inner: blocked' }
`$r = icacls '$G\mine' /grant "`$([Security.Principal.WindowsIdentity]::GetCurrent().Name):F" 2>&1; if (`$LASTEXITCODE -eq 0) { 'grant-F: SUCCEEDED' } else { 'grant-F: blocked' }
'DONE'
"@ | Set-Content $mk -Encoding UTF8
$log = Join-Path $env:TEMP 'guard-mk.log'; Remove-Item $log -EA SilentlyContinue
$act = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c powershell -NoProfile -ExecutionPolicy Bypass -File `"$mk`" > `"$log`" 2>&1"
$pr  = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName 'guard-attack-test' -Action $act -Principal $pr -Force | Out-Null
Start-ScheduledTask -TaskName 'guard-attack-test'
WaitFor { (Test-Path $log) -and ((Get-Content $log -Raw) -match 'DONE') } 40 | Out-Null
Unregister-ScheduledTask -TaskName 'guard-attack-test' -Confirm:$false -EA SilentlyContinue
$r = @(); if (Test-Path $log) { $r = Get-Content $log }; $r | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
Check 'agent''s own subfolder: no delete inside, no Full Control' (($r -contains 'del-inner: blocked') -and ($r -contains 'grant-F: blocked'))
Remove-Item $mk, $log -Force -EA SilentlyContinue
Invoke-GuardCommand "use 3" 6>&1 | Out-Null
New-Item -ItemType Directory "$G\deep" -Force | Out-Null; 'd' | Set-Content "$G\deep\d.png"
WaitFor { IsLocked "$G\deep\d.png" } 10 | Out-Null
Q YES; $o = Out-Of 'delete all'
$left = @(Get-ChildItem $G -Force | Where-Object { $_.Name -ne '_guard.json' })
Check 'delete all: empties the folder, subfolders too' ($left.Count -eq 0)
Check 'delete all: folder itself still there and locked' ((Test-Path $G) -and (IsLocked $G))
Check 'delete all: says empty and still protected' ($o -match 'folder is empty and still protected')
Q 1; Invoke-GuardCommand 'remove' 6>&1 | Out-Null
$gone = $true; try { Remove-Item $G -Recurse -Force -ErrorAction Stop } catch { $gone = $false }
Check 'remove: drive-root folder deletes normally again' ($gone -and -not (Test-Path $G))
Check 'C:\ has no deny left for the user' (-not (IsLocked 'C:\'))
Invoke-GuardCommand "use 1" 6>&1 | Out-Null

# ---------------------------------------------------------------------------
Section 'help, typos, cls'
Check 'help edit: long text' ((Out-Of 'help edit') -match 'If you forget, the next')
Check 'help all: every command' (((Out-Of 'help all') -match 'uninstall') -and ((Out-Of 'help all') -match 'skip'))
Check 'help nosuch: says no command' ((Out-Of 'help dleete') -match 'did you mean  delete')
Check 'typo: did you mean' ((Out-Of 'delet amazon') -match 'did you mean  delete')
Check 'help (plain) = command table' ((Out-Of 'help') -match 'Current folder')
Check 'list: shows files' ((Out-Of 'list') -match 'amazon-checkout.png')

# ---------------------------------------------------------------------------
Section 'update line + update to a newer version'
function With-Version($Files, [string]$Ver, [string]$Extra = '') {
    $h = @{}; foreach ($k in $Files.Keys) { $h[$k] = $Files[$k] }
    $t = [Text.Encoding]::UTF8.GetString($h['src/guard-core.ps1']) -replace "GuardVersion = '1\.0'", "GuardVersion = '$Ver'"
    $h['src/guard-core.ps1'] = [Text.Encoding]::UTF8.GetBytes($t + $Extra); return $h
}
# hacked GitHub first: a 1.1 whose file was changed after signing, then one signed with another key
$d = Publish 'v11-tampered' (With-Version (Repo-Files) '1.1') '1.1' ('11' * 20)
[IO.File]::AppendAllText((Join-Path $d (('11' * 20) + '\src\guard-watch.ps1')), "`n'evil' | Set-Content C:\guard-e2e-evil.txt")
$o = Out-Of 'update'; Write-Host $o -ForegroundColor DarkGray
Check "hacked GitHub: a changed file - update refused" ($o -match "update refused: src/guard-watch\.ps1 from GitHub doesn't match")
Check 'hacked GitHub: nothing installed' ((Get-Content "$prefix\guard-core.ps1" -Raw) -match "GuardVersion = '1\.0'" -and -not (Test-Path 'C:\guard-e2e-evil.txt'))
$evilRsa = New-Object Security.Cryptography.RSACng 2048
$d = Join-Path $relRoot 'v11-evilkey'; New-GuardReleaseFolder $d ('12' * 20) (With-Version (Repo-Files) '1.1') '1.1' { param([byte[]]$x) $evilRsa.SignData($x, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1) }
$env:GUARD_RELEASE_URL = ([Uri]$d).AbsoluteUri
$o = Out-Of 'update'
Check 'hacked GitHub: a list signed with another key - update refused' ($o -match 'update refused: the release list is not signed')
Check 'no update line for an unsigned version' ($null -eq (Get-GuardRemoteVersion))
Check 'staging is left empty' (@(Get-ChildItem "$prefix\staging" -Force -EA SilentlyContinue).Count -eq 0)
$fake = Publish 'v11' (With-Version (Repo-Files) '1.1') '1.1' ('11' * 20)
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
Check 'Guard is Updated Successfully.' ($o -cmatch 'Guard is Updated Successfully\.')
Check 'installed core is 1.1' ((Get-Content "$prefix\guard-core.ps1" -Raw) -match "GuardVersion = '1\.1'")
Check 'background guard restarted (new process, still one)' (WaitFor { $ws = @(Watchers); $ws.Count -eq 1 -and $ws[0].ProcessId -ne $before } 20)
Check 'folders untouched by update' ((IsLocked "$A\amazon-checkout.png") -and (IsLocked "$B2\invoice.pdf"))
. "$prefix\guard-shell.ps1"; $ErrorActionPreference = 'Continue'; $script:User = Get-GuardUser; $script:Cfg = Load-GuardConfig
Check 'already newest: says so' ((Out-Of 'update') -match 'newest version \(1\.1\)')
[void](Publish 'v10-replay' (Repo-Files) '1.0' $c10)
Check 'an old signed release is not taken (no downgrade)' ((Out-Of 'update') -match 'newest version \(1\.1\)')
$env:GUARD_RELEASE_URL = ([Uri](Join-Path $relRoot 'nothing-here')).AbsoluteUri
Check 'GitHub unreachable/missing: update says so, no crash' ((Out-Of 'update') -match "can't reach GitHub")
$env:GUARD_RELEASE_URL = ([Uri](Join-Path $relRoot 'v11')).AbsoluteUri   # reinstall later: 1.1

# ---------------------------------------------------------------------------
Section 'Security Vault: real TPM chip, hidden owner account, placeholders, the background guard (SYSTEM)'
$vid = [guid]::NewGuid().ToString('N').Substring(0, 6)
$env:GUARD_VAULT_ROOT = Join-Path $root 'guard-sv'; $env:GUARD_VAULT_ACCOUNT = "gv-$vid"; $env:GUARD_VAULT_KEYNAME = "guard-vault-e2e-$vid"
$env:GUARD_VAULT_CODE = '24680-13579-24680-13579-24680-13579'
$badgeFile = "$env:ProgramData\guard\badges.txt"
$menuKey = 'SOFTWARE\Classes\*\shell\guard-unlock\command'
function Menu-Cmd { $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($menuKey); if (-not $k) { return $null }; try { [string]$k.GetValue('') } finally { $k.Close() } }
function Size($p) { (Get-Item -LiteralPath $p -Force).Length }
Set-Content "$A\marker.txt" 'TOPSECRET-e2e-marker'
[void](WaitFor { IsLocked "$A\marker.txt" } 20)
$markerHash = Get-VaultFileHash "$A\marker.txt"
$vpin = 'e2e-pin-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
try {
    Q $vpin $vpin $env:GUARD_VAULT_CODE; $o = Out-Of 'security vault on'; Write-Host $o -ForegroundColor DarkGray
    Check 'security vault on: Security Vault is On.' ($o -cmatch 'Security Vault is On\.')
    Check 'it never says where the files went' ($o -notmatch [regex]::Escape($env:GUARD_VAULT_ROOT))
    Check 'every file is an empty placeholder with its name' ((Size "$A\marker.txt") -eq 0 -and (Size "$A\amazon-checkout.png") -eq 0 -and (Size "$B2\invoice.pdf") -eq 0)
    $wdeny = @((Get-Acl "$A\marker.txt").Access | Where-Object { $_.AccessControlType -eq 'Deny' -and $_.IdentityReference -match 'ojhas' -and $_.FileSystemRights.ToString() -match 'Write' })
    Check 'a placeholder can not be written into, nor deleted' ($wdeny.Count -and (IsLocked "$A\marker.txt"))
    $vst = Read-VaultState; $vv = Get-SecureVault $vst $A; $ents = @(Get-VaultEntries $vv)
    Check 'the chip key is a real TPM machine key' ([Security.Cryptography.CngKey]::Exists($env:GUARD_VAULT_KEYNAME, (Get-VaultChipProvider), (Get-VaultChipFlags)))
    $acc = Get-LocalUser -Name $env:GUARD_VAULT_ACCOUNT -EA SilentlyContinue
    Check 'the hidden owner account exists and is switched off' ($acc -and -not $acc.Enabled)
    Check 'every sealed copy is owned by that account' ($ents.Count -gt 3 -and @($ents | Where-Object { (Get-Acl $_.Gv).GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $vst.ownerSid }).Count -eq 0)
    $aces = @((Get-Acl $env:GUARD_VAULT_ROOT).Access | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } | Select-Object -Unique)
    Check 'only SYSTEM, administrators and that account in its permissions' (@($aces | Where-Object { @('S-1-5-18', 'S-1-5-32-544', $vst.ownerSid) -notcontains $_ }).Count -eq 0)
    Check 'the sealed place is hidden' ((Get-Item -LiteralPath $env:GUARD_VAULT_ROOT -Force).Attributes -match 'Hidden')
    Check 'no readable text in the sealed copies' (-not ($ents | Where-Object { [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($_.Gv)) -match 'TOPSECRET' }))
    Check 'Explorer right-click "Unlock with guard" starts the installed guard' (((Menu-Cmd) -match [regex]::Escape("$prefix\guard.ps1")) -and ((Menu-Cmd) -match '-Unlock "%1"'))
    Check 'badges: the blue shield on the protected folders' ((Get-Content $badgeFile) -contains "sealed|$A")
    Check 'uninstall refused while it is on' (((Out-Of 'uninstall') -match 'security vault off  first') -and (Test-Path $prefix))
    Check 'edit paused while it is on' ((Out-Of 'edit') -match 'security vault off  first')
    Q $vpin; $o = (Invoke-SecurityUnlock "$A\marker.txt" 6>&1 | Out-String)
    Check 'unlock: the real file is back, the same bytes, yours, not locked' (((Get-VaultFileHash "$A\marker.txt") -eq $markerHash) -and ((OwnerOf "$A\marker.txt") -match 'ojhas') -and -not (IsLocked "$A\marker.txt"))
    Check 'unlock: only that file' ((Size "$A\amazon-checkout.png") -eq 0)
    Check 'unlocked: orange badge line' ((Get-Content $badgeFile) -contains "unsealed|$A\marker.txt")
    Set-Content "$A\marker.txt" 'TOPSECRET-e2e-marker-changed'; $newHash = Get-VaultFileHash "$A\marker.txt"
    Check 'the background guard seals the change within seconds' (WaitFor { (@((Read-VaultState).open) | Where-Object { $_.plain -eq "$A\marker.txt" }).hash -eq $newHash } 30)
    [void](Update-VaultState { param($st) foreach ($i in $st.open) { $i.at = (Get-Date).AddMinutes(-16).ToString('o') } })
    Check 'the background guard locks it again 15 minutes after opening' (WaitFor { (Size "$A\marker.txt") -eq 0 -and -not @((Read-VaultState).open).Count } 45)
    Set-Content "$A\later.txt" 'TOPSECRET-e2e-later'
    Check 'a new file in a protected folder is sealed by the background guard' (WaitFor { (Test-Path "$A\later.txt") -and (Size "$A\later.txt") -eq 0 } 45)
    if (-not (Test-Path "$A\later.txt") -or (Size "$A\later.txt") -gt 0 -or (Size "$A\marker.txt") -gt 0) {
        Get-Content "$env:ProgramData\guard\watch-error.log" -Tail 12 -EA SilentlyContinue | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
    }
    Q $vpin; $o = Out-Of 'security vault off'; Write-Host $o -ForegroundColor DarkGray
    Check 'security vault off: Security Vault is Off.' ($o -cmatch 'Security Vault is Off\.')
    Check 'every file back, with its last change' (((Get-Content "$A\marker.txt" -Raw) -match 'marker-changed') -and ((Get-Content "$A\later.txt" -Raw) -match 'e2e-later') -and (Size "$A\amazon-checkout.png") -gt 0 -and (Size "$B2\invoice.pdf") -gt 0)
    Check 'back under normal protection' ((IsLocked "$A\marker.txt") -and (IsLocked "$A\later.txt") -and (IsLocked "$A\amazon-checkout.png"))
    Check 'the right-click entry is gone' ($null -eq (Menu-Cmd))
    Check 'badges: the normal lock again' (-not ((Get-Content $badgeFile) -match '^(sealed|unsealed)\|'))
} finally {
    try { if (Test-SecurityOn) { Q $vpin; Out-Of 'security vault off' | Out-Null } } catch { }
    if (-not (Test-GuardVaultInUse)) { Remove-GuardVaultSystem | Out-Null }
    Remove-LocalUser -Name $env:GUARD_VAULT_ACCOUNT -EA SilentlyContinue
    Remove-VaultChipKey $env:GUARD_VAULT_KEYNAME
}
Check 'chip key and owner account removed again' (-not [Security.Cryptography.CngKey]::Exists($env:GUARD_VAULT_KEYNAME, (Get-VaultChipProvider), (Get-VaultChipFlags)) -and -not (Get-LocalUser -Name $env:GUARD_VAULT_ACCOUNT -EA SilentlyContinue))
foreach ($n in 'GUARD_VAULT_ROOT', 'GUARD_VAULT_ACCOUNT', 'GUARD_VAULT_KEYNAME', 'GUARD_VAULT_CODE') { Set-Item "env:$n" '' }

# ---------------------------------------------------------------------------
Section 'check account: an admin account first, then the daily one becomes standard (throwaway test accounts)'
$tid = [guid]::NewGuid().ToString('N').Substring(0, 6); $daily = "gd-$tid"; $adm = "ga-$tid"
$apw = 'Admin-pw-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
$keepUser = $script:User
try {
    New-LocalUser -Name $daily -Password (ConvertTo-SecureString ('Daily-' + [guid]::NewGuid().ToString('N')) -AsPlainText -Force) -ErrorAction Stop | Out-Null
    Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $daily
    $script:User = "$env:COMPUTERNAME\$daily"
    Check 'check: an admin daily account is to fix' ((Out-Of 'check') -match 'fix\s+account')
    Q $adm $apw 'Another-password-123'; $o = Out-Of 'check account'
    Check 'passwords differ: nothing made' (($o -match 'differ') -and -not (Get-LocalUser -Name $adm -EA SilentlyContinue))
    Q $adm 'short' 'short'
    Check 'short password refused' ((Out-Of 'check account') -match 'shorter than 12')
    Q $adm $apw $apw 'no'; $o = Out-Of 'check account'
    Check 'admin account made, and Windows accepts its password' (($o -match "works for $adm") -and (Test-CheckIsAdmin "$env:COMPUTERNAME\$adm"))
    Check 'no at the last step: the daily account stays an admin' (Test-CheckIsAdmin $script:User)
    Q $adm 'Wrong-password-000' 'Wrong-password-000'
    Check 'existing admin account + wrong password: refused, nothing taken away' (((Out-Of 'check account') -match 'not its password') -and (Test-CheckIsAdmin $script:User))
    Q $adm $apw $apw 'YES'; $o = Out-Of 'check account'
    Check 'Account is Changed Successfully.' ($o -cmatch 'Account is Changed Successfully\.')
    Check 'the daily account is a standard account now' (-not (Test-CheckIsAdmin $script:User))
    Check 'the admin account is still an administrator' (Test-CheckIsAdmin "$env:COMPUTERNAME\$adm")
    Check 'check: account ok now' ((Out-Of 'check') -match 'ok\s+account')
    Check 'check account again: nothing to do' ((Out-Of 'check account') -match 'already a standard account')
} finally {
    $script:User = $keepUser
    foreach ($n in $daily, $adm) { Remove-LocalUser -Name $n -EA SilentlyContinue }
}
Check 'test accounts removed' (-not (Get-LocalUser -Name $daily -EA SilentlyContinue) -and -not (Get-LocalUser -Name $adm -EA SilentlyContinue))
Check 'your own account untouched (still an administrator)' (Test-CheckIsAdmin $keepUser)

# ---------------------------------------------------------------------------
Section 'uninstall'
$script:InputQueue = New-Object System.Collections.Queue; $script:InputQueue.Enqueue('no')
Check 'uninstall: anything but YES cancels' (((Out-Of 'uninstall') -match 'cancelled') -and (Test-Path $prefix))
$script:InputQueue = New-Object System.Collections.Queue; $script:InputQueue.Enqueue('YES')
$o = Out-Of 'uninstall'; Write-Host $o -ForegroundColor DarkGray
Check 'Guard is Uninstalled Successfully.' ($o -cmatch 'Guard is Uninstalled Successfully\.')
Check 'background guard stopped' (WaitFor { @(Watchers).Count -eq 0 } 15)
Check 'task removed' ($null -eq (Get-ScheduledTask -TaskName guard -EA SilentlyContinue))
Check 'Program Files\guard removed' (WaitFor { -not (Test-Path $prefix) } 10)
Check 'C:\Windows\guard.cmd removed' (WaitFor { -not (Test-Path "$env:SystemRoot\guard.cmd") } 10)
Check 'ProgramData\guard removed' (-not (Test-Path "$env:ProgramData\guard"))
Check 'PATH back exactly as before, still REG_EXPAND_SZ' (((Raw-Path) -eq $rawBefore) -and ((Path-Kind) -eq 'ExpandString'))
Check 'folders owned by you again' ((OwnerOf $A) -match 'ojhas' -and (OwnerOf "$A\amazon-checkout.png") -match 'ojhas' -and (OwnerOf "$B2\invoice.pdf") -match 'ojhas')
Check 'no lock left' (-not (IsLocked "$A\amazon-checkout.png") -and -not (IsLocked "$A\sub") -and -not (IsLocked $A))
Check '_guard.json kept as memory' ((Test-Path "$A\_guard.json") -and (Test-Path "$B2\_guard.json"))

# ---------------------------------------------------------------------------
Section 'reinstall finds the memory and restores'
$env:GUARD_ANSWERS = '1'
# run it the way  irm | iex  does: text, no file behind it (installer must save itself + run apart)
#  (and no -Source: the signed installer and files, from the signed 1.1 release)
$o = & ([scriptblock]::Create($sbText)) 6>&1 | Out-String
$env:GUARD_ANSWERS = ''
Check 'no-file run (iex style) worked' ($o -cmatch 'Guard is Installed Successfully\.')
Check 'iex style left nothing behind in this session' (-not (Get-Command Bar-Start -EA SilentlyContinue))
Write-Host $o -ForegroundColor DarkGray
Check 'installer found the memory' ($o -match 'memory\s+found in')
Check 'the signed 1.1 was installed' ((Get-Content "$prefix\guard-core.ps1" -Raw) -match "GuardVersion = '1\.1'")
Check 'restore: 2 folders protected' ($o -cmatch '2 Folders are Protected Successfully\.')
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
Check 'uninstalled again' ((WaitFor { -not (Test-Path $prefix) } 10) -and $null -eq (Get-ScheduledTask -TaskName guard -EA SilentlyContinue))
$canDel = $true; try { Remove-Item $root -Recurse -Force -ErrorAction Stop } catch { $canDel = $false }
Check 'test folders delete normally' ($canDel -and -not (Test-Path $root))
Check 'testing_env has no deny left' (-not (IsLocked (Join-Path $repo 'testing_env')))
Check 'no background guard left running' (@(Watchers).Count -eq 0)
Check 'ProgramData\guard gone' (-not (Test-Path "$env:ProgramData\guard"))
Remove-Item $relRoot -Recurse -Force -EA SilentlyContinue
$env:GUARD_RELEASE_KEY = ''; $env:GUARD_RELEASE_URL = ''
Check 'PATH exactly as before after the whole run' ((Raw-Path) -eq $rawBefore)
Set-TestFlag $false
Check 'test switch GUARD_TEST removed' (-not (Get-ItemProperty "HKLM:\$envKey" -Name GUARD_TEST -EA SilentlyContinue))

$color='Green'; if($fail){$color='Red'}
Write-Host "`n$pass passed, $fail failed" -ForegroundColor $color
