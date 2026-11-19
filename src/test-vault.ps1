# test-vault.ps1 - the vault: in, open only what is asked, close, auto-close, recovery code,
# PIN change, out. No admin: a stand-in for the TPM chip (GUARD_VAULT_SOFTCHIP), no hidden
# account and no owner changes. verify-e2e and redteam run the real chip, account and permissions.
$tmp = Join-Path $env:TEMP ('guard-vault-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$script:GuardConfigPath = Join-Path $tmp 'data\config.json'
$env:GUARD_VAULT_ROOT = Join-Path $tmp 'guard-vault'
$env:GUARD_VAULT_SOFTCHIP = '1'; $env:GUARD_VAULT_NOACCOUNT = '1'; $env:GUARD_NOBROWSER = '1'
$code = '11111-22222-33333-44444-55555-66666'; $env:GUARD_VAULT_CODE = $code
. "$PSScriptRoot\guard-shell.ps1"
$ErrorActionPreference = 'Continue'
$script:User = Get-GuardUser; $script:Cfg = New-GuardConfig
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { Write-Host "  PASS  $n" -ForegroundColor Green; $script:pass++ } else { Write-Host "  FAIL  $n" -ForegroundColor Red; $script:fail++ } }
function Feed([string[]]$a) { $script:InputQueue = New-Object System.Collections.Queue; foreach ($x in $a) { $script:InputQueue.Enqueue($x) } }
function Out-Of([string]$c) { (Invoke-GuardCommand $c 6>&1 | Out-String -Width 400) }
function Has-Secret([string]$Dir) { foreach ($f in Get-ChildItem -LiteralPath $Dir -Recurse -File -Force -EA SilentlyContinue) { if ([Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($f.FullName)) -match 'TOPSECRET') { return $true } }; return $false }

