# test-check.ps1 - the  check  command. Every registry read and write goes to a test key in
# HKCU (GUARD_CHECK_ROOT); hibernate, Defender and the update date are stand-ins. Nothing on
# this PC changes. No admin.
$script:GuardConfigPath = Join-Path $env:TEMP ('guardtest-' + [guid]::NewGuid().ToString('N') + '\config.json')
$testKey = 'HKCU:\Software\guard-check-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$env:GUARD_CHECK_ROOT = $testKey
. "$PSScriptRoot\guard-shell.ps1"
$ErrorActionPreference = 'Continue'
$script:User = Get-GuardUser
$script:Cfg = New-GuardConfig
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { Write-Host "  PASS  $n" -ForegroundColor Green; $script:pass++ } else { Write-Host "  FAIL  $n" -ForegroundColor Red; $script:fail++ } }
function Feed([string[]]$a) { $script:InputQueue = New-Object System.Collections.Queue; foreach ($x in $a) { $script:InputQueue.Enqueue($x) } }
function Out-Of([string]$c) { (Invoke-GuardCommand $c 6>&1 | Out-String) }

# stand-ins for what isn't a plain registry value
$script:FakeHib = $true; $script:FakeSamples = 1; $script:HibFails = $false
function Get-CheckHibernate { return $script:FakeHib }
function Set-CheckHibernateOff { if ($script:HibFails) { throw 'powercfg said no' }; $script:FakeHib = $false }
function Get-CheckDefender { return @{ Ok = $true; RealTime = $true; Tamper = $true; Samples = $script:FakeSamples } }
function Set-CheckDefenderSamples { $script:FakeSamples = 2 }
function Get-CheckLastUpdate { return (Get-Date).AddDays(-100) }
function Test-CheckIsAdmin([string]$Account) { return $true }

try {
    Write-Host "== check: a PC with nothing set ==" -ForegroundColor Cyan
    $o = Out-Of 'check'
    foreach ($n in 'account', 'passwords', 'clipboard', 'hibernate', 'pagefile', 'crash files', 'samples', 'updates', 'core') {
        Check "shows $n to fix" ($o -match "fix\s+$n\s")
    }
    Check 'uac: not set = Windows default = ok' ($o -match 'ok\s+uac\s')
    Check 'defender on: ok' ($o -match 'ok\s+defender\s')
    Check 'says why, in plain words (clipboard)' ($o -match 'every password you copy')
    Check 'old Windows: 100 days ago' ($o -match '100 days ago')
    Check 'startup: an info line, never something to fix' (($o -match 'info\s+startup\s+no startup PIN') -and ($o -notmatch 'fix\s+startup'))
    Check 'counts what check fix can do' ($o -match '9 to fix\.\s+check fix  fixes 6 of them')

    Write-Host "`n== check fix ==" -ForegroundColor Cyan
    Feed @('no'); $o = Out-Of 'check fix'
    Check 'anything but YES: nothing changed' (($o -match 'cancelled') -and $null -eq (Get-CheckValue 'SOFTWARE\Policies\Microsoft\Windows\System' 'AllowClipboardHistory'))
    $script:HibFails = $true
    Feed @('YES'); $o = Out-Of 'check fix'
    Check 'a fix that fails says FAIL' ($o -match 'FAIL\s+hibernate')
    Check 'a failed fix never says Successfully' (($o -notmatch 'Changed Successfully') -and ($o -match '1 setting\(s\) could not be changed'))
    Check 'the other fixes still ran' ((Get-CheckValue 'SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'ClearPageFileAtShutdown') -eq 1)
    $script:HibFails = $false
    Feed @('YES'); $o = Out-Of 'check fix'
    Check 'second run: Settings are Changed Successfully' ($o -cmatch 'Settings are Changed Successfully\.')
    Check 'clipboard history + cloud off (policy)' (((Get-CheckValue 'SOFTWARE\Policies\Microsoft\Windows\System' 'AllowClipboardHistory') -eq 0) -and ((Get-CheckValue 'SOFTWARE\Policies\Microsoft\Windows\System' 'AllowCrossDeviceClipboard') -eq 0))
    Check 'password box after Ctrl+Alt+Del' ((Get-CheckValue 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\CredUI' 'EnableSecureCredentialPrompting') -eq 1)
    Check 'crash files: small' ((Get-CheckValue 'SYSTEM\CurrentControlSet\Control\CrashControl' 'CrashDumpEnabled') -eq 3)
    Check 'hibernate off, samples never sent' ((-not $script:FakeHib) -and $script:FakeSamples -eq 2)
    $o = Out-Of 'check'
    Check 'after fix: only what guard can not change is left' ($o -match '3 to fix\.\s*\r?\n' -and $o -match 'fix\s+account' -and $o -match 'fix\s+updates' -and $o -match 'fix\s+core')
    Check 'check fix again: nothing to do' ((Out-Of 'check fix') -match 'nothing guard can fix')
    Check 'never touched the real HKLM (test key holds the values)' (Test-Path "$testKey\SOFTWARE\Policies\Microsoft\Windows\System")
    Check 'help check explains it' ((Out-Of 'help check') -match 'Nothing about startup or booting')
    Check 'unknown check word: says the three forms' ((Out-Of 'check foo') -match 'check, check fix or check account')
} finally {
    Remove-Item -LiteralPath $testKey -Recurse -Force -EA SilentlyContinue
    $env:GUARD_CHECK_ROOT = ''
}
Write-Host "`n$script:pass passed, $script:fail failed"
