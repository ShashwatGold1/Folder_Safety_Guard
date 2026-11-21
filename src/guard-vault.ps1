# guard-vault.ps1 - the Security Vault: protected folders nobody can read without the guard PIN.
#   security vault on    PIN (the first time: choose it, recovery code for paper). Then every
#                        protected folder is sealed: each file goes into the vault, checked, and
#                        an empty placeholder with the same name stays (shield badge, locked).
#   security vault off   PIN, then every file comes back (still delete-protected as before)
#   security vault       on or off, how many files are unlocked right now
#   security vault pin   changes the PIN
#   right-click a placeholder -> "Unlock with guard": Windows asks Yes, guard asks the PIN, only
#   that file (or folder) is real again. Every change goes into the vault within 5 seconds; it
#   locks again 15 minutes after it was opened, once no program uses it, and always at sign-in.
#   New files in a sealed folder are sealed by themselves. Nothing ever says where the vault is.
#
# How it holds:
#  - every file is encrypted (AES-256 + HMAC-SHA256) with a key of its own. That key is locked
#    with the vault's data key; the data key's private half is locked with a 64-byte vault key,
#    and the vault key is locked by a key in this PC's TPM chip that only works with the PIN.
#    The chip counts wrong PINs and slows guessing down. A second copy of the vault key is
#    locked with the recovery code (paper only), for a new PC, a cleared chip or a lost PIN.
#  - putting a file IN needs only the public half: guard can save changes back (close, and
#    the background guard's auto-close) without the PIN. Getting one OUT always needs the PIN.
#  - the encrypted files sit in a hidden folder, owned by a hidden, switched-off account
#    (guard-vault) that nobody signs in with. Only that account, SYSTEM and administrators may
#    touch the folder; you, Explorer and every program running as you get "access denied".
#    An administrator who takes the files anyway gets only scrambled bytes.
# Works in guard's own window (admin) and in the background guard (SYSTEM, auto-close only).

$script:VaultTrusted = @('S-1-5-18', 'S-1-5-32-544')
$script:VaultMagic = [Text.Encoding]::ASCII.GetBytes('GVF1')
$script:VaultCloseMin = 15
$script:SecureLockMin = 15   # an unlocked file locks again 15 minutes after it was opened (once no program uses it)
$script:SecureLater = @()

