# verify-agent.ps1 — RUN ELEVATED. Protects a folder with the real init, then attacks it from a
# limited (non-admin) process, the same rights an AI agent in a normal terminal has.
$ErrorActionPreference = 'Continue'
$src = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfgDir = Join-Path $env:TEMP ('guardag-' + [guid]::NewGuid().ToString('N'))
$env:GUARD_CONFIG = Join-Path $cfgDir 'config.json'
$env:GUARD_NOBROWSER = '1'
# admin process: guard honours GUARD_CONFIG only with HKLM GUARD_TEST=1 (removed at the end)
$envKey = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
$k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($envKey, $true); $k.SetValue('GUARD_TEST', '1'); $k.Close()
. "$src\guard-shell.ps1"
$ErrorActionPreference = 'Continue'
$root   = Join-Path (Split-Path $src -Parent) 'testing_env'
$folder = Join-Path $root 'owntest'
$user   = Get-GuardUser
$pass=0; $fail=0
function Check($n,$c){ if($c){Write-Host "  PASS  $n" -ForegroundColor Green;$script:pass++}else{Write-Host "  FAIL  $n" -ForegroundColor Red;$script:fail++} }

if (-not (Test-GuardAdmin)) { Write-Host 'NOT ELEVATED' -ForegroundColor Red; return }

function Run-Limited([string]$target, [string]$log) {
    Remove-Item $log -Force -EA SilentlyContinue
    $arg = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$src\attack-limited.ps1`" -Folder `"$folder`" -Log `"$log`" -Target `"$target`""
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $pr  = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName 'guard-attack-test' -Action $act -Principal $pr -Force | Out-Null
    Start-ScheduledTask -TaskName 'guard-attack-test'
    for ($i=0; $i -lt 60; $i++) { Start-Sleep -Milliseconds 500; if ((Test-Path $log) -and ((Get-Content $log -Raw) -match 'DONE')) { break } }
    Unregister-ScheduledTask -TaskName 'guard-attack-test' -Confirm:$false -EA SilentlyContinue
    if (Test-Path $log) { return Get-Content $log } else { return @('NO LOG') }
}

# fresh folder, protected through the real shell
if (Test-Path $folder) { icacls $folder /reset /T /C *> $null; Remove-Item $folder -Recurse -Force -EA SilentlyContinue }
New-Item -ItemType Directory $folder -Force | Out-Null
Set-Content "$folder\secret.png" 'top secret'
$script:User = $user
$script:Cfg  = New-GuardConfig
Write-Host '== init (real) ==' -ForegroundColor Cyan
Invoke-GuardCommand "init $folder" | Out-Null

Write-Host "`n== round 1: limited process attacks a protected file ==" -ForegroundColor Cyan
$r1 = Run-Limited 'secret.png' (Join-Path $root 'attack1.log')
$r1 | ForEach-Object { "    $_" }
Check 'attacker really had no admin'      ($r1 -contains 'admin: False')
Check 'no attack succeeded'               (-not ($r1 -match 'SUCCEEDED'))
Check 'normal use still works (read, add)' (($r1 -contains 'read file: ok') -and ($r1 -contains 'add new file: ok'))
Check 'secret.png still exists'           (Test-Path "$folder\secret.png")

Write-Host "`n== round 2: file the attacker created itself, after guard locked it ==" -ForegroundColor Cyan
Invoke-GuardCommand 'resume' | Out-Null
Check 'agent-new.png now owned by SYSTEM' ((Get-Acl "$folder\agent-new.png").Owner -match 'SYSTEM')
$r2 = Run-Limited 'agent-new.png' (Join-Path $root 'attack2.log')
$r2 | ForEach-Object { "    $_" }
Check 'no attack on its own file succeeded' (-not ($r2 -match 'SUCCEEDED'))
Check 'agent-new.png still exists'          (Test-Path "$folder\agent-new.png")

Write-Host "`n== remove gives everything back ==" -ForegroundColor Cyan
$script:InputQueue = New-Object System.Collections.Queue; $script:InputQueue.Enqueue('1')   # remove asks first
Invoke-GuardCommand 'remove' | Out-Null
Check 'owner back to user'           ((Get-Acl $folder).Owner -match 'ojhas')
Check 'file owner back to user'      ((Get-Acl "$folder\secret.png").Owner -match 'ojhas')
$canDel = try { Remove-Item "$folder\secret.png" -Force -EA Stop; $true } catch { $false }
Check 'file deletes normally after remove' $canDel
$canDelF = try { Remove-Item $folder -Recurse -Force -EA Stop; $true } catch { $false }
Check 'folder deletes normally after remove' $canDelF
icacls $root /reset *> $null
Remove-Item (Join-Path $root 'attack1.log'),(Join-Path $root 'attack2.log') -Force -EA SilentlyContinue
Remove-Item $cfgDir -Recurse -Force -EA SilentlyContinue
$k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($envKey, $true); $k.DeleteValue('GUARD_TEST', $false); $k.Close()

$color='Green'; if($fail){$color='Red'}
Write-Host "`n$pass passed, $fail failed" -ForegroundColor $color