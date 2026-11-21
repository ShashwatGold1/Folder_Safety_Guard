# guard-sign.ps1 - publish a signed guard release. For the publisher only; guard never runs it.
#   guard-sign.ps1 -Setup   once: makes the release key in this PC's TPM chip (your PIN), writes
#                           its public half into the code, and signs the first release
#   guard-sign.ps1          signs the current main as a new release
# Run it in a NORMAL terminal (not admin) inside the repo folder. git runs there without admin
# rights on purpose: an elevated git would run the hooks and settings in .git, which any program
# running as you can plant. Only the signer asks for administrator. It opens in a window of its
# own, downloads the commit from GitHub itself, hashes every file, checks that the key written
# in that commit is this PC's TPM key, shows what it will sign, and needs YES and your PIN.
# The key can't be copied out of the TPM and can't be used without the PIN and admin rights,
# so nobody else (an AI agent included) can publish a release that guard accepts.
#   -SignCommit, -NewKey, -SignOut   used by the script itself for the elevated part
#   -Lib                             tests: define the functions only
# (parameter names nobody else uses: dot-sourced with -Lib, each one becomes a variable in the
#  caller, and PowerShell names ignore case - a -Repo would wipe a test's own $repo)
param([switch]$Setup, [string]$SignRepo = '', [switch]$Lib,
      [string]$SignCommit = '', [switch]$NewKey, [string]$SignOut = '', [string]$SignKeyName = 'guard-release')

if (-not $Lib) { $ErrorActionPreference = 'Stop' }
$signHere = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $signHere 'guard-core.ps1')

$script:PcpName = 'Microsoft Platform Crypto Provider'
function Get-SignProvider { return (New-Object Security.Cryptography.CngProvider $script:PcpName) }
function Get-SignOpenFlags { return ([Security.Cryptography.CngKeyOpenOptions]::MachineKey -bor [Security.Cryptography.CngKeyOpenOptions]::Silent) }
function Test-ReleaseKeyExists([string]$Name) {
    return [Security.Cryptography.CngKey]::Exists($Name, (Get-SignProvider), (Get-SignOpenFlags))
}
function Get-PinBytes([string]$Pin) { return [Text.Encoding]::Unicode.GetBytes($Pin + [char]0) }