# ---- settings (test overrides only in test mode: see Get-GuardTestEnv) ------------------
function Test-VaultTestMode { return [bool](Get-GuardTestEnv 'GUARD_VAULT_ROOT') }
function Get-VaultStatePath { return (Join-Path (Split-Path $script:GuardConfigPath -Parent) 'vault.json') }
function Get-VaultAccount { $a = Get-GuardTestEnv 'GUARD_VAULT_ACCOUNT'; if ($a) { return $a }; return 'guard-vault' }
function Test-VaultSoftChip { return [bool](Get-GuardTestEnv 'GUARD_VAULT_SOFTCHIP') }
# tests without admin rights can't set owners: those steps are skipped there (and only there)
function Test-VaultNoAcl { return ((Test-VaultTestMode) -and -not (Test-GuardAdmin)) }
function Get-VaultRootFor([string]$Path = '') {
    # one hidden place for every sealed file (guard never tells the user where it is)
    $r = Get-GuardTestEnv 'GUARD_VAULT_ROOT'; if ($r) { return $r.TrimEnd('\') }
    return (Join-Path (Get-GuardProgramData) 'guard-sv')
}

# ---- bytes ------------------------------------------------------------------------------
function New-VaultRandom([int]$N) {
    $b = New-Object byte[] $N; $g = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $g.GetBytes($b) } finally { $g.Dispose() }
    return ,$b
}
function Get-VaultPart([byte[]]$B, [int]$Start, [int]$Len) { $o = New-Object byte[] $Len; [Array]::Copy($B, $Start, $o, 0, $Len); return ,$o }
function Join-VaultBytes { $ms = New-Object IO.MemoryStream; foreach ($a in $args) { $ms.Write([byte[]]$a, 0, $a.Length) }; return ,$ms.ToArray() }
function Test-VaultSame([byte[]]$A, [byte[]]$B) {
    if ($null -eq $A -or $null -eq $B -or $A.Length -ne $B.Length) { return $false }
    $d = 0; for ($i = 0; $i -lt $A.Length; $i++) { $d = $d -bor ($A[$i] -bxor $B[$i]) }
    return ($d -eq 0)
}
function New-VaultAes([byte[]]$Key, [byte[]]$Iv) {
    $a = [Security.Cryptography.Aes]::Create(); $a.Mode = 'CBC'; $a.Padding = 'PKCS7'; $a.Key = $Key
    if ($Iv) { $a.IV = $Iv } else { $a.GenerateIV() }
    return $a
}
function Protect-VaultBytes([byte[]]$Data, [byte[]]$Key64) {
    # iv | ciphertext | HMAC(iv | ciphertext)
    $aes = New-VaultAes (Get-VaultPart $Key64 0 32) $null
    try { $ct = $aes.CreateEncryptor().TransformFinalBlock($Data, 0, $Data.Length); $body = Join-VaultBytes $aes.IV $ct } finally { $aes.Dispose() }
    $h = New-Object Security.Cryptography.HMACSHA256 (,(Get-VaultPart $Key64 32 32))
    try { $mac = $h.ComputeHash($body) } finally { $h.Dispose() }
    return ,(Join-VaultBytes $body $mac)
}
function Unprotect-VaultBytes([byte[]]$Blob, [byte[]]$Key64) {
    if (-not $Blob -or $Blob.Length -lt 64) { throw 'damaged' }
    $body = Get-VaultPart $Blob 0 ($Blob.Length - 32); $mac = Get-VaultPart $Blob ($Blob.Length - 32) 32
    $h = New-Object Security.Cryptography.HMACSHA256 (,(Get-VaultPart $Key64 32 32))
    try { $ok = Test-VaultSame $h.ComputeHash($body) $mac } finally { $h.Dispose() }
    if (-not $ok) { throw 'wrong key or damaged' }
    $aes = New-VaultAes (Get-VaultPart $Key64 0 32) (Get-VaultPart $body 0 16)
    try { return ,$aes.CreateDecryptor().TransformFinalBlock($body, 16, $body.Length - 16) } finally { $aes.Dispose() }
}
function Get-VaultStretch([string]$Secret, [byte[]]$Salt, [int]$Iter) {
    $d = New-Object Security.Cryptography.Rfc2898DeriveBytes($Secret, $Salt, $Iter, [Security.Cryptography.HashAlgorithmName]::SHA256)
    try { return ,$d.GetBytes(64) } finally { $d.Dispose() }
}
function Get-VaultSha([byte[]]$B) { return -join ([Security.Cryptography.SHA256]::Create().ComputeHash($B) | ForEach-Object { $_.ToString('x2') }) }
function Get-VaultFileHash([string]$Path) {
    $s = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try { return -join ([Security.Cryptography.SHA256]::Create().ComputeHash($s) | ForEach-Object { $_.ToString('x2') }) } finally { $s.Dispose() }
}

# ---- the TPM chip: a machine key that only works with the PIN ---------------------------
function Get-VaultChipProvider { return (New-Object Security.Cryptography.CngProvider 'Microsoft Platform Crypto Provider') }
function Get-VaultChipFlags { return ([Security.Cryptography.CngKeyOpenOptions]::MachineKey -bor [Security.Cryptography.CngKeyOpenOptions]::Silent) }
function Get-VaultPinBytes([string]$Pin) { return ,[Text.Encoding]::Unicode.GetBytes($Pin + [char]0) }
function Protect-VaultChip([byte[]]$Key, [string]$Pin, [string]$KeyName) {
    # returns the chip-locked copy of $Key (base64); makes the chip key
    if (Test-VaultSoftChip) {
        # tests only: the same steps with a PIN-stretched key instead of the chip
        $salt = New-VaultRandom 16
        return [Convert]::ToBase64String((Join-VaultBytes $salt (Protect-VaultBytes $Key (Get-VaultStretch $Pin $salt 20000))))
    }
    $cp = New-Object Security.Cryptography.CngKeyCreationParameters
    $cp.Provider = Get-VaultChipProvider
    $cp.KeyCreationOptions = [Security.Cryptography.CngKeyCreationOptions]::MachineKey
    $cp.KeyUsage = [Security.Cryptography.CngKeyUsages]::Decryption
    $none = [Security.Cryptography.CngPropertyOptions]::None
    $cp.Parameters.Add((New-Object Security.Cryptography.CngProperty 'Length', ([BitConverter]::GetBytes([int]2048)), $none))
    $cp.Parameters.Add((New-Object Security.Cryptography.CngProperty 'SmartCardPin', (Get-VaultPinBytes $Pin), $none))
    $k = [Security.Cryptography.CngKey]::Create([Security.Cryptography.CngAlgorithm]::Rsa, $KeyName, $cp)
    try { $blob = $k.Export([Security.Cryptography.CngKeyBlobFormat]::GenericPublicBlob) } finally { $k.Dispose() }
    $pub = New-Object Security.Cryptography.RSACng ([Security.Cryptography.CngKey]::Import($blob, [Security.Cryptography.CngKeyBlobFormat]::GenericPublicBlob))
    return [Convert]::ToBase64String($pub.Encrypt($Key, [Security.Cryptography.RSAEncryptionPadding]::OaepSHA256))
}
function Unprotect-VaultChip([string]$Wrapped, [string]$Pin, [string]$KeyName) {
    $w = [Convert]::FromBase64String($Wrapped)
    if (Test-VaultSoftChip) {
        try { return ,(Unprotect-VaultBytes (Get-VaultPart $w 16 ($w.Length - 16)) (Get-VaultStretch $Pin (Get-VaultPart $w 0 16) 20000)) } catch { throw 'wrong PIN' }
    }
    if (-not [Security.Cryptography.CngKey]::Exists($KeyName, (Get-VaultChipProvider), (Get-VaultChipFlags))) { throw 'the vault key is not in this PC''s chip (new PC, or the chip was cleared): type  recovery  at the PIN question' }
    $k = [Security.Cryptography.CngKey]::Open($KeyName, (Get-VaultChipProvider), (Get-VaultChipFlags))
    try {
        $k.SetProperty((New-Object Security.Cryptography.CngProperty 'SmartCardPin', (Get-VaultPinBytes $Pin), ([Security.Cryptography.CngPropertyOptions]::None)))
        return ,(New-Object Security.Cryptography.RSACng $k).Decrypt($w, [Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
    } catch {
        $m = "$($_.Exception.Message) $($_.Exception.InnerException.Message)"
        if ($m -match 'lock|block') { throw 'the chip is locked after too many wrong PINs: wait 2 hours, or type  recovery  at the PIN question' }
        if ($m -match 'denied|incorrect|PIN') { throw 'wrong PIN (the chip counts every wrong try)' }
        throw $m.Trim()
    } finally { $k.Dispose() }
}
function Remove-VaultChipKey([string]$KeyName) {
    if ((Test-VaultSoftChip) -or -not $KeyName) { return }
    try { if ([Security.Cryptography.CngKey]::Exists($KeyName, (Get-VaultChipProvider), (Get-VaultChipFlags))) { ([Security.Cryptography.CngKey]::Open($KeyName, (Get-VaultChipProvider), (Get-VaultChipFlags))).Delete() } } catch { }
}

# ---- the recovery code: 30 digits, on paper only ----------------------------------------
function New-VaultRecoveryCode {
    $t = Get-GuardTestEnv 'GUARD_VAULT_CODE'; if ($t -and (Test-VaultTestMode)) { return $t }   # tests type it back
    $b = New-VaultRandom 30; $d = -join ($b | ForEach-Object { [string]($_ % 10) })
    # (x % 10 over 0..255 is very slightly uneven; 30 digits keep it far above 90 bits)
    return (($d -split '(.{5})' | Where-Object { $_ }) -join '-')
}
function Get-VaultCodeDigits([string]$Code) { return ($Code -replace '[^0-9]', '') }

# ---- the state: ProgramData\guard\vault.json, and a copy in every vault folder root ------
function Read-VaultState {
    $p = Get-VaultStatePath
    $cands = @($p, (Join-Path (Get-VaultRootFor) 'vault-keys.json'))
    $best = $null
    foreach ($c in $cands) {
        # (a drive that is locked, or one this account can't read, is skipped, never an error)
        try { if (-not (Test-Path -LiteralPath $c -ErrorAction Stop)) { continue } } catch { continue }
        if (-not (Test-VaultTestMode) -and -not (Test-GuardTrustedOwner $c)) { continue }
        try { $s = [IO.File]::ReadAllText($c) | ConvertFrom-Json } catch { continue }
        if (-not $s.dataPub) { continue }
        if (-not $best -or [string]$s.saved -gt [string]$best.saved) { $best = $s }
    }
    if ($best) {
        foreach ($k in 'vaults', 'open') { if (-not $best.PSObject.Properties[$k]) { $best | Add-Member -NotePropertyName $k -NotePropertyValue @() } }
        $best.vaults = @($best.vaults | Where-Object { $_ }); $best.open = @($best.open | Where-Object { $_ })
    }
    return $best
}
function Save-VaultState($S) {
    $S.saved = (Get-Date).ToString('o')
    $json = $S | ConvertTo-Json -Depth 10
    $targets = @(Get-VaultStatePath)
    if (Test-Path -LiteralPath (Get-VaultRootFor)) { $targets += (Join-Path (Get-VaultRootFor) 'vault-keys.json') }
    foreach ($t in $targets) {
        $d = Split-Path $t -Parent; if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        $tmp = "$t.tmp"
        [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $t -Force
    }
}
function Update-VaultState([scriptblock]$VaultChange, [switch]$VaultTry) {
    # guard's window and the background guard both change the files: one at a time.
    # -VaultTry (the background guard): busy right now = do nothing, returns $false (next tick again)
    # (odd names: the block runs in here and sees these, so they must not hide the caller's)
    $vaultMx = $null; $vaultGot = $false
    $vaultWait = 60000; if ($VaultTry) { $vaultWait = 0 }
    try { $vaultMx = New-Object Threading.Mutex($false, 'Global\guard-vault-state'); try { $vaultGot = $vaultMx.WaitOne($vaultWait) } catch [Threading.AbandonedMutexException] { $vaultGot = $true } } catch { }
    if ($VaultTry -and -not $vaultGot) { if ($vaultMx) { $vaultMx.Dispose() }; return $false }
    try {
        $vaultNow = Read-VaultState; if (-not $vaultNow) { throw 'no vault' }
        [void](& $VaultChange $vaultNow)
        Save-VaultState $vaultNow
        return $true
    } finally { if ($vaultGot) { try { $vaultMx.ReleaseMutex() } catch { } }; if ($vaultMx) { $vaultMx.Dispose() } }
}

# ---- the hidden owner account and the vault folder's permissions --------------------------
function Get-VaultAccountSid {
    # (MachineName from Windows, not %COMPUTERNAME%: any program can set that for the elevated guard)
    try { return (New-Object Security.Principal.NTAccount("$([Environment]::MachineName)\$(Get-VaultAccount)")).Translate([Security.Principal.SecurityIdentifier]).Value } catch { return $null }
}
function Initialize-VaultAccount {
    # a local account that is switched off: it can own files, nobody can ever sign in with it
    if (Get-GuardTestEnv 'GUARD_VAULT_NOACCOUNT') { return 'S-1-5-32-544' }
    $name = Get-VaultAccount
    $u = $null; try { $u = Get-LocalUser -Name $name -ErrorAction Stop } catch { }
    if (-not $u) {
        New-LocalUser -Name $name -NoPassword -AccountNeverExpires -UserMayNotChangePassword -Description 'owns the guard vault; nobody signs in' -ErrorAction Stop | Out-Null   # (Windows: 48 characters at most)
    }
    Disable-LocalUser -Name $name -ErrorAction Stop
    if ((Get-LocalUser -Name $name).Enabled) { throw "the $name account could not be switched off" }
    $sid = Get-VaultAccountSid; if (-not $sid) { throw "the $name account was not found after making it" }
    return $sid
}
function Initialize-VaultRoot([string]$Root, [string]$OwnerSid) {
    # <drive>:\guard-vault. Any user can make folders at a drive root, so one that is already
    # there and not made by guard is refused (it could hold planted files or point elsewhere).
    if (Test-Path -LiteralPath $Root) {
        $it = Get-Item -LiteralPath $Root -Force
        if ($it.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$Root is a link to somewhere else: rename or delete it first" }
        if (-not (Test-VaultTestMode)) {
            $o = (Get-Acl -LiteralPath $Root).GetOwner([Security.Principal.SecurityIdentifier]).Value
            if (($script:VaultTrusted + @($OwnerSid)) -notcontains $o) { throw "$Root already exists and wasn't made by guard: rename or delete it first" }
        }
    } else { New-Item -ItemType Directory -Path $Root -Force | Out-Null }
    try { (Get-Item -LiteralPath $Root -Force).Attributes = 'Directory, Hidden, System' } catch { }
    if (Test-VaultNoAcl) { return }
    $r = Invoke-Icacls @($Root, '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', "*${OwnerSid}:(OI)(CI)F")
    if (-not $r.Ok) { throw "couldn't set the vault folder's permissions: $($r.Out)" }
    Set-VaultOwner $Root $OwnerSid
}
function Set-VaultOwner([string]$Path, [string]$OwnerSid) {
    if (Test-VaultNoAcl) { return }
    $r = Invoke-Icacls @($Path, '/setowner', "*$OwnerSid", '/T', '/C')
    if (-not $r.Ok) { throw "couldn't give the vault files to the vault account: $($r.Out)" }
}

# ---- one file in, one file out ---------------------------------------------------------
# file: "GVF1" | HMAC(32) | len(2) | file key locked with the data key | iv(16) | ciphertext
#       HMAC over everything after itself, with the file's own MAC key
function Write-VaultFile([string]$Plain, [string]$Out, [string]$PubXml) {
    $fk = New-VaultRandom 64
    $rsa = New-Object Security.Cryptography.RSACng; $rsa.FromXmlString($PubXml)
    $wrap = $rsa.Encrypt($fk, [Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
    $aes = New-VaultAes (Get-VaultPart $fk 0 32) $null
    $d = Split-Path $Out -Parent; if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    $tmp = "$Out.new-" + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $fs = [IO.File]::Open($tmp, 'CreateNew', 'ReadWrite', 'None')
    try {
        $fs.Write($script:VaultMagic, 0, 4); $fs.Write((New-Object byte[] 32), 0, 32)
        $fs.Write([BitConverter]::GetBytes([uint16]$wrap.Length), 0, 2); $fs.Write($wrap, 0, $wrap.Length); $fs.Write($aes.IV, 0, 16)
        $in = [IO.File]::Open($Plain, 'Open', 'Read', 'ReadWrite')
        try { $cs = New-Object Security.Cryptography.CryptoStream($fs, $aes.CreateEncryptor(), 'Write'); $in.CopyTo($cs); $cs.FlushFinalBlock() } finally { $in.Dispose() }
        $fs.Position = 36
        $h = New-Object Security.Cryptography.HMACSHA256 (,(Get-VaultPart $fk 32 32)); $mac = $h.ComputeHash($fs); $h.Dispose()
        $fs.Position = 4; $fs.Write($mac, 0, 32); $fs.Flush()
    } catch { $fs.Dispose(); Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue; throw } finally { $fs.Dispose(); $aes.Dispose() }
    Move-Item -LiteralPath $tmp -Destination $Out -Force
    return ,$fk   # the file's own key: lets the writer check the new file without the PIN
}
function Read-VaultFile([string]$Gv, [string]$Out, $Priv, [byte[]]$FileKey = $null) {
    # checks the file, then writes the plain bytes to $Out (or nowhere); returns their SHA-256.
    # -FileKey: the key Write-VaultFile just used (a check right after writing, no PIN needed)
    $fs = [IO.File]::Open($Gv, 'Open', 'Read', 'Read')
    try {
        $br = New-Object IO.BinaryReader($fs)
        if (-not (Test-VaultSame $br.ReadBytes(4) $script:VaultMagic)) { throw 'not a vault file' }
        $mac = $br.ReadBytes(32); $wl = [int]$br.ReadUInt16(); $wrap = $br.ReadBytes($wl)
        if ($FileKey) { $fk = $FileKey }
        else { try { $fk = $Priv.Decrypt($wrap, [Security.Cryptography.RSAEncryptionPadding]::OaepSHA256) } catch { throw 'damaged or changed (its key does not open)' } }
        $fs.Position = 36
        $h = New-Object Security.Cryptography.HMACSHA256 (,(Get-VaultPart $fk 32 32)); $calc = $h.ComputeHash($fs); $h.Dispose()
        if (-not (Test-VaultSame $calc $mac)) { throw 'damaged or changed after it was locked' }
        $fs.Position = 38 + $wl; $iv = $br.ReadBytes(16)
        $aes = New-VaultAes (Get-VaultPart $fk 0 32) $iv
        $cs = New-Object Security.Cryptography.CryptoStream($fs, $aes.CreateDecryptor(), 'Read')
        $sha = [Security.Cryptography.SHA256]::Create(); $o = $null; $tmp = $null
        if ($Out) {
            $dd = Split-Path $Out -Parent; if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }
            $tmp = "$Out.open-" + [guid]::NewGuid().ToString('N').Substring(0, 8); $o = [IO.File]::Open($tmp, 'CreateNew', 'Write', 'None')
        }
        try {
            $buf = New-Object byte[] 1048576
            while (($n = $cs.Read($buf, 0, $buf.Length)) -gt 0) { [void]$sha.TransformBlock($buf, 0, $n, $null, 0); if ($o) { $o.Write($buf, 0, $n) } }
            [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        } catch { if ($o) { $o.Dispose(); Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue }; throw }
        if ($o) { $o.Dispose(); Move-Item -LiteralPath $tmp -Destination $Out -Force }
        $aes.Dispose()
        return (-join ($sha.Hash | ForEach-Object { $_.ToString('x2') }))
    } finally { $fs.Dispose() }
}
function Remove-VaultPlain([string]$Path) {
    # overwrite with zeros, then delete (on an SSD old blocks may linger: C: BitLocker covers them)
    try {
        $s = [IO.File]::Open($Path, 'Open', 'Write', 'None')
        try { $z = New-Object byte[] 1048576; $left = $s.Length; while ($left -gt 0) { $n = [Math]::Min($left, $z.Length); $s.Write($z, 0, $n); $left -= $n }; $s.Flush() } finally { $s.Dispose() }
    } catch { }
    Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
}

# ---- paths a program without admin rights could bend ------------------------------------
function Test-VaultLinkFree([string]$Path) {
    # no folder on the way (drive root down to $Path) may be a link: guard writes there as admin
    $p = $Path
    while ($p -and (Split-Path $p -Parent)) {
        if (Test-Path -LiteralPath $p) { if ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false } }
        $p = Split-Path $p -Parent
    }
    return $true
}
function Test-VaultPlainOk([string]$Path, [string]$UserSid) {
    # an open copy guard may read back: a real file of the user's, not a link to some other file
    try {
        $it = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($it.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
        if (-not (Test-VaultLinkFree (Split-Path $Path -Parent))) { return $false }
        if (Test-VaultNoAcl) { return $true }
        $o = (Get-Acl -LiteralPath $Path).GetOwner([Security.Principal.SecurityIdentifier]).Value
        return ($o -eq $UserSid)
    } catch { return $false }
}
function Test-VaultSingleLink([string]$Path) {
    # A file with a second name somewhere else (a hard link) is never read, sealed or wiped:
    # that other name could be a Windows file, and sealing wipes the bytes of both names.
    if (Test-VaultNoAcl) { return $true }
    try { $o = @(& (Get-GuardTool 'fsutil.exe') hardlink list $Path 2>$null | Where-Object { $_ -and "$_".Trim() }) } catch { return $false }
    if ($LASTEXITCODE) { return $false }
    return ($o.Count -eq 1)
}
function Get-VaultUserSid([string]$User) {
    try { return (New-Object Security.Principal.NTAccount($User)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { return $null }
}
function Set-VaultPlainOwner([string]$Path, [string]$User) {
    # an open copy belongs to you, like any file you saved yourself
    if (Test-VaultNoAcl) { return }
    Invoke-Icacls @($Path, '/setowner', $User) | Out-Null
}

# ---- the vault's contents ---------------------------------------------------------------
function Get-VaultDir($V) { return (Join-Path $V.root $V.id) }
function Get-VaultEntries($V) {
    # every locked file: @{ Rel = 'sub\a.txt'; Gv = full path }
    $d = Get-VaultDir $V
    if (-not (Test-Path -LiteralPath $d)) { return @() }
    return @(Get-ChildItem -LiteralPath $d -Recurse -File -Force -Filter '*.gv' -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{ Rel = $_.FullName.Substring($d.Length + 1, $_.FullName.Length - $d.Length - 4); Gv = $_.FullName }
    })
}
function Open-VaultKeys($S, [string]$Secret, [switch]$Recovery) {
    # PIN (or recovery code) -> the data key's private half, in memory only
    if ($Recovery) {
        $k = $null
        try { $k = Unprotect-VaultBytes ([Convert]::FromBase64String($S.recWrap)) (Get-VaultStretch (Get-VaultCodeDigits $Secret) ([Convert]::FromBase64String($S.recSalt)) ([int]$S.recIter)) } catch { throw 'wrong recovery code' }
    } else { $k = Unprotect-VaultChip $S.chipWrap $Secret $S.keyName }
    $xml = [Text.Encoding]::UTF8.GetString((Unprotect-VaultBytes ([Convert]::FromBase64String($S.dataPriv)) $k))
    $r = New-Object Security.Cryptography.RSACng; $r.FromXmlString($xml)
    return @{ Priv = $r; Key = $k }
}

# ---- sealing: a real file becomes a sealed copy + an empty placeholder (no PIN needed) ------
# In a sealed folder every file is a placeholder: an empty file with the same name and date,
# locked against delete and against writing. The real bytes are only in the vault.
function Test-SecurityOn { $s = Read-VaultState; return [bool]($s -and $s.on) }
function Get-SecureVault($S, [string]$Path) {
    # the sealed folder $Path is in (or is), or $null
    foreach ($v in @($S.vaults)) { $vp = $v.path.TrimEnd('\'); if ($Path -ieq $vp -or $Path.StartsWith($vp + '\', [StringComparison]::OrdinalIgnoreCase)) { return $v } }
    return $null
}
function Get-SecureRel($V, [string]$Full) { return $Full.Substring($V.path.TrimEnd('\').Length + 1) }
function Get-SecureGv($V, [string]$Rel) { return (Join-Path (Get-VaultDir $V) ($Rel + '.gv')) }
function Get-SecureOpen($S, [string]$Full) { return @($S.open | Where-Object { $_.plain -ieq $Full })[0] }
function Test-SecurePlaceholder($V, [string]$Full) {
    try { $it = Get-Item -LiteralPath $Full -Force -ErrorAction Stop } catch { return $false }
    return ((-not $it.PSIsContainer) -and $it.Length -eq 0 -and (Test-Path -LiteralPath (Get-SecureGv $V (Get-SecureRel $V $Full))))
}
function Set-SecurePlaceholder([string]$Full, [datetime]$When, [string]$User) {
    # an empty file with the same name and date: nothing can be written into it, nor delete it
    [IO.File]::WriteAllBytes($Full, (New-Object byte[] 0))
    try { (Get-Item -LiteralPath $Full -Force).LastWriteTime = $When } catch { }
    if (Test-VaultNoAcl) { return }
    Lock-GuardFile -Path $Full -User $User -Force | Out-Null
    Invoke-Icacls @($Full, '/deny', ($User + ':(W)')) | Out-Null
}
function New-SecureVaultEntry($S, [string]$Folder) {
    $v = [pscustomobject]@{ id = [guid]::NewGuid().ToString('N').Substring(0, 12); path = $Folder.TrimEnd('\'); root = (Get-VaultRootFor); added = (Get-Date).ToString('o') }
    New-Item -ItemType Directory -Path (Get-VaultDir $v) -Force | Out-Null
    $S.vaults = @($S.vaults) + @($v)
    return $v
}
function Protect-SecureFile($S, $V, [string]$Full, [string]$User, $Priv = $null) {
    # real file -> sealed copy (checked: decrypts to the same bytes) -> placeholder.
    # Returns 'sealed', 'busy' (try again later), 'gone' or 'fail: <why>'. Never loses a file:
    # the old sealed copy is replaced only by a checked new one, the real file goes only after that.
    try { $it = Get-Item -LiteralPath $Full -Force -ErrorAction Stop } catch { return 'gone' }
    if ($it.Attributes -band [IO.FileAttributes]::ReparsePoint) { return 'fail: a link, not a file' }
    if (-not (Test-VaultLinkFree (Split-Path $Full -Parent))) { return 'fail: a folder on the way is a link' }
    if (-not (Test-VaultSingleLink $Full)) { return 'fail: a hard link to another file' }
    if (Test-GuardBusy $Full) { return 'busy' }
    $when = $it.LastWriteTime
    try { $h1 = Get-VaultFileHash $Full } catch { return 'busy' }
    $gv = Get-SecureGv $V (Get-SecureRel $V $Full); $new = "$gv.check"
    try { $fk = Write-VaultFile $Full $new $S.dataPub } catch { Remove-Item -LiteralPath $new -Force -EA SilentlyContinue; return ('fail: ' + $_.Exception.Message) }
    $h2 = $null
    try { if ($Priv) { $h2 = Read-VaultFile $new $null $Priv } else { $h2 = Read-VaultFile $new $null $null -FileKey $fk } } catch { }
    if ($h2 -ne $h1) { Remove-Item -LiteralPath $new -Force -EA SilentlyContinue; return 'fail: the sealed copy did not check out' }
    try { $h3 = Get-VaultFileHash $Full } catch { $h3 = $null }
    if ($h3 -ne $h1) { Remove-Item -LiteralPath $new -Force -EA SilentlyContinue; return 'busy' }   # changed meanwhile
    Move-Item -LiteralPath $new -Destination $gv -Force
    try { Set-VaultOwner $gv $S.ownerSid } catch { }
    if (-not (Test-VaultNoAcl)) { Unlock-GuardFile -Path $Full -User $User | Out-Null }
    try { Remove-VaultPlain $Full } catch { return 'busy' }
    Set-SecurePlaceholder $Full $when $User
    return 'sealed'
}
function Open-SecureFile($S, $V, [string]$Full, [string]$User, $Priv) {
    # placeholder -> the real file, yours, for a while. Returns its SHA-256. Throws on any problem.
    $gv = Get-SecureGv $V (Get-SecureRel $V $Full)
    if (-not (Test-Path -LiteralPath $gv)) { throw 'not in the security vault' }
    if (-not (Test-VaultLinkFree (Split-Path $Full -Parent))) { throw 'a folder on the way is a link: refused' }
    if ((Test-Path -LiteralPath $Full) -and -not (Test-SecurePlaceholder $V $Full)) { throw 'a different file is in its place: refused' }
    $tmp = "$Full.guard-" + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $h = Read-VaultFile $gv $tmp $Priv                     # checked before the placeholder goes
    if (-not (Test-VaultNoAcl)) { Unlock-GuardFile -Path $Full -User $User | Out-Null }
    try { Remove-Item -LiteralPath $Full -Force -ErrorAction Stop } catch { Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue; throw 'the placeholder could not be replaced' }
    Move-Item -LiteralPath $tmp -Destination $Full
    Set-VaultPlainOwner $Full $User
    return $h
}
function Sync-SecureItem($S, $Item, [string]$User) {
    # every 5 seconds while open: a changed file goes into the vault at once (no PIN needed)
    $v = @($S.vaults | Where-Object { $_.id -eq $Item.vault })[0]; if (-not $v) { return }
    if (-not (Test-VaultPlainOk $Item.plain (Get-VaultUserSid $User))) { return }   # gone, a link, or not yours: never read it
    if (-not (Test-VaultSingleLink $Item.plain)) { return }
    try { $h = Get-VaultFileHash $Item.plain } catch { return }
    if ($h -eq $Item.hash) { return }
    $gv = Get-SecureGv $v (Get-SecureRel $v $Item.plain); $new = "$gv.check"
    try {
        $fk = Write-VaultFile $Item.plain $new $S.dataPub
        if ((Read-VaultFile $new $null $null -FileKey $fk) -ne $h) { throw 'check' }
        Move-Item -LiteralPath $new -Destination $gv -Force; try { Set-VaultOwner $gv $S.ownerSid } catch { }
        $Item.hash = $h; $Item | Add-Member -NotePropertyName synced -NotePropertyValue (Get-Date).ToString('o') -Force
    } catch { Remove-Item -LiteralPath $new -Force -EA SilentlyContinue }   # being saved right now: next time
}
function Close-SecureItem($S, $Item, [string]$User) {
    # lock again: last changes in, real file out, placeholder back. 'locked', 'busy' or 'kept'
    $v = @($S.vaults | Where-Object { $_.id -eq $Item.vault })[0]; if (-not $v) { return 'kept' }
    $sid = Get-VaultUserSid $User
    if (-not (Test-Path -LiteralPath $Item.plain)) {
        # deleted or renamed while open: the sealed copy stays, the placeholder comes back
        $gv = Get-SecureGv $v (Get-SecureRel $v $Item.plain)
        try { Set-SecurePlaceholder $Item.plain (Get-Item -LiteralPath $gv).LastWriteTime $User } catch { }
        return 'kept'
    }
    if (-not (Test-VaultPlainOk $Item.plain $sid)) { return 'kept' }   # swapped for a link / someone else's file: never read back
    $r = Protect-SecureFile $S $v $Item.plain $User
    if ($r -eq 'sealed') { return 'locked' }
    if ($r -eq 'gone') { return 'kept' }
    return 'busy'
}
function Invoke-SecureSweep($S, $Cfg, [string]$User, [string[]]$Paths = $null) {
    # every protected folder is sealed; any real file found in one (new, copied in, saved by a
    # program) is sealed too. $Paths: only these (new files the watcher saw); $null: everything.
    # Returns how many files it sealed.
    $n = 0
    foreach ($f in @($Cfg.folders)) {
        if (-not $f.path -or -not (Test-Path -LiteralPath $f.path)) { continue }
        $v = Get-SecureVault $S $f.path
        if (-not $v) { $v = New-SecureVaultEntry $S $f.path; try { Set-VaultOwner (Get-VaultDir $v) $S.ownerSid } catch { } }
        $skip = @(); if ($f.skip) { $skip = @($f.skip) }
        $todo = @()
        if ($null -eq $Paths) { $todo = @(Get-ChildItem -LiteralPath $f.path -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }
        else {
            foreach ($p in $Paths) {
                if (-not $p.StartsWith($v.path + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
                if (Test-Path -LiteralPath $p -PathType Container) { $todo += @(Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }
                else { $todo += $p }
            }
        }
        foreach ($p in $todo) {
            $name = Split-Path $p -Leaf
            if ($name -eq '_guard.json' -or (Test-GuardSkip -Name $name -Extra $skip) -or $name -like '*.guard-*') { continue }
            if (Get-SecureOpen $S $p) { continue }               # unlocked right now
            if (Test-SecurePlaceholder $v $p) { continue }      # already sealed
            try { if (((Get-Date) - (Get-Item -LiteralPath $p -Force).LastWriteTime).TotalSeconds -lt 2) { $script:SecureLater += $p; continue } } catch { continue }
            $r = Protect-SecureFile $S $v $p $User
            if ($r -eq 'sealed') { $n++ } elseif ($r -eq 'busy') { $script:SecureLater += $p }
        }
    }
    return $n
}
function Invoke-SecureTick([string]$User, $Cfg, [datetime]$Since = [datetime]::MinValue, [string[]]$NewPaths = @(), [switch]$Full) {
    # the background guard, every 5 seconds: unlocked files synced, old ones locked again, new
    # files sealed. Busy (guard's window is working): does nothing this time.
    $s = Read-VaultState
    if (-not $s -or -not $s.on) { return $false }
    $script:SecureLater = @()
    $min = $script:SecureLockMin; if ($s.lockAfterMin) { $min = [int]$s.lockAfterMin }
    $cut = (Get-Date).AddMinutes(-$min)
    $done = Update-VaultState -VaultTry {
        param($st)
        $keep = @()
        foreach ($it in @($st.open)) {
            $t = [datetime]$it.at
            if ((($t -lt $cut) -or ($t -lt $Since)) -and -not (Test-GuardBusy $it.plain)) {
                if ((Close-SecureItem $st $it $User) -ne 'busy') { continue }
            } else { Sync-SecureItem $st $it $User }
            $keep += $it
        }
        $st.open = $keep
        $p = $null; if (-not $Full) { $p = @($NewPaths) }
        if ($Full -or $p.Count) { [void](Invoke-SecureSweep $st $Cfg $User $p) }
    }
    return [bool]$done
}

# =========================== the commands (guard's window) =================================
function Read-VaultSecret([string]$Prompt) { return (Read-CheckSecret $Prompt) }
function Read-VaultUnlock($S) {
    # PIN, or the recovery code; returns the keys or $null (and says why)
    $p = Read-VaultSecret '  PIN  (forgot it, or a new PC: type  recovery)'
    try {
        if ($p.Trim() -ieq 'recovery') { $c = Read-VaultSecret '  recovery code'; return (Open-VaultKeys $S $c -Recovery) }
        return (Open-VaultKeys $S $p)
    } catch { Say ("  not opened: {0}." -f $_.Exception.Message) 'Red'; return $null } finally { $p = $null }
}
function Test-VaultAdminOk { return ((Test-GuardAdmin) -or (Test-VaultTestMode)) }

function New-VaultSetup {
    # the first vault: PIN, chip key, hidden account, recovery code. Returns the state or $null.
    Say ""
    Say "  choose the guard PIN. unlocking a file asks for it."
    Say "  at least 8 characters; longer is safer (an administrator could reset the chip's count"
    Say "  of wrong tries and guess for a long time). nobody, guard included, can show it to you again."
    $p1 = Read-VaultSecret '  new PIN'; $p2 = Read-VaultSecret '  new PIN again'
    if ($p1 -ne $p2) { Say "  the two PINs differ. nothing was changed." 'Red'; return $null }
    if ($p1.Length -lt 8) { Say "  shorter than 8 characters. nothing was changed." 'Red'; return $null }
    $keyName = Get-GuardTestEnv 'GUARD_VAULT_KEYNAME'; if (-not $keyName) { $keyName = 'guard-vault-' + [guid]::NewGuid().ToString('N').Substring(0, 8) }
    try {
        $sid = Initialize-VaultAccount
        $k = New-VaultRandom 64
        $chip = Protect-VaultChip $k $p1 $keyName
        $rsa = New-Object Security.Cryptography.RSACng 3072
        $code = New-VaultRecoveryCode; $salt = New-VaultRandom 16; $iter = 300000
        if (Test-VaultSoftChip) { $iter = 2000 }
        $s = [pscustomobject]@{
            version = 1; on = $false; lockAfterMin = $script:SecureLockMin; keyName = $keyName; chipWrap = $chip; ownerSid = $sid
            recSalt = [Convert]::ToBase64String($salt); recIter = $iter
            recWrap = [Convert]::ToBase64String((Protect-VaultBytes $k (Get-VaultStretch (Get-VaultCodeDigits $code) $salt $iter)))
            dataPub = $rsa.ToXmlString($false)
            dataPriv = [Convert]::ToBase64String((Protect-VaultBytes ([Text.Encoding]::UTF8.GetBytes($rsa.ToXmlString($true))) $k))
            closeAfterMin = $script:VaultCloseMin; vaults = @(); open = @(); saved = ''
        }
        $rsa.Dispose()
        # prove the chip opens it with this PIN before anything depends on it
        $t = Open-VaultKeys $s $p1
        if (-not (Test-VaultSame $t.Key $k)) { throw 'the chip did not give the vault key back' }
        $script:VaultSetupKeys = $t
    } catch { Say ("  FAIL  {0}" -f $_.Exception.Message) 'Red'; Remove-VaultChipKey $keyName; Say "  nothing was changed." 'Red'; return $null }
    finally { $p1 = $null; $p2 = $null }
    Say ""
    Say "  recovery code. write it on paper now and keep it away from this PC:" 'Yellow'
    Say ""; Say ("      {0}" -f $code) 'Cyan'; Say ""
    Say "  it opens everything without the PIN: on a new PC, after Windows is reinstalled, or"
    Say "  when the PIN is forgotten. without the PIN and without this code the files are gone for good."
    $back = Read-VaultSecret '  type the recovery code from your paper'
    if ((Get-VaultCodeDigits $back) -ne (Get-VaultCodeDigits $code)) {
        Remove-VaultChipKey $keyName
        Say "  that is not the code. nothing was changed: type  security vault on  again for a new PIN and code." 'Red'; return $null
    }
    return $s
}

function Cmd-Security([string]$Arg) {
    switch (("$Arg".Trim() -replace '\s+', ' ').ToLower()) {
        'vault on'  { Cmd-SecurityOn }
        'vault off' { Cmd-SecurityOff }
        'vault'     { Show-SecurityState }
        'vault pin' { Cmd-VaultPin }
        default     { Say "  security vault on   or   security vault off" 'Red' }
    }
}
function Show-SecurityState {
    $s = Read-VaultState
    if ($s -and $s.on) {
        Say "  Security Vault is On." 'Green'
        $n = @($s.open).Count
        if ($n) { Say ("  {0} file(s) unlocked right now: they lock again by themselves." -f $n) 'Yellow' }
    } else { Say "  Security Vault is Off.  type  security vault on  to turn it on." }
}
function Get-SecureFolderFiles($F) {
    $skip = @(); if ($F.skip) { $skip = @($F.skip) }
    return @(Get-ChildItem -LiteralPath $F.path -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '_guard.json' -and -not (Test-GuardSkip -Name $_.Name -Extra $skip) })
}

function Cmd-SecurityOn {
    if (-not (Test-VaultAdminOk)) { Say "  needs administrator" 'Red'; return }
    $s = Read-VaultState
    if ($s -and $s.on) { Say "  Security Vault is already On." 'Green'; return }
    $folders = @($script:Cfg.folders | Where-Object { $_.path -and (Test-Path -LiteralPath $_.path) })
    if (-not $folders.Count) { Say "  no protected folder yet. type  init  in a folder first, then  security vault on" 'Red'; return }
    if (@($folders | Where-Object { $_.editing }).Count) { Say "  a folder is unlocked for editing. type  resume all  first, then  security vault on" 'Red'; return }
    $all = @()
    foreach ($f in $folders) {
        if (-not (Test-VaultLinkFree $f.path)) { Say ("  FAIL  {0}: a folder on its path is a link to somewhere else. nothing was changed." -f $f.name) 'Red'; return }
        if (@(Get-ChildItem -LiteralPath $f.path -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
            Say ("  FAIL  {0} holds a link to somewhere else: guard won't follow it. nothing was changed." -f $f.name) 'Red'; return
        }
        $all += @(Get-SecureFolderFiles $f | ForEach-Object { $_.FullName })
    }
    $bytes = [long]((@($all | ForEach-Object { (Get-Item -LiteralPath $_ -Force).Length }) | Measure-Object -Sum).Sum)
    try { $free = (New-Object IO.DriveInfo((Split-Path (Get-VaultRootFor) -Qualifier))).AvailableFreeSpace; if ($free -lt ($bytes * 1.1 + 50MB)) { Say "  not enough free disk space. nothing was changed." 'Red'; return } } catch { }
    Say ""
    Say "  Security Vault: every file in your protected folders gets sealed. only your PIN opens one."
    $new = $false
    if (-not $s) { $s = New-VaultSetup; if (-not $s) { return }; $new = $true; $keys = $script:VaultSetupKeys; $script:VaultSetupKeys = $null }
    else { $keys = Read-VaultUnlock $s; if (-not $keys) { Say "  nothing was changed." 'Red'; return } }
    try {
        Initialize-VaultRoot (Get-VaultRootFor) $s.ownerSid
        if ($new) { Save-VaultState $s }   # the keys are kept before anything depends on them
    } catch { Say ("  FAIL  {0}. nothing was changed." -f $_.Exception.Message) 'Red'; if ($new) { Remove-VaultChipKey $s.keyName }; return }

    # 1: a sealed, checked copy of every file. The folders don't change yet.
    $res = Invoke-WithDots '  sealing' {
        $plan = @(); $made = @()
        try {
            foreach ($f in $folders) { if (-not (Get-SecureVault $s $f.path)) { $made += (New-SecureVaultEntry $s $f.path) } }
            foreach ($full in $all) {
                if (-not (Test-VaultSingleLink $full)) { throw ("{0} is a hard link to another file: guard won't touch it. move it out first" -f (Split-Path $full -Leaf)) }
                $v = Get-SecureVault $s $full
                $h1 = Get-VaultFileHash $full
                $gv = Get-SecureGv $v (Get-SecureRel $v $full); $nw = "$gv.check"
                [void](Write-VaultFile $full $nw $s.dataPub)
                $plan += [pscustomobject]@{ V = $v; Full = $full; New = $nw; Gv = $gv; Hash = $h1; When = (Get-Item -LiteralPath $full -Force).LastWriteTime }
                if ((Read-VaultFile $nw $null $keys.Priv) -ne $h1) { throw ("{0} did not check out" -f (Split-Path $full -Leaf)) }
            }
            return @{ Plan = $plan; Made = $made; Err = $null }
        } catch { return @{ Plan = $plan; Made = $made; Err = $_.Exception.Message } }
    }
    if ($res.Err) {
        foreach ($p in $res.Plan) { Remove-Item -LiteralPath $p.New -Force -EA SilentlyContinue }
        foreach ($m in $res.Made) { Remove-Item -LiteralPath (Get-VaultDir $m) -Recurse -Force -EA SilentlyContinue }
        $ids = @($res.Made | ForEach-Object { $_.id }); $s.vaults = @($s.vaults | Where-Object { $ids -notcontains $_.id })
        Say ("  FAIL  {0}" -f $res.Err) 'Red'; Say "  nothing was changed: every file is where it was." 'Red'
        $keys.Priv.Dispose(); return
    }
    # 2: every copy in place, then every file becomes a placeholder. The background guard waits.
    $script:SecureLeft = 0
    [void](Update-VaultState {
        param($st)
        $st.vaults = @($s.vaults); $st.on = $true
        foreach ($p in $res.Plan) {
            Move-Item -LiteralPath $p.New -Destination $p.Gv -Force
            try { Set-VaultOwner $p.Gv $s.ownerSid } catch { }
            $ok = $false
            try {
                if (-not (Test-GuardBusy $p.Full) -and (Get-VaultFileHash $p.Full) -eq $p.Hash) {
                    if (-not (Test-VaultNoAcl)) { Unlock-GuardFile -Path $p.Full -User $script:User | Out-Null }
                    Remove-VaultPlain $p.Full
                    Set-SecurePlaceholder $p.Full $p.When $script:User
                    $ok = $true
                }
            } catch { }
            if (-not $ok) { $script:SecureLeft++ }   # open or changed right now: the background guard seals it later
        }
    })
    $keys.Priv.Dispose(); $keys = $null
    Set-SecureMenu
    Write-GuardBadges -Config $script:Cfg
    Say ""
    if ($script:SecureLeft) {
        Say ("  {0} file(s) are open in a program right now: they are sealed by themselves as soon as it lets go." -f $script:SecureLeft) 'Yellow'
        Say "  NOT everything is sealed yet." 'Red'
    } else { Say "  Security Vault is On." 'Green' }
    Say "  to use a file: right-click it, then  Unlock with guard." 'DarkGray'
}

function Cmd-SecurityOff {
    if (-not (Test-VaultAdminOk)) { Say "  needs administrator" 'Red'; return }
    $s = Read-VaultState
    if (-not $s -or -not $s.on) { Say "  Security Vault is already Off."; return }
    Say ""; Say "  Security Vault off: every file comes back as a normal file, still protected from deleting."
    $keys = Read-VaultUnlock $s
    if (-not $keys) { Say "  nothing was changed." 'Red'; return }
    $script:SecureBad = 0
    [void](Update-VaultState {
        param($st)
        $st.on = $false   # first: the background guard stops sealing
        $keepV = @()
        foreach ($v in @($st.vaults)) {
            $bad = 0
            foreach ($e in Get-VaultEntries $v) {
                $full = Join-Path $v.path $e.Rel; $tmp = "$full.guard-" + [guid]::NewGuid().ToString('N').Substring(0, 8)
                try {
                    if ((Test-Path -LiteralPath $full) -and -not (Test-SecurePlaceholder $v $full)) {
                        # unlocked right now: the real file is already here and newest
                    } else {
                        if (-not (Test-VaultLinkFree (Split-Path $full -Parent))) { throw 'a folder on the way is a link' }
                        $when = $null; try { $when = (Get-Item -LiteralPath $full -Force -EA Stop).LastWriteTime } catch { }
                        [void](Read-VaultFile $e.Gv $tmp $keys.Priv)
                        if (Test-Path -LiteralPath $full) {
                            if (-not (Test-VaultNoAcl)) { Unlock-GuardFile -Path $full -User $script:User | Out-Null }
                            Remove-Item -LiteralPath $full -Force -ErrorAction Stop
                        }
                        Move-Item -LiteralPath $tmp -Destination $full
                        if ($when) { try { (Get-Item -LiteralPath $full -Force).LastWriteTime = $when } catch { } }
                        Set-VaultPlainOwner $full $script:User
                    }
                    if (-not (Test-VaultNoAcl)) { Lock-GuardFile -Path $full -User $script:User -Force | Out-Null }   # normal protection again
                } catch { $bad++; Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue }
            }
            if ($bad) { $script:SecureBad += $bad; $keepV += $v } else { Remove-Item -LiteralPath (Get-VaultDir $v) -Recurse -Force -EA SilentlyContinue }
        }
        $st.vaults = @($keepV); $st.open = @()
        if ($keepV.Count) { $st.on = $true }   # what could not come back stays sealed
    })
    $keys.Priv.Dispose()
    if (-not (Test-SecurityOn)) { Set-SecureMenu -Off }
    Write-GuardBadges -Config $script:Cfg
    Say ""
    if ($script:SecureBad) { Say ("  {0} file(s) could not come back: they stay sealed. type  security vault off  again." -f $script:SecureBad) 'Red' }
    else { Say "  Security Vault is Off." 'Green' }
}

function Invoke-SecurityUnlock([string]$Path) {
    # right-click -> Unlock with guard (guard's own admin window). Returns 0 when unlocked.
    Say ""
    $s = Read-VaultState
    if (-not $s -or -not $s.on) { Say "  Security Vault is off: nothing to unlock."; return 1 }
    $full = "$Path".Trim().Trim('"')
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\', '.') }
    try { $full = (Resolve-Path -LiteralPath $full -ErrorAction Stop).ProviderPath.TrimEnd('\') } catch { Say "  not found." 'Red'; return 1 }
    $v = Get-SecureVault $s $full
    if (-not $v) { Say "  this is not in the Security Vault." 'Red'; return 1 }
    $targets = @()
    if (Test-Path -LiteralPath $full -PathType Container) { $targets = @(Get-ChildItem -LiteralPath $full -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { Test-SecurePlaceholder $v $_.FullName } | ForEach-Object { $_.FullName }) }
    elseif (Test-SecurePlaceholder $v $full) { $targets = @($full) }
    if (-not $targets.Count) {
        if (Get-SecureOpen $s $full) { Say "  already unlocked." 'Green'; Open-SecureShown $full; return 0 }
        Say "  nothing locked here."; return 1
    }
    Say ("  unlock  {0}" -f (Split-Path $full -Leaf))
    $keys = Read-VaultUnlock $s
    if (-not $keys) { return 1 }
    $script:SecureOpened = 0; $script:SecureFailed = 0
    [void](Update-VaultState {
        param($st)
        foreach ($t in $targets) {
            try {
                $h = Open-SecureFile $st $v $t $script:User $keys.Priv
                $st.open = @($st.open) + @([pscustomobject]@{ vault = $v.id; plain = $t; at = (Get-Date).ToString('o'); hash = $h })
                $script:SecureOpened++
            } catch { $script:SecureFailed++; Say ("  FAIL  {0}  {1}" -f (Split-Path $t -Leaf), $_.Exception.Message) 'Red' }
        }
    })
    $keys.Priv.Dispose(); $keys = $null
    Write-GuardBadges -Config $script:Cfg
    if ($script:SecureOpened) { Open-SecureShown $full }
    if ($script:SecureFailed) { Say "  NOT everything was unlocked (see above)." 'Red'; return 1 }
    Say ("  Unlocked. it locks again by itself {0} minutes after you opened it, once no program uses it." -f [int]$s.lockAfterMin) 'Green'
    return 0
}
function Open-SecureShown([string]$Full) {
    # the file opens in its normal program (Explorer starts it in your normal session)
    if (Get-GuardTestEnv 'GUARD_NOBROWSER') { return }
    try { Start-Process (Join-Path (Get-GuardWindowsDir) 'explorer.exe') -ArgumentList "`"$Full`"" } catch { }
}
function Set-SecureMenu([switch]$Off) {
    # Explorer: right-click -> "Unlock with guard" on files and folders (only while it is on)
    if (Test-VaultNoAcl) { return }
    $keys = @('SOFTWARE\Classes\*\shell\guard-unlock', 'SOFTWARE\Classes\Directory\shell\guard-unlock')
    foreach ($k in $keys) { try { [Microsoft.Win32.Registry]::LocalMachine.DeleteSubKeyTree($k, $false) } catch { } }
    if ($Off) { return }
    $g = Join-Path $script:InstallDir 'guard.ps1'
    $cmd = '"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -Unlock "%1"' -f (Get-GuardPowerShellExe), $g
    foreach ($k in $keys) {
        try {
            $r = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($k)
            $r.SetValue('MUIVerb', 'Unlock with guard'); $r.SetValue('HasLUAShield', '')
            $c = $r.CreateSubKey('command'); $c.SetValue('', $cmd); $c.Close(); $r.Close()
        } catch { }
    }
}



function Cmd-VaultPin {
    if (-not (Test-VaultAdminOk)) { Say "  needs administrator" 'Red'; return }
    $s = Read-VaultState
    if (-not $s) { Say "  no vault yet."; return }
    Say ""; Say "  change the guard PIN. first the current one:"
    $keys = Read-VaultUnlock $s
    if (-not $keys) { return }
    $p1 = Read-VaultSecret '  new PIN'; $p2 = Read-VaultSecret '  new PIN again'
    if ($p1 -ne $p2) { Say "  the two PINs differ. the PIN is unchanged." 'Red'; return }
    if ($p1.Length -lt 8) { Say "  shorter than 8 characters. the PIN is unchanged." 'Red'; return }
    $old = $s.keyName
    $nk = Get-GuardTestEnv 'GUARD_VAULT_KEYNAME'; if ($nk) { $nk = "$nk-2" } else { $nk = 'guard-vault-' + [guid]::NewGuid().ToString('N').Substring(0, 8) }
    try {
        $w = Protect-VaultChip $keys.Key $p1 $nk
        $tmp = $s.PSObject.Copy(); $tmp.chipWrap = $w; $tmp.keyName = $nk
        if (-not (Test-VaultSame (Open-VaultKeys $tmp $p1).Key $keys.Key)) { throw 'the new PIN did not open the vault key' }
        Update-VaultState { param($st) $st.chipWrap = $w; $st.keyName = $nk }
    } catch { Remove-VaultChipKey $nk; Say ("  FAIL  {0}. the PIN is unchanged." -f $_.Exception.Message) 'Red'; return }
    finally { $p1 = $null; $p2 = $null }
    if ($old -ne $nk) { Remove-VaultChipKey $old }
    Say ""; Say "  PIN is Changed Successfully." 'Green'
}

function Show-VaultLine {
    # under the status block, only while the Security Vault is on
    try {
        $s = Read-VaultState
        if (-not $s -or -not $s.on) { return }
        $n = @($s.open).Count
        if ($n) { Say ("vault     Security Vault on  -  {0} file(s) unlocked, they lock again by themselves" -f $n) 'Yellow' }
        else { Say "vault     Security Vault on" 'Green' }
    } catch { }
}
function Test-GuardVaultInUse { $s = Read-VaultState; return [bool]($s -and @($s.vaults).Count) }
function Remove-GuardVaultSystem {
    # uninstall, only when nothing is sealed: the chip key, the account, the hidden folder, the menu
    $s = Read-VaultState
    if ($s -and @($s.vaults).Count) { return $false }
    if ($s) { Remove-VaultChipKey $s.keyName }
    Remove-Item -LiteralPath (Get-VaultStatePath) -Force -EA SilentlyContinue
    if (-not (Get-GuardTestEnv 'GUARD_VAULT_NOACCOUNT')) { try { Remove-LocalUser -Name (Get-VaultAccount) -ErrorAction Stop } catch { } }
    $r = Get-VaultRootFor
    if (Test-Path -LiteralPath $r) {
        Remove-Item -LiteralPath (Join-Path $r 'vault-keys.json') -Force -EA SilentlyContinue
        if (-not (Get-ChildItem -LiteralPath $r -Recurse -File -Force -EA SilentlyContinue)) { Remove-Item -LiteralPath $r -Recurse -Force -EA SilentlyContinue }
    }
    Set-SecureMenu -Off
    return $true
}
