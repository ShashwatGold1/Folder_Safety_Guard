# test-vault.ps1 - the Security Vault: on (every protected folder sealed, placeholders left),
# unlock one file, changes sealed every tick, locks again by itself, new files sealed, recovery
# code, PIN change, off. No admin: a stand-in for the TPM chip, no hidden account, no owner
# changes. verify-e2e and redteam run the real chip, account and permissions.
$tmp = Join-Path $env:TEMP ('guard-vault-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$script:GuardConfigPath = Join-Path $tmp 'data\config.json'
$env:GUARD_VAULT_ROOT = Join-Path $tmp 'sv'
$env:GUARD_VAULT_SOFTCHIP = '1'; $env:GUARD_VAULT_NOACCOUNT = '1'; $env:GUARD_NOBROWSER = '1'
$code = '11111-22222-33333-44444-55555-66666'; $env:GUARD_VAULT_CODE = $code
. "$PSScriptRoot\guard-shell.ps1"
$ErrorActionPreference = 'Continue'
$script:User = Get-GuardUser; $script:Cfg = New-GuardConfig
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { Write-Host "  PASS  $n" -ForegroundColor Green; $script:pass++ } else { Write-Host "  FAIL  $n" -ForegroundColor Red; $script:fail++ } }
function Feed([string[]]$a) { $script:InputQueue = New-Object System.Collections.Queue; foreach ($x in $a) { $script:InputQueue.Enqueue($x) } }
function Out-Of([string]$c) { (Invoke-GuardCommand $c 6>&1 | Out-String -Width 400) }
function Unlock-Of([string]$p) { $script:LastUnlock = 9; $o = (& { $script:LastUnlock = Invoke-SecurityUnlock $p } 6>&1 | Out-String -Width 400); return $o }
function Has-Secret([string]$Dir) { foreach ($f in Get-ChildItem -LiteralPath $Dir -Recurse -File -Force -EA SilentlyContinue) { if ([Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($f.FullName)) -match 'TOPSECRET') { return $true } }; return $false }
function Size($p) { (Get-Item -LiteralPath $p -Force).Length }
function Tick([string[]]$New = @(), [switch]$Full, [datetime]$Since = [datetime]::MinValue) { Invoke-SecureTick -User $script:User -Cfg $script:Cfg -Since $Since -NewPaths $New -Full:$Full | Out-Null }
function Age($p) { (Get-Item -LiteralPath $p -Force).LastWriteTime = (Get-Date).AddMinutes(-1) }

$A = Join-Path $tmp 'Alpha'; $B = Join-Path $tmp 'Beta'; $pin = 'pin-12345678'
New-Item -ItemType Directory "$A\sub", $B -Force | Out-Null
Set-Content "$A\alpha.txt" 'TOPSECRET-alpha'; Set-Content "$A\sub\beta.txt" 'TOPSECRET-beta'; Set-Content "$B\gamma.txt" 'TOPSECRET-gamma'
Set-Content "$A\work.tmp" 'TOPSECRET-skipme'   # a temp file: never sealed (built-in skip)
$big = New-Object byte[] (3MB + 17); (New-Object Random 5).NextBytes($big); [IO.File]::WriteAllBytes("$A\big.bin", $big)
$bigHash = Get-VaultFileHash "$A\big.bin"
$when = (Get-Item "$A\alpha.txt").LastWriteTime
$script:Cfg.folders = @(
    [pscustomobject]@{ path = $A; name = 'Alpha'; skip = @(); added = (Get-Date).ToString('o') },
    [pscustomobject]@{ path = $B; name = 'Beta'; skip = @(); added = (Get-Date).ToString('o') })