$sec = Join-Path $tmp 'Secrets'; $pin = 'pin-12345678'
New-Item -ItemType Directory "$sec\sub" -Force | Out-Null
Set-Content "$sec\alpha.txt" 'TOPSECRET-alpha'; Set-Content "$sec\sub\beta.txt" 'TOPSECRET-beta'
$big = New-Object byte[] (3MB + 17); (New-Object Random 5).NextBytes($big); [IO.File]::WriteAllBytes("$sec\big.bin", $big)
$bigHash = Get-VaultFileHash "$sec\big.bin"
try {
    Write-Host "== vault: first time sets the PIN and the recovery code ==" -ForegroundColor Cyan
    Feed @('pin-12345678', 'pin-99999999'); $o = Out-Of "vault `"$sec`""
    Check 'PINs differ: nothing made' (($o -match 'differ') -and -not (Read-VaultState) -and (Test-Path "$sec\alpha.txt"))
    Feed @('short', 'short'); Check 'short PIN refused' ((Out-Of "vault $sec") -match 'shorter than 8')
    Feed @($pin, $pin, '00000-00000'); $o = Out-Of "vault $sec"
    Check 'wrong recovery code typed back: nothing vaulted' (($o -match 'not the code') -and -not (Read-VaultState) -and (Test-Path "$sec\alpha.txt"))
    Feed @($pin, $pin, $code); $o = Out-Of "vault $sec"
    Check 'shows the recovery code once' ($o -match [regex]::Escape($code))
    Check 'Folder is in the Vault.' ($o -cmatch 'Folder is in the Vault\.')
    Check 'the normal folder is gone' (-not (Test-Path $sec))
    $s = Read-VaultState; $v = @($s.vaults)[0]
    Check 'every file is in the vault' (@(Get-VaultEntries $v).Count -eq 3)
    Check 'the vault holds no readable text' (-not (Has-Secret $env:GUARD_VAULT_ROOT))
    Check 'vault state saved, with a copy in the vault folder' ((Test-Path (Get-VaultStatePath)) -and (Test-Path "$env:GUARD_VAULT_ROOT\vault-keys.json"))
    Check 'vault lists it' ((Out-Of 'vault') -match 'Secrets\s+3 files')

    Write-Host "`n== open: PIN, only what was asked ==" -ForegroundColor Cyan
    Feed @('wrong-pin-000'); $o = Out-Of 'open alpha'
    Check 'wrong PIN: not opened' (($o -match 'wrong PIN') -and -not (Test-Path "$sec\alpha.txt"))
    Feed @($pin); $o = Out-Of 'open alpha'
    Check 'right PIN: alpha.txt is back' ((Get-Content "$sec\alpha.txt" -Raw) -match 'TOPSECRET-alpha')
    Check 'only that file: beta and big stay locked' (-not (Test-Path "$sec\sub\beta.txt") -and -not (Test-Path "$sec\big.bin"))
    Check 'the status block says something is open' ((Show-VaultLine 6>&1 | Out-String) -match '1 item\(s\) open')
    Check 'open the same again: says already open' ((Out-Of 'open alpha') -match 'already open')
    Set-Content "$sec\alpha.txt" 'TOPSECRET-alpha-changed'
    $o = Out-Of 'close'
    Check 'close: Vault is Locked Again.' ($o -cmatch 'Vault is Locked Again\.')
    Check 'close: the change is saved back' ($o -match '1 changed saved')
    Check 'close: the open copy is gone, and its folder' (-not (Test-Path $sec))
    Check 'close: nothing open' ((Out-Of 'close') -match 'nothing is open')

    Write-Host "`n== open a whole folder ==" -ForegroundColor Cyan
    Feed @($pin); $o = Out-Of 'open Secrets'
    Check 'whole folder: every file back' ((Get-Content "$sec\alpha.txt" -Raw) -match 'alpha-changed' -and (Test-Path "$sec\sub\beta.txt") -and ((Get-VaultFileHash "$sec\big.bin") -eq $bigHash))
    Set-Content "$sec\new.txt" 'TOPSECRET-new'; Remove-Item "$sec\sub\beta.txt"
    $o = Out-Of 'close all'
    Check 'a new file is added to the vault' ($o -match '1 new added')
    Check 'a file deleted while open stays in the vault' (($o -match 'kept in the vault') -and @(Get-VaultEntries $v | Where-Object { $_.Rel -eq 'sub\beta.txt' }).Count -eq 1)
    Check 'still no readable text in the vault' (-not (Has-Secret $env:GUARD_VAULT_ROOT))

    Write-Host "`n== a changed vault file is refused ==" -ForegroundColor Cyan
    $gv = @(Get-VaultEntries $v | Where-Object { $_.Rel -eq 'alpha.txt' })[0].Gv
    $orig = [IO.File]::ReadAllBytes($gv); $bad = [byte[]]$orig.Clone(); $bad[$bad.Length - 5] = $bad[$bad.Length - 5] -bxor 1; [IO.File]::WriteAllBytes($gv, $bad)
    Feed @($pin); $o = Out-Of 'open alpha'
    Check 'changed after it was locked: refused, nothing written' (($o -match 'damaged or changed') -and -not (Test-Path "$sec\alpha.txt"))
    [IO.File]::WriteAllBytes($gv, $orig)
    Out-Of 'close' | Out-Null

    Write-Host "`n== closes by itself ==" -ForegroundColor Cyan
    Feed @($pin); Out-Of 'open beta' | Out-Null
    Check 'beta open' (Test-Path "$sec\sub\beta.txt")
    Check 'not yet 30 minutes: stays open' ((Invoke-GuardVaultAutoClose -User $script:User) -eq 0 -and (Test-Path "$sec\sub\beta.txt"))
    Update-VaultState { param($st) foreach ($i in $st.open) { $i.at = (Get-Date).AddMinutes(-31).ToString('o') } }
    Check 'after 30 minutes: closed by the background guard' ((Invoke-GuardVaultAutoClose -User $script:User) -eq 1 -and -not (Test-Path "$sec\sub\beta.txt"))
    Feed @($pin); Out-Of 'open beta' | Out-Null
    Check 'opened before the last sign-in: closed' ((Invoke-GuardVaultAutoClose -User $script:User -Since (Get-Date).AddMinutes(1)) -eq 1 -and -not (Test-Path $sec))

    Write-Host "`n== recovery code, PIN change ==" -ForegroundColor Cyan
    Feed @('recovery', '99999-99999-99999-99999-99999-99999'); Check 'wrong recovery code refused' ((Out-Of 'open alpha') -match 'wrong recovery code')
    Feed @('recovery', $code); Out-Of 'open alpha' | Out-Null
    Check 'the recovery code opens it' ((Get-Content "$sec\alpha.txt" -Raw) -match 'alpha-changed'); Out-Of 'close' | Out-Null
    Feed @($pin, 'new-pin-7654321', 'new-pin-7654321'); $o = Out-Of 'vault pin'
    Check 'PIN is Changed Successfully.' ($o -cmatch 'PIN is Changed Successfully\.')
    Feed @($pin); Check 'the old PIN no longer works' ((Out-Of 'open alpha') -match 'wrong PIN')
    Feed @('new-pin-7654321'); Out-Of 'open alpha' | Out-Null
    Check 'the new PIN works' (Test-Path "$sec\alpha.txt"); Out-Of 'close' | Out-Null
    $pin = 'new-pin-7654321'

    Write-Host "`n== refusals ==" -ForegroundColor Cyan
    Check 'a file, not a folder: refused' ((Out-Of "vault $PSCommandPath") -match 'not a folder')
    Check 'the Windows folder: refused' ((Out-Of ("vault " + (Get-GuardWindowsDir))) -match "can't be a vault")
    Check 'nothing matching: says so' ((Out-Of 'open nosuchthing') -match 'nothing in the vault matches')
    Check 'uninstall refused while folders are in the vault' ((Out-Of 'uninstall') -match 'unvault all  first')
    Check 'help vault explains it' ((Out-Of 'help vault') -match 'access denied')

    Write-Host "`n== unvault ==" -ForegroundColor Cyan
    Feed @('no'); Check 'unvault: anything but YES cancels' (((Out-Of 'unvault Secrets') -match 'cancelled') -and -not (Test-Path $sec))
    Feed @('YES', $pin); $o = Out-Of 'unvault Secrets'
    Check 'Folder is out of the Vault.' ($o -cmatch 'Folder is out of the Vault\.')
    Check 'every file back as it was' (((Get-Content "$sec\alpha.txt" -Raw) -match 'alpha-changed') -and (Test-Path "$sec\sub\beta.txt") -and (Test-Path "$sec\new.txt") -and ((Get-VaultFileHash "$sec\big.bin") -eq $bigHash))
    Check 'nothing left in the vault' (@((Read-VaultState).vaults).Count -eq 0 -and -not (Has-Secret $env:GUARD_VAULT_ROOT))
    Check 'with no vault left, uninstall may go on (check only)' (-not (Test-GuardVaultInUse))
} finally {
    foreach ($n in 'GUARD_VAULT_ROOT', 'GUARD_VAULT_SOFTCHIP', 'GUARD_VAULT_NOACCOUNT', 'GUARD_VAULT_CODE') { Set-Item "env:$n" '' }
    Remove-Item -LiteralPath $tmp -Recurse -Force -EA SilentlyContinue
}
Write-Host "`n$script:pass passed, $script:fail failed"