function New-ReleaseKey([string]$Name, [string]$Pin) {
    # RSA-2048 in the TPM, machine key (admin only), PIN-protected; returns the base64 modulus
    $cp = New-Object Security.Cryptography.CngKeyCreationParameters
    $cp.Provider = Get-SignProvider
    $cp.KeyCreationOptions = [Security.Cryptography.CngKeyCreationOptions]::MachineKey
    $cp.KeyUsage = [Security.Cryptography.CngKeyUsages]::Signing
    $none = [Security.Cryptography.CngPropertyOptions]::None
    $cp.Parameters.Add((New-Object Security.Cryptography.CngProperty 'Length', ([BitConverter]::GetBytes([int]2048)), $none))
    $cp.Parameters.Add((New-Object Security.Cryptography.CngProperty 'SmartCardPin', (Get-PinBytes $Pin), $none))
    $k = [Security.Cryptography.CngKey]::Create([Security.Cryptography.CngAlgorithm]::Rsa, $Name, $cp)
    try { return (Get-ReleaseKeyModulus $k) } finally { $k.Dispose() }
}
function Get-ReleaseKeyModulus($Key) {
    $blob = $Key.Export([Security.Cryptography.CngKeyBlobFormat]::GenericPublicBlob)
    $pk = [Security.Cryptography.CngKey]::Import($blob, [Security.Cryptography.CngKeyBlobFormat]::GenericPublicBlob)
    $p = (New-Object Security.Cryptography.RSACng $pk).ExportParameters($false)
    if ([Convert]::ToBase64String($p.Exponent) -ne 'AQAB') { throw 'unexpected key exponent' }
    return [Convert]::ToBase64String($p.Modulus)
}
function Get-TpmReleaseModulus([string]$Name) {
    $k = [Security.Cryptography.CngKey]::Open($Name, (Get-SignProvider), (Get-SignOpenFlags))
    try { return (Get-ReleaseKeyModulus $k) } finally { $k.Dispose() }
}
function Invoke-TpmSign([string]$Name, [string]$Pin, [byte[]]$Data) {
    $k = [Security.Cryptography.CngKey]::Open($Name, (Get-SignProvider), (Get-SignOpenFlags))
    try {
        $k.SetProperty((New-Object Security.Cryptography.CngProperty 'SmartCardPin', (Get-PinBytes $Pin), ([Security.Cryptography.CngPropertyOptions]::None)))
        return (New-Object Security.Cryptography.RSACng $k).SignData($Data, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    } finally { $k.Dispose() }
}
function Remove-ReleaseKey([string]$Name) {
    $k = [Security.Cryptography.CngKey]::Open($Name, (Get-SignProvider), (Get-SignOpenFlags)); $k.Delete()
}
function Get-KeyFingerprint([string]$Modulus) {
    $h = Get-GuardSha256 ([Convert]::FromBase64String($Modulus))
    return (($h.Substring(0, 24) -split '(.{4})' | Where-Object { $_ }) -join ' ')
}

function New-GuardReleaseJson([string]$Version, [string]$Commit, $Hashes) {
    # fixed field order and no spaces: the signature is over these exact bytes
    $f = (Get-GuardReleaseFiles | ForEach-Object { '"{0}":"{1}"' -f $_, $Hashes[$_] }) -join ','
    $t = '{"name":"guard","version":"' + $Version + '","commit":"' + $Commit + '","files":{' + $f + '}}'
    return (New-Object Text.UTF8Encoding($false)).GetBytes($t)
}
function Get-CodeKeys([string]$CoreText, [string]$InstallText) {
    $a = ''; $b = ''
    if ($CoreText -match "\`$script:GuardReleaseKey\s*=\s*'([^']*)'") { $a = $Matches[1] }
    if ($InstallText -match "\`$releaseKey\s*=\s*'([^']*)'") { $b = $Matches[1] }
    return @($a, $b)
}
function New-GuardReleaseFolder([string]$Root, [string]$Commit, $FileBytes, [string]$Version, $Signer) {
    # tests: a fake "GitHub" folder (file://): <Root>\<commit>\... and <Root>\main\release.*
    # $FileBytes: repo path -> bytes; $Signer: { param([byte[]]$d) <signature bytes> }
    $h = @{}
    foreach ($f in Get-GuardReleaseFiles) {
        $p = Join-Path (Join-Path $Root $Commit) $f; [void][IO.Directory]::CreateDirectory((Split-Path $p -Parent))
        [IO.File]::WriteAllBytes($p, $FileBytes[$f]); $h[$f] = Get-GuardSha256 $FileBytes[$f]
    }
    $j = New-GuardReleaseJson $Version $Commit $h
    $m = Join-Path $Root 'main'; [void][IO.Directory]::CreateDirectory($m)
    [IO.File]::WriteAllBytes((Join-Path $m 'release.json'), $j)
    [IO.File]::WriteAllText((Join-Path $m 'release.sig'), [Convert]::ToBase64String((& $Signer $j)), (New-Object Text.ASCIIEncoding))
}
function Read-Pin([string]$Prompt) {
    $s = Read-Host $Prompt -AsSecureString
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}
function Exit-Signer([int]$Code, [string]$Msg) {
    if ($Msg) { $c = 'Green'; if ($Code) { $c = 'Red' }; Write-Host ""; Write-Host "  $Msg" -ForegroundColor $c }
    Write-Host ""; Read-Host "  press Enter to close" | Out-Null; exit $Code
}

if ($Lib) { return }

# =========================== elevated part: a window of its own ===========================
if ($NewKey) {
    if (-not (Test-GuardAdmin)) { Exit-Signer 1 'needs administrator' }
    try { $Host.UI.RawUI.WindowTitle = 'guard release key (administrator)' } catch { }
    Write-Host ""; Write-Host "  guard release key - made in this PC's TPM chip, never leaves it"
    if (Test-ReleaseKeyExists $SignKeyName) { Exit-Signer 1 "a release key already exists on this PC ($SignKeyName). nothing was changed." }
    Write-Host "  choose a PIN: at least 12 characters, or 4 random words. it can't be reset or recovered:"
    Write-Host "  write it on paper and keep it away from the PC. a new key = every guard must be reinstalled."
    $p1 = Read-Pin '  PIN'; $p2 = Read-Pin '  PIN again'
    if ($p1 -ne $p2) { Exit-Signer 1 'the two PINs differ. nothing was changed.' }
    if ($p1.Length -lt 12) { Exit-Signer 1 'the PIN is shorter than 12 characters. nothing was changed.' }
    try { $m = New-ReleaseKey $SignKeyName $p1 } catch { Exit-Signer 1 ("the TPM refused: " + $_.Exception.Message) }
    [IO.File]::WriteAllText($SignOut, $m, (New-Object Text.ASCIIEncoding))
    Exit-Signer 0 ("key made - fingerprint  " + (Get-KeyFingerprint $m))
}
if ($SignCommit) {
    if (-not (Test-GuardAdmin)) { Exit-Signer 1 'needs administrator' }
    try { $Host.UI.RawUI.WindowTitle = 'guard release signing (administrator)' } catch { }
    if ($SignCommit -notmatch '^[0-9a-f]{40}$') { Exit-Signer 1 'not a commit id' }
    Write-Host ""; Write-Host "  guard release signing"
    if (-not (Test-ReleaseKeyExists $SignKeyName)) { Exit-Signer 1 'no release key on this PC: run  guard-sign.ps1 -Setup  first' }
    $base = Get-GuardReleaseBase; $bytes = @{}; $h = @{}
    try {
        foreach ($f in Get-GuardReleaseFiles) { $bytes[$f] = Get-GuardBytes "$base/$SignCommit/$f"; $h[$f] = Get-GuardSha256 $bytes[$f] }
    } catch { Exit-Signer 1 ("couldn't download commit $SignCommit from GitHub: " + $_.Exception.Message) }
    $u8 = New-Object Text.UTF8Encoding($false)
    $core = $u8.GetString($bytes['src/guard-core.ps1']); $inst = $u8.GetString($bytes['install.ps1'])
    if ($core -notmatch "GuardVersion\s*=\s*'([\d\.]+)'") { Exit-Signer 1 'no version in guard-core.ps1' }
    $ver = $Matches[1]
    $mine = Get-TpmReleaseModulus $SignKeyName; $keys = Get-CodeKeys $core $inst
    if ($keys[0] -ne $mine -or $keys[1] -ne $mine) { Exit-Signer 1 "the release key written in that commit is not this PC's key. refused: someone changed it." }
    Write-Host ("  version      {0}" -f $ver)
    Write-Host ("  commit       {0}" -f $SignCommit)
    Write-Host ("  files        {0}  (downloaded from GitHub just now, hashed here)" -f $h.Count)
    Write-Host ("  key          {0}" -f (Get-KeyFingerprint $mine))
    Write-Host "  after this, every guard updates to exactly these files. only sign code you meant to publish."
    if ((Read-Host '  type YES to sign').Trim() -ne 'YES') { Exit-Signer 1 'cancelled. nothing was signed.' }
    $json = New-GuardReleaseJson $ver $SignCommit $h
    $pin = Read-Pin '  PIN'
    try { $sig = Invoke-TpmSign $SignKeyName $pin $json } catch { Exit-Signer 1 ("not signed: the TPM refused (wrong PIN?). " + $_.Exception.Message) } finally { $pin = $null }
    try { [void](Read-GuardRelease $json $sig $mine) } catch { Exit-Signer 1 ("the signature doesn't check out: " + $_.Exception.Message) }
    [IO.File]::WriteAllBytes((Join-Path $SignOut 'release.json'), $json)
    [IO.File]::WriteAllText((Join-Path $SignOut 'release.sig'), [Convert]::ToBase64String($sig), (New-Object Text.ASCIIEncoding))
    Exit-Signer 0 "signed - guard $ver. back in your terminal, the release is committed and pushed."
}

# ============================= normal part: your terminal =================================
function Say([string]$t, [string]$c = 'Gray') { Write-Host "  $t" -ForegroundColor $c }
# (git.exe: PowerShell names ignore case, so a plain  git  here would call this function again, forever)
function Git { $ErrorActionPreference = 'Continue'; $o = & git.exe -C $script:R @args 2>&1 | ForEach-Object { "$_" }; if ($LASTEXITCODE) { throw ("git " + ($args -join ' ') + ": " + ($o | Out-String).Trim()) }; return $o }
if (Test-GuardAdmin) { Say 'run this in a NORMAL terminal (not administrator): git must not run with admin rights here.' 'Red'; exit 1 }
if (-not $SignRepo) { $SignRepo = Split-Path $signHere -Parent }
$script:R = (& git.exe -C $SignRepo rev-parse --show-toplevel 2>$null); if (-not $script:R) { Say "not a git repo: $SignRepo" 'Red'; exit 1 }
$script:R = $script:R -replace '/', '\'
try {
    if ((Git rev-parse --abbrev-ref HEAD) -ne 'main') { throw 'switch to the main branch first' }
    if (Git status --porcelain) { throw 'commit or undo your changes first (git status is not clean)' }
    # the elevated part: the copy in Program Files when guard is installed (only admins can change
    # it). Before that (the very first -Setup) this copy, which any program running as you could edit.
    $pf = Get-GuardProgramFiles; $signer = Join-Path $pf 'guard\guard-sign.ps1'
    if (-not (Test-Path -LiteralPath $signer)) {
        $signer = $MyInvocation.MyCommand.Path
        Say "guard isn't installed: using this copy of the signer. later releases use the one in Program Files." 'Yellow'
    }
    $ps = Get-GuardPowerShellExe
    $coreP = Join-Path $script:R 'src\guard-core.ps1'; $instP = Join-Path $script:R 'install.ps1'
    $u8b = New-Object Text.UTF8Encoding($true); $u8 = New-Object Text.UTF8Encoding($false)
    $coreT = [IO.File]::ReadAllText($coreP); $instT = [IO.File]::ReadAllText($instP)
    $keys = Get-CodeKeys $coreT $instT
    if ($Setup) {
        if ($keys[0] -or $keys[1]) { throw 'a release key is already written in the code: setup was done. to sign, run without -Setup' }
        $kf = Join-Path $script:R ('release-key-' + [guid]::NewGuid().ToString('N') + '.txt')
        Say 'a window asks for administrator, then for a new PIN.'
        $p = Start-Process $ps -Verb RunAs -PassThru -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$signer`" -NewKey -SignOut `"$kf`""
        if ($p.ExitCode -or -not (Test-Path -LiteralPath $kf)) { throw 'no key was made' }
        $m = ([IO.File]::ReadAllText($kf)).Trim(); Remove-Item -LiteralPath $kf -Force
        if ($m -notmatch '^[A-Za-z0-9+/=]{340,}$') { throw 'the key file is malformed' }
        # (the signer later checks this is really the TPM's key: a swapped file is caught there)
        $coreT = $coreT.Replace("`$script:GuardReleaseKey  = ''", "`$script:GuardReleaseKey  = '$m'")
        $instT = $instT.Replace("`$releaseKey  = ''", "`$releaseKey  = '$m'")
        [IO.File]::WriteAllText($coreP, $coreT, $u8b); [IO.File]::WriteAllText($instP, $instT, $u8)
        $keys = Get-CodeKeys $coreT $instT
        if ($keys[0] -ne $m -or $keys[1] -ne $m) { throw "couldn't write the key into the code" }
        Git add src/guard-core.ps1 install.ps1 | Out-Null
        Git commit -q -m ("guard release key " + (Get-KeyFingerprint $m)) | Out-Null
        Say ("key written into the code - fingerprint  " + (Get-KeyFingerprint $m)) 'Green'
    }
    if (-not $keys[0]) { throw 'no release key in the code yet: run  guard-sign.ps1 -Setup' }
    # a release must be newer than the last one: raise the version when it isn't
    $ver = '0'; if ($coreT -match "GuardVersion\s*=\s*'([\d\.]+)'") { $ver = $Matches[1] }
    $prev = $null; $rj = Join-Path $script:R 'release.json'
    if (Test-Path -LiteralPath $rj) { try { $prev = ([IO.File]::ReadAllText($rj) | ConvertFrom-Json) } catch { } }
    if ($prev -and -not ([version]$ver -gt [version]$prev.version)) {
        $pv = [version]$prev.version; $new = '{0}.{1}' -f $pv.Major, ($pv.Minor + 1)
        $coreT = $coreT -replace "GuardVersion = '[\d\.]+'", "GuardVersion = '$new'"
        [IO.File]::WriteAllText($coreP, $coreT, $u8b)
        Git add src/guard-core.ps1 | Out-Null; Git commit -q -m "guard $new" | Out-Null
        Say "version raised to $new"; $ver = $new
    }
    Say 'pushing main ...'; Git push -q origin main | Out-Null
    $sha = (Git rev-parse HEAD).Trim()
    if ($prev) { Say ("since release {0}:" -f $prev.version); Git log --oneline "$($prev.commit)..$sha" | ForEach-Object { Say "  $_" 'DarkGray' } }
    Say 'a window asks for administrator, then shows what it signs: check it, type YES and your PIN.'
    $p = Start-Process $ps -Verb RunAs -PassThru -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$signer`" -SignCommit $sha -SignOut `"$($script:R)`""
    if ($p.ExitCode) { throw 'not signed (see the signing window). nothing was published.' }
    # ($signed, not $r: names ignore case, and $r is $script:R, the repo folder)
    $signed = Read-GuardRelease ([IO.File]::ReadAllBytes($rj)) ([Convert]::FromBase64String(([IO.File]::ReadAllText((Join-Path $script:R 'release.sig'))).Trim())) $keys[0]
    if ($signed.commit -ne $sha) { throw 'the signed list is for another commit' }
    Git add release.json release.sig | Out-Null; Git commit -q -m "release $ver" | Out-Null
    Git push -q origin main | Out-Null
    Say ("guard {0} is released - signed commit {1}" -f $ver, $sha.Substring(0, 10)) 'Green'
} catch { Say $_.Exception.Message 'Red'; exit 1 }