try {
    Write-Host "== security vault on ==" -ForegroundColor Cyan
    Check 'off at first' ((Out-Of 'security vault') -match 'Security Vault is Off')
    Feed @('pin-12345678', 'pin-99999999'); $o = Out-Of 'security vault on'
    Check 'PINs differ: nothing changed' (($o -match 'differ') -and -not (Read-VaultState) -and (Size "$A\alpha.txt") -gt 0)
    Feed @($pin, $pin, '00000-00000'); $o = Out-Of 'security vault on'
    Check 'wrong recovery code typed back: nothing changed' (($o -match 'not the code') -and -not (Test-SecurityOn) -and (Size "$A\alpha.txt") -gt 0)
    Feed @($pin, $pin, $code); $o = Out-Of 'security vault on'
    Check 'shows the recovery code once' ($o -match [regex]::Escape($code))
    Check 'Security Vault is On.' ($o -cmatch 'Security Vault is On\.')
    Check 'never says where the files went' ($o -notmatch [regex]::Escape($env:GUARD_VAULT_ROOT) -and $o -notmatch 'guard-sv')
    Check 'every file is an empty placeholder, same name' ((Size "$A\alpha.txt") -eq 0 -and (Size "$A\sub\beta.txt") -eq 0 -and (Size "$B\gamma.txt") -eq 0 -and (Size "$A\big.bin") -eq 0)
    Check 'the placeholder keeps the file date' ((Get-Item "$A\alpha.txt").LastWriteTime -eq $when)
    Check 'a temp file is left alone' ((Get-Content "$A\work.tmp" -Raw) -match 'skipme')
    Check 'the folders hold no readable text (but the temp file)' (-not (Has-Secret $B) -and -not (@(Get-ChildItem $A -Recurse -File | Where-Object { $_.Name -ne 'work.tmp' -and $_.Length -gt 0 }).Count))
    Check 'the sealed copies hold no readable text' (-not (Has-Secret $env:GUARD_VAULT_ROOT))
    Check 'badges: both folders get the shield' (((Get-Content (Join-Path (Split-Path $script:GuardConfigPath) 'badges.txt')) -match '^sealed\|').Count -eq 2)
    Check 'the status block says it' ((Show-VaultLine 6>&1 | Out-String) -match 'Security Vault on')
    Check 'on again: already on' ((Out-Of 'security vault on') -match 'already On')
    Check 'delete is paused while it is on' ((Out-Of 'delete alpha') -match 'security vault off  first')
    Check 'uninstall refused while it is on' ((Out-Of 'uninstall') -match 'security vault off  first')

    Write-Host "`n== unlock one file (right-click) ==" -ForegroundColor Cyan
    Feed @('wrong-pin-000'); $o = Unlock-Of "$A\alpha.txt"
    Check 'wrong PIN: nothing unlocked' (($o -match 'wrong PIN') -and $script:LastUnlock -ne 0 -and (Size "$A\alpha.txt") -eq 0)
    Feed @($pin); $o = Unlock-Of "$A\alpha.txt"
    Check 'right PIN: the real file is back in its place' ($script:LastUnlock -eq 0 -and (Get-Content "$A\alpha.txt" -Raw) -match 'TOPSECRET-alpha')
    Check 'only that file: everything else stays sealed' ((Size "$A\sub\beta.txt") -eq 0 -and (Size "$A\big.bin") -eq 0 -and (Size "$B\gamma.txt") -eq 0)
    Check 'unlocked file: orange badge line' ((Get-Content (Join-Path (Split-Path $script:GuardConfigPath) 'badges.txt')) -contains "unsealed|$A\alpha.txt")
    Check 'unlock again: says already unlocked' ((Unlock-Of "$A\alpha.txt") -match 'already unlocked')
    Set-Content "$A\alpha.txt" 'TOPSECRET-alpha-changed'
    Tick
    Check 'a change is sealed at the next tick (5 s)' ((@((Read-VaultState).open)[0].hash) -eq (Get-VaultFileHash "$A\alpha.txt"))
    Tick
    Check 'before 15 minutes: stays unlocked' ((Size "$A\alpha.txt") -gt 0)
    Update-VaultState { param($st) foreach ($i in $st.open) { $i.at = (Get-Date).AddMinutes(-16).ToString('o') } } | Out-Null
    $hold = [IO.File]::Open("$A\alpha.txt", 'Open', 'Read', 'None')
    Tick
    Check 'after 15 minutes but still open in a program: stays unlocked' ((Size "$A\alpha.txt") -gt 0)
    $hold.Dispose()
    Tick
    Check 'after 15 minutes, no program using it: locked again (placeholder back)' ((Size "$A\alpha.txt") -eq 0 -and -not @((Read-VaultState).open).Count)

    Write-Host "`n== unlock a folder, sign-in, new files ==" -ForegroundColor Cyan
    Feed @($pin); Unlock-Of "$A\sub" | Out-Null
    Check 'a folder: every file in it unlocked' ((Get-Content "$A\sub\beta.txt" -Raw) -match 'TOPSECRET-beta' -and (Size "$A\alpha.txt") -eq 0)
    Tick -Since (Get-Date).AddMinutes(1)
    Check 'unlocked before this sign-in: locked again' ((Size "$A\sub\beta.txt") -eq 0)
    Set-Content "$B\new.txt" 'TOPSECRET-new'; Age "$B\new.txt"
    Tick -New @("$B\new.txt")
    Check 'a new file in a protected folder is sealed by itself' ((Size "$B\new.txt") -eq 0 -and -not (Has-Secret $B))
    New-Item -ItemType Directory "$B\deep" -Force | Out-Null; Set-Content "$B\deep\copied.txt" 'TOPSECRET-copied'; Age "$B\deep\copied.txt"
    Tick -Full
    Check 'the full sweep seals anything it finds' ((Size "$B\deep\copied.txt") -eq 0)
    Set-Content "$B\fresh.txt" 'TOPSECRET-fresh'
    Tick -New @("$B\fresh.txt")
    Check 'a file still being written (under 2 s old) waits' ((Size "$B\fresh.txt") -gt 0)
    Age "$B\fresh.txt"; Tick -New @("$B\fresh.txt")
    Check '... and is sealed a moment later' ((Size "$B\fresh.txt") -eq 0)

    Write-Host "`n== a changed sealed copy is refused ==" -ForegroundColor Cyan
    $v = Get-SecureVault (Read-VaultState) $B; $gv = Get-SecureGv $v 'gamma.txt'
    $orig = [IO.File]::ReadAllBytes($gv); $bad = [byte[]]$orig.Clone(); $bad[$bad.Length - 5] = $bad[$bad.Length - 5] -bxor 1; [IO.File]::WriteAllBytes($gv, $bad)
    Feed @($pin); $o = Unlock-Of "$B\gamma.txt"
    Check 'changed after sealing: refused, placeholder stays' (($o -match 'damaged or changed') -and (Size "$B\gamma.txt") -eq 0)
    [IO.File]::WriteAllBytes($gv, $orig)
    Check 'not in the vault: refused' ((Unlock-Of $env:TEMP) -match 'not in the Security Vault')

    Write-Host "`n== recovery code, PIN change ==" -ForegroundColor Cyan
    Feed @('recovery', '99999-99999-99999-99999-99999-99999'); Check 'wrong recovery code refused' ((Unlock-Of "$B\gamma.txt") -match 'wrong recovery code')
    Feed @('recovery', $code); Unlock-Of "$B\gamma.txt" | Out-Null
    Check 'the recovery code unlocks' ((Get-Content "$B\gamma.txt" -Raw) -match 'TOPSECRET-gamma')
    Feed @($pin, 'new-pin-7654321', 'new-pin-7654321'); $o = Out-Of 'security vault pin'
    Check 'PIN is Changed Successfully.' ($o -cmatch 'PIN is Changed Successfully\.')
    Feed @($pin); Check 'the old PIN no longer works' ((Unlock-Of "$A\alpha.txt") -match 'wrong PIN')
    $pin = 'new-pin-7654321'
    Check 'status: 1 file unlocked' ((Out-Of 'security vault') -match '1 file\(s\) unlocked')

    Write-Host "`n== security vault off ==" -ForegroundColor Cyan
    Feed @('wrong-pin-000'); $o = Out-Of 'security vault off'
    Check 'wrong PIN: stays on' (($o -match 'wrong PIN') -and (Test-SecurityOn) -and (Size "$A\alpha.txt") -eq 0)
    Feed @($pin); $o = Out-Of 'security vault off'
    Check 'Security Vault is Off.' ($o -cmatch 'Security Vault is Off\.')
    Check 'every file back, with its last change' (((Get-Content "$A\alpha.txt" -Raw) -match 'alpha-changed') -and ((Get-Content "$A\sub\beta.txt" -Raw) -match 'TOPSECRET-beta') -and ((Get-VaultFileHash "$A\big.bin") -eq $bigHash))
    Check 'files sealed while it was on come back too' (((Get-Content "$B\new.txt" -Raw) -match 'TOPSECRET-new') -and ((Get-Content "$B\deep\copied.txt" -Raw) -match 'copied') -and ((Get-Content "$B\gamma.txt" -Raw) -match 'gamma'))
    Check 'the file date is kept' ((Get-Item "$A\sub\beta.txt").LastWriteTime -lt (Get-Date).AddSeconds(-1))
    Check 'nothing sealed is left' (-not (Test-SecurityOn) -and -not @((Read-VaultState).vaults).Count -and -not (Has-Secret $env:GUARD_VAULT_ROOT))
    Check 'badges back to the normal lock' (-not ((Get-Content (Join-Path (Split-Path $script:GuardConfigPath) 'badges.txt')) -match '^(sealed|unsealed)\|'))
    Check 'off again: already off' ((Out-Of 'security vault off') -match 'already Off')
    Check 'delete works again' ((Out-Of 'delete nosuchfile') -notmatch 'security vault off  first')
    Feed @($pin); $o = Out-Of 'security vault on'
    Check 'on again later: only the PIN (no new setup)' (($o -cmatch 'Security Vault is On\.') -and $o -notmatch 'recovery code\.')
    Feed @($pin); Out-Of 'security vault off' | Out-Null
    Check 'help security explains it' ((Out-Of 'help security') -match 'Unlock with guard')
    Check 'the old vault commands are gone' ((Out-Of 'unvault x') -match 'unknown command' -and (Out-Of 'open x') -match 'unknown command')
} finally {
    foreach ($n in 'GUARD_VAULT_ROOT', 'GUARD_VAULT_SOFTCHIP', 'GUARD_VAULT_NOACCOUNT', 'GUARD_VAULT_CODE') { Set-Item "env:$n" '' }
    Remove-Item -LiteralPath $tmp -Recurse -Force -EA SilentlyContinue
}
Write-Host "`n$script:pass passed, $script:fail failed"
