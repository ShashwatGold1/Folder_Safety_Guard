# guard-vault.ps1 - the vault: folders nobody can read without the guard PIN.
#   vault <path>   moves a folder into the vault (PIN; the first time you choose the PIN)
#   vault          lists the vault folders and what is open
#   vault pin      changes the PIN
#   open <name>    PIN, then only that file or folder comes back as a normal one
#   close [name]   saves changes back into the vault and takes the open copies away again
#   unvault <name> PIN, then the whole folder becomes a normal folder again
#
# How it holds:
#  - every file is encrypted (AES-256 + HMAC-SHA256) with a key of its own. That key is locked
#    with the vault's data key; the data key's private half is locked with a 64-byte vault key,
#    and the vault key is locked by a key in this PC's TPM chip that only works with the PIN.
#    The chip counts wrong PINs and slows guessing down. A second copy of the vault key is
#    locked with the recovery code (paper only), for a new PC, a cleared chip or a lost PIN.
#  - putting a file IN needs only the public half: guard can save changes back (close, and
#    the background guard's auto-close) without the PIN. Getting one OUT always needs the PIN.
#  - the encrypted files sit in <drive>:\guard-vault, owned by a hidden, switched-off account
#    (guard-vault) that nobody signs in with. Only that account, SYSTEM and administrators may
#    touch the folder; you, Explorer and every program running as you get "access denied".
#    An administrator who takes the files anyway gets only scrambled bytes.
# Works in guard's own window (admin) and in the background guard (SYSTEM, auto-close only).

$script:VaultTrusted = @('S-1-5-18', 'S-1-5-32-544')
$script:VaultMagic = [Text.Encoding]::ASCII.GetBytes('GVF1')
$script:VaultCloseMin = 30

# ---- settings (test overrides only in test mode: see Get-GuardTestEnv) ------------------
function Test-VaultTestMode { return [bool](Get-GuardTestEnv 'GUARD_VAULT_ROOT') }
function Get-VaultStatePath { return (Join-Path (Split-Path $script:GuardConfigPath -Parent) 'vault.json') }
function Get-VaultAccount { $a = Get-GuardTestEnv 'GUARD_VAULT_ACCOUNT'; if ($a) { return $a }; return 'guard-vault' }
function Test-VaultSoftChip { return [bool](Get-GuardTestEnv 'GUARD_VAULT_SOFTCHIP') }
# tests without admin rights can't set owners: those steps are skipped there (and only there)
function Test-VaultNoAcl { return ((Test-VaultTestMode) -and -not (Test-GuardAdmin)) }
function Get-VaultRootFor([string]$Path) {
    $r = Get-GuardTestEnv 'GUARD_VAULT_ROOT'; if ($r) { return $r.TrimEnd('\') }
    return ((Split-Path $Path -Qualifier) + '\guard-vault')
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
    $cands = @($p)
    if (-not (Test-VaultTestMode)) { foreach ($d in [IO.DriveInfo]::GetDrives()) { if ($d.DriveType -eq 'Fixed') { $cands += (Join-Path $d.RootDirectory.FullName 'guard-vault\vault-keys.json') } } }
    else { $cands += (Join-Path (Get-VaultRootFor '') 'vault-keys.json') }
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
    $targets = @(Get-VaultStatePath) + @($S.vaults | ForEach-Object { Join-Path $_.root 'vault-keys.json' } | Select-Object -Unique)
    foreach ($t in $targets) {
        $d = Split-Path $t -Parent; if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        $tmp = "$t.tmp"
        [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $t -Force
    }
}
function Update-VaultState([scriptblock]$Change) {
    # guard's window and the background guard both change the open list: one at a time
    $m = $null; $got = $false
    try { $m = New-Object Threading.Mutex($false, 'Global\guard-vault-state'); try { $got = $m.WaitOne(10000) } catch [Threading.AbandonedMutexException] { $got = $true } } catch { }
    try {
        $s = Read-VaultState; if (-not $s) { throw 'no vault' }
        & $Change $s
        Save-VaultState $s
    } finally { if ($got) { try { $m.ReleaseMutex() } catch { } }; if ($m) { $m.Dispose() } }
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
}
function Read-VaultFile([string]$Gv, [string]$Out, $Priv) {
    # checks the file, then writes the plain bytes to $Out (or nowhere); returns their SHA-256
    $fs = [IO.File]::Open($Gv, 'Open', 'Read', 'Read')
    try {
        $br = New-Object IO.BinaryReader($fs)
        if (-not (Test-VaultSame $br.ReadBytes(4) $script:VaultMagic)) { throw 'not a vault file' }
        $mac = $br.ReadBytes(32); $wl = [int]$br.ReadUInt16(); $wrap = $br.ReadBytes($wl)
        try { $fk = $Priv.Decrypt($wrap, [Security.Cryptography.RSAEncryptionPadding]::OaepSHA256) } catch { throw 'damaged or changed (its key does not open)' }
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

# ---- close: save back, take the open copies away (no PIN: only the public half is needed) --
function Close-VaultItem($S, $Item, [string]$User) {
    # returns @{ Done; Saved; Added; Same; Kept; Busy; Why }
    $res = @{ Done = $false; Saved = 0; Added = 0; Same = 0; Kept = 0; Busy = 0; Why = '' }
    $v = @($S.vaults | Where-Object { $_.id -eq $Item.vault })[0]
    if (-not $v) { $res.Done = $true; return $res }
    $sid = Get-VaultUserSid $User
    $known = @{}; foreach ($p in $Item.files.PSObject.Properties) { $known[$p.Name] = [string]$p.Value }
    $vdir = Get-VaultDir $v
    $plainFiles = @()
    if (Test-Path -LiteralPath $Item.plain) {
        if (Test-Path -LiteralPath $Item.plain -PathType Leaf) { $plainFiles = @([pscustomobject]@{ Rel = $Item.rel; Full = $Item.plain }) }
        else {
            $base = $Item.plain.TrimEnd('\')
            $plainFiles = @(Get-ChildItem -LiteralPath $base -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
                $r = $_.FullName.Substring($base.Length + 1); if ($Item.rel) { $r = Join-Path $Item.rel $r }
                [pscustomobject]@{ Rel = $r; Full = $_.FullName } })
        }
    }
    $seen = @{}
    foreach ($f in $plainFiles) {
        $seen[$f.Rel] = $true
        if (-not (Test-VaultPlainOk $f.Full $sid)) { $res.Kept++; continue }   # a link or not yours: never read it back
        try { $h = Get-VaultFileHash $f.Full } catch { $res.Busy++; continue }
        if ($known.ContainsKey($f.Rel) -and $known[$f.Rel] -eq $h) { $res.Same++ }
        else {
            try { Write-VaultFile $f.Full (Join-Path $vdir ($f.Rel + '.gv')) $S.dataPub } catch { $res.Busy++; continue }
            if ($known.ContainsKey($f.Rel)) { $res.Saved++ } else { $res.Added++ }
        }
        try { Remove-VaultPlain $f.Full } catch { $res.Busy++ }
    }
    foreach ($k in $known.Keys) { if (-not $seen[$k]) { $res.Kept++ } }   # deleted while open: the vault copy stays
    if ($res.Saved -or $res.Added) { try { Set-VaultOwner $vdir $S.ownerSid } catch { } }
    # take away the folders open made, from the deepest up to the folder's own path
    if (Test-Path -LiteralPath $Item.plain -PathType Container) {
        Get-ChildItem -LiteralPath $Item.plain -Recurse -Directory -Force -EA SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending |
            ForEach-Object { if (-not (Get-ChildItem -LiteralPath $_.FullName -Force -EA SilentlyContinue)) { Remove-Item -LiteralPath $_.FullName -Force -EA SilentlyContinue } }
    }
    $p = $Item.plain; if (Test-Path -LiteralPath $p -PathType Leaf) { $p = Split-Path $p -Parent } elseif (-not (Test-Path -LiteralPath $p)) { $p = Split-Path $p -Parent }
    $stop = Split-Path $v.path -Parent
    while ($p -and $p.Length -gt $stop.Length -and $p.StartsWith($v.path, [StringComparison]::OrdinalIgnoreCase)) {
        if ((Test-Path -LiteralPath $p -PathType Container) -and -not (Get-ChildItem -LiteralPath $p -Force -EA SilentlyContinue)) { Remove-Item -LiteralPath $p -Force -EA SilentlyContinue } else { break }
        $p = Split-Path $p -Parent
    }
    $res.Done = ($res.Busy -eq 0)
    return $res
}
function Close-VaultItems([scriptblock]$Which, [string]$User) {
    # closes the open items $Which picks; returns one result per item (with .Item)
    $script:VaultLastClose = @()
    Update-VaultState {
        param($s)
        $keep = @()
        foreach ($it in @($s.open)) {
            if (-not (& $Which $it)) { $keep += $it; continue }
            $r = Close-VaultItem $s $it $User; $r.Item = $it; $script:VaultLastClose += , $r
            if (-not $r.Done) { $keep += $it }
        }
        $s.open = $keep
    }
    return @($script:VaultLastClose)
}
function Invoke-GuardVaultAutoClose([string]$User, [datetime]$Since = [datetime]::MinValue) {
    # the background guard: closes what was opened more than 30 minutes ago, or before the last
    # sign-in (a restart). Returns how many it closed.
    $s = Read-VaultState
    if (-not $s -or -not @($s.open).Count) { return 0 }
    $min = $script:VaultCloseMin; if ($s.closeAfterMin) { $min = [int]$s.closeAfterMin }
    $cut = (Get-Date).AddMinutes(-$min)
    $script:VaultLastClose = @()
    $r = Close-VaultItems { param($i) $t = [datetime]$i.at; ($t -lt $cut) -or ($t -lt $Since) } $User
    return @($r | Where-Object { $_.Done }).Count
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
    Say "  first vault: choose the guard PIN. every  open  asks for it."
    Say "  at least 8 characters; longer is safer (an administrator could reset the chip's count"
    Say "  of wrong tries and guess for a long time). nobody, guard included, can show it to you again."
    $p1 = Read-VaultSecret '  new PIN'; $p2 = Read-VaultSecret '  new PIN again'
    if ($p1 -ne $p2) { Say "  the two PINs differ. nothing was changed." 'Red'; return $null }
    if ($p1.Length -lt 8) { Say "  shorter than 8 characters. nothing was changed." 'Red'; return $null }
    $keyName = Get-GuardTestEnv 'GUARD_VAULT_KEYNAME'; if (-not $keyName) { $keyName = 'guard-vault-' + [guid]::NewGuid().ToString('N').Substring(0, 8) }
    try {
        $sid = Initialize-VaultAccount
        Ok "account" ("{0}  -hidden, switched off: owns the vault, nobody signs in with it" -f (Get-VaultAccount))
        $k = New-VaultRandom 64
        $chip = Protect-VaultChip $k $p1 $keyName
        $rsa = New-Object Security.Cryptography.RSACng 3072
        $code = New-VaultRecoveryCode; $salt = New-VaultRandom 16; $iter = 300000
        if (Test-VaultSoftChip) { $iter = 2000 }
        $s = [pscustomobject]@{
            version = 1; keyName = $keyName; chipWrap = $chip; ownerSid = $sid
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
        Ok "chip" "the vault key is locked in this PC's TPM chip with your PIN"
    } catch { Say ("  FAIL  {0}" -f $_.Exception.Message) 'Red'; Remove-VaultChipKey $keyName; Say "  nothing was put in a vault." 'Red'; return $null }
    finally { $p1 = $null; $p2 = $null }
    Say ""
    Say "  recovery code. write it on paper now and keep it away from this PC:" 'Yellow'
    Say ""; Say ("      {0}" -f $code) 'Cyan'; Say ""
    Say "  it opens every vault without the PIN: on a new PC, after Windows is reinstalled, or"
    Say "  when the PIN is forgotten. without the PIN and without this code the files are gone for good."
    $back = Read-VaultSecret '  type the recovery code from your paper'
    if ((Get-VaultCodeDigits $back) -ne (Get-VaultCodeDigits $code)) {
        Remove-VaultChipKey $keyName
        Say "  that is not the code. nothing was put in a vault: type  vault <path>  again for a new PIN and code." 'Red'; return $null
    }
    Ok "recovery" "code checked"
    return $s
}

function Cmd-Vault([string]$Arg) {
    $a = "$Arg".Trim()
    if (-not $a) { Show-VaultList; return }
    if ($a -ieq 'pin') { Cmd-VaultPin; return }
    if (-not (Test-VaultAdminOk)) { Say "  needs administrator" 'Red'; return }
    $path = (Resolve-Path -LiteralPath $a.Trim('"') -ErrorAction SilentlyContinue).Path
    if (-not $path) { Say "  not found: $a" 'Red'; return }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { Say "  not a folder: $path  (a vault holds folders: put the file in one)" 'Red'; return }
    $path = $path.TrimEnd('\')
    if (-not (Split-Path $path -Parent)) { Say "  a whole drive can't be a vault. pick a folder on it" 'Red'; return }
    foreach ($sys in @((Get-GuardWindowsDir), (Get-GuardProgramFiles), (Get-GuardProgramFilesX86), (Get-GuardProgramData))) {
        if ($sys -and (($path -ieq $sys) -or $path.StartsWith($sys.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase))) { Say "  Windows and program folders can't be a vault: $sys" 'Red'; return }
    }
    $root = Get-VaultRootFor $path
    if (($path + '\').StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) -or ($root + '\').StartsWith($path + '\', [StringComparison]::OrdinalIgnoreCase)) { Say "  that is the vault's own place" 'Red'; return }
    if ($path -match '\\(OneDrive|Google Drive|Dropbox)(\\|$|[ -])') { Say "  folders inside OneDrive, Google Drive or Dropbox can't be a vault: an open file would be uploaded" 'Red'; return }
    if (-not (Test-VaultLinkFree $path)) { Say "  a folder on that path is a link to somewhere else: pick the real folder" 'Red'; return }
    $s = Read-VaultState
    foreach ($v in @($s.vaults | Where-Object { $_ })) {
        $vp = $v.path.TrimEnd('\') + '\'; $pp = $path + '\'
        if ($pp.StartsWith($vp, [StringComparison]::OrdinalIgnoreCase) -or $vp.StartsWith($pp, [StringComparison]::OrdinalIgnoreCase)) { Say ("  already in the vault: {0}" -f $v.name) 'Red'; return }
    }
    # a folder protected by  init : stop that protection first (the vault replaces it)
    $prot = @($script:Cfg.folders | Where-Object { $_.path -ieq $path })
    foreach ($o in $script:Cfg.folders) {
        $op = $o.path.TrimEnd('\') + '\'
        if ($o.path -ine $path -and ((($path + '\').StartsWith($op, [StringComparison]::OrdinalIgnoreCase)) -or $op.StartsWith($path + '\', [StringComparison]::OrdinalIgnoreCase))) { Say ("  part of the protected folder {0}: put that whole folder in the vault, or  remove  it first" -f $o.path) 'Red'; return }
    }
    $files = @(Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '_guard.json' })
    $links = @(Get-ChildItem -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    if ($links.Count) { Say ("  the folder holds a link ({0}): guard won't follow it. move it out first" -f $links[0].FullName) 'Red'; return }
    $bytes = [long](($files | Measure-Object Length -Sum).Sum)
    try { $free = (New-Object IO.DriveInfo((Split-Path $root -Qualifier))).AvailableFreeSpace; if (-not (Test-VaultTestMode) -and $free -lt ($bytes * 1.1 + 50MB)) { Say ("  not enough free space on {0} for the locked copy" -f (Split-Path $root -Qualifier)) 'Red'; return } } catch { }
    $name = Split-Path $path -Leaf
    Say ""; Say ("  {0}  -{1}  -{2} files  -{3:N1} MB" -f $name, $path, $files.Count, ($bytes / 1MB))
    Say "  after this only guard, with your PIN, can open it. the normal folder goes away."

    $new = $false
    if (-not $s) { $s = New-VaultSetup; if (-not $s) { return }; $new = $true; $keys = $script:VaultSetupKeys; $script:VaultSetupKeys = $null }
    else { $keys = Read-VaultUnlock $s; if (-not $keys) { Say "  nothing was put in the vault." 'Red'; return } }

    $id = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $v = [pscustomobject]@{ id = $id; name = $name; path = $path; root = $root; added = (Get-Date).ToString('o'); files = $files.Count }
    $dir = Join-Path $root $id; $stage = "$dir.new"
    try {
        Initialize-VaultRoot $root $s.ownerSid
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        $err = Invoke-WithDots '  locking every file' {
            try {
                foreach ($f in $files) {
                    $rel = $f.FullName.Substring($path.Length + 1)
                    Write-VaultFile $f.FullName (Join-Path $stage ($rel + '.gv')) $s.dataPub
                }
                $null
            } catch { $_.Exception.Message }
        }
        if ($err) { throw $err }
        # check: every locked file opens with the key and gives back exactly the original bytes
        $bad = Invoke-WithDots '  checking every file' {
            $n = 0
            foreach ($f in $files) {
                $rel = $f.FullName.Substring($path.Length + 1)
                try { if ((Read-VaultFile (Join-Path $stage ($rel + '.gv')) $null $keys.Priv) -ne (Get-VaultFileHash $f.FullName)) { $n++ } } catch { $n++ }
            }
            $n
        }
        if ($bad) { throw "$bad file(s) did not check out" }
        Move-Item -LiteralPath $stage -Destination $dir
        Set-VaultOwner $dir $s.ownerSid
    } catch {
        Remove-Item -LiteralPath $stage -Recurse -Force -EA SilentlyContinue
        Say ("  FAIL  {0}" -f $_.Exception.Message) 'Red'; Say "  nothing was moved: the folder is as it was." 'Red'
        if ($new) { Remove-VaultChipKey $s.keyName }
        return
    }
    Ok "locked" ("{0} files  -encrypted, checked one by one" -f $files.Count)
    $s.vaults = @($s.vaults) + @($v)
    Save-VaultState $s
    Ok "vault" ("{0}  -owned by {1}  -only administrators and SYSTEM may touch it" -f $dir, (Get-VaultAccount))
    # the vault holds it now: the normal folder goes
    if ($prot.Count) {
        $f0 = $prot[0]
        $script:Cfg.folders = @($script:Cfg.folders | Where-Object { $_.path -ine $path })
        $script:Cfg.current = 0
        Save-GuardConfig -Config $script:Cfg -User $script:User; Wait-WatchSync
        Unlock-GuardTree -Folder $path -User $script:User | Out-Null
        Unlock-GuardFile -Path (Join-Path $path '_guard.json') -User $script:User | Out-Null
        Set-GuardOwnerUser -Folder $path -User $script:User | Out-Null
        Ok "unlocked" "the old delete protection (the vault replaces it)"
    }
    $left = 0
    Invoke-WithDots '  removing the normal folder' {
        foreach ($f in $files) { try { Remove-VaultPlain $f.FullName } catch { } }
        Remove-Item -LiteralPath (Join-Path $path '_guard.json') -Force -EA SilentlyContinue
        Get-ChildItem -LiteralPath $path -Recurse -Directory -Force -EA SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -EA SilentlyContinue }
        Remove-Item -LiteralPath $path -Force -EA SilentlyContinue
    }
    if (Test-Path -LiteralPath $path) { $left = @(Get-ChildItem -LiteralPath $path -Recurse -File -Force -EA SilentlyContinue).Count }
    Say ""
    if ($left) {
        Say ("  FAIL  {0} file(s) are still in {1}: open in a program?" -f $left, $path) 'Red'
        Say "  they ARE in the vault. close the program, then delete them yourself." 'Red'
        return
    }
    Ok "removed" "the normal folder (its files are only in the vault now)"
    Say ""
    Say "  Folder is in the Vault." 'Green'
    Say ("  to use a file:  open {0}   or  open <part of a file name>" -f $name) 'DarkGray'
}

function Show-VaultList {
    $s = Read-VaultState
    if (-not $s -or -not @($s.vaults).Count) { Say "  no vault yet. type  vault <path>  to put a folder in it."; return }
    Say ""
    $i = 0
    foreach ($v in @($s.vaults)) {
        $i++; $n = @(Get-VaultEntries $v).Count
        Say ("  {0}  {1,-20} {2} files  -was {3}" -f $i, $v.name, $n, $v.path)
    }
    $o = @($s.open)
    if ($o.Count) {
        Say ""
        foreach ($it in $o) { Say ("  open   {0}  -since {1:HH:mm}  -closes by itself at {2:HH:mm}" -f $it.plain, ([datetime]$it.at), ([datetime]$it.at).AddMinutes([int]$s.closeAfterMin)) 'Yellow' }
        Say "  type  close  when you are done." 'Yellow'
    }
}

function Find-VaultMatches($S, [string]$Name) {
    # rows: whole vault folders whose name matches, then files whose path matches
    $rows = @()
    foreach ($v in @($S.vaults)) {
        if ($v.name -ieq $Name -or ($Name -and $v.name -like "*$Name*")) { $rows += [pscustomobject]@{ V = $v; Rel = ''; Label = ("{0}\  (whole folder)" -f $v.name) } }
    }
    foreach ($v in @($S.vaults)) {
        foreach ($e in Get-VaultEntries $v) {
            if ($Name -and (Split-Path $e.Rel -Leaf) -like "*$Name*") { $rows += [pscustomobject]@{ V = $v; Rel = $e.Rel; Label = ("{0}\{1}" -f $v.name, $e.Rel) } }
        }
    }
    return $rows
}

function Cmd-Open([string]$Arg) {
    if (-not (Test-VaultAdminOk)) { Say "  needs administrator" 'Red'; return }
    $s = Read-VaultState
    if (-not $s -or -not @($s.vaults).Count) { Say "  no vault yet. type  vault <path>  to put a folder in it."; return }
    $name = "$Arg".Trim().Trim('"')
    if (-not $name) { Show-VaultList; Say ""; Say "  type  open <name>: a vault folder, or part of a file name"; return }
    $rows = @(Find-VaultMatches $s $name)
    if (-not $rows.Count) { Say ("  nothing in the vault matches `"{0}`"" -f $name) 'Red'; return }
    $pick = $rows
    if ($rows.Count -gt 1) {
        Say ""; Say ("  {0} match. which ones?" -f $rows.Count)
        $nums = @(Select-Items @($rows | ForEach-Object { $_.Label }))
        if (-not $nums.Count) { Say "  cancelled"; return }
        $pick = @($nums | ForEach-Object { $rows[$_ - 1] })
    }
    foreach ($r in $pick) {
        foreach ($o in @($s.open)) {
            if ($o.vault -eq $r.V.id -and ($o.rel -eq '' -or $o.rel -eq $r.Rel)) { Say ("  already open: {0}  -type  close  first" -f $o.plain) 'Yellow'; return }
        }
    }
    Say ""; Say ("  open {0}" -f (($pick | ForEach-Object { $_.Label }) -join ', '))
    $keys = Read-VaultUnlock $s
    if (-not $keys) { return }
    $sid = Get-VaultUserSid $script:User
    $items = @(); $count = 0; $fail = 0
    foreach ($r in $pick) {
        $v = $r.V
        $targets = @(Get-VaultEntries $v | Where-Object { -not $r.Rel -or $_.Rel -eq $r.Rel })
        $plain = $v.path; if ($r.Rel) { $plain = Join-Path $v.path $r.Rel }
        $parent = $plain; if ($r.Rel) { $parent = Split-Path $plain -Parent }
        if (-not (Test-VaultLinkFree $parent)) { Say ("  FAIL  a folder on {0} is a link to somewhere else: not opened" -f $parent) 'Red'; $fail++; continue }
        $hashes = [ordered]@{}
        foreach ($e in $targets) {
            $out = Join-Path $v.path $e.Rel
            if (Test-Path -LiteralPath $out) { Say ("  FAIL  {0} is already there (a file guard didn't open): not opened" -f $out) 'Red'; $fail++; continue }
            try {
                $h = Read-VaultFile $e.Gv $out $keys.Priv
                Set-VaultPlainOwner $out $script:User
                $hashes[$e.Rel] = $h; $count++
            } catch { Say ("  FAIL  {0}  {1}" -f $e.Rel, $_.Exception.Message) 'Red'; $fail++ }
        }
        # the folders open made belong to you too
        if (-not (Test-VaultTestMode) -or (Test-GuardAdmin)) { if (Test-Path -LiteralPath $v.path) { Invoke-Icacls @($v.path, '/setowner', $script:User) | Out-Null } }
        $items += [pscustomobject]@{ vault = $v.id; rel = $r.Rel; plain = $plain; at = (Get-Date).ToString('o'); files = [pscustomobject]$hashes }
    }
    $keys.Priv.Dispose(); $keys = $null
    if ($items.Count) { Update-VaultState { param($st) $st.open = @($st.open) + $items } }
    Say ""
    if ($fail) { Say ("  {0} file(s) NOT opened (see above). {1} opened." -f $fail, $count) 'Red' }
    else {
        Ok "opened" ("{0} file(s)  -normal files again, only these" -f $count)
        foreach ($it in $items) { Say ("  here    {0}" -f $it.plain) 'Cyan' }
        Say ("  everything else stays locked. type  close  when done; closes by itself after {0} minutes or at the next restart." -f [int]$s.closeAfterMin) 'DarkGray'
    }
    if ($items.Count -and -not (Get-GuardTestEnv 'GUARD_NOBROWSER')) {
        $show = $items[0].plain; if (Test-Path -LiteralPath $show -PathType Leaf) { $show = Split-Path $show -Parent }
        try { Start-Process (Join-Path (Get-GuardWindowsDir) 'explorer.exe') -ArgumentList "`"$show`"" } catch { }
    }
}

function Cmd-Close([string]$Arg) {
    if (-not (Test-VaultAdminOk)) { Say "  needs administrator" 'Red'; return }
    $s = Read-VaultState
    if (-not $s -or -not @($s.open).Count) { Say "  nothing is open."; return }
    $name = "$Arg".Trim().Trim('"')
    $script:VaultLastClose = @()
    $res = @(Close-VaultItems { param($i) (-not $name) -or $name -ieq 'all' -or ($i.plain -like "*$name*") } $script:User)
    if (-not $res.Count) { Say ("  nothing open matches `"{0}`"" -f $name) 'Red'; return }
    Say ""
    $busy = 0
    foreach ($r in $res) {
        $bits = @()
        if ($r.Saved) { $bits += "$($r.Saved) changed saved" }
        if ($r.Added) { $bits += "$($r.Added) new added" }
        if ($r.Same) { $bits += "$($r.Same) unchanged" }
        if ($r.Kept) { $bits += "$($r.Kept) kept in the vault (deleted, or not a normal file of yours, while open)" }
        if ($r.Done) { Ok "closed" ("{0}  -{1}" -f $r.Item.plain, ($bits -join ', ')) }
        else { $busy++; Say ("  FAIL  {0}  -{1} file(s) still in use by a program: close it, then  close  again (or it closes by itself)" -f $r.Item.plain, $r.Busy) 'Red' }
    }
    Say ""
    if ($busy) { Say "  NOT everything is locked again (see above)." 'Red' } else { Say "  Vault is Locked Again." 'Green' }
}

function Cmd-Unvault([string]$Arg) {
    if (-not (Test-VaultAdminOk)) { Say "  needs administrator" 'Red'; return }
    $s = Read-VaultState
    if (-not $s -or -not @($s.vaults).Count) { Say "  no vault yet."; return }
    $name = "$Arg".Trim().Trim('"')
    $targets = @($s.vaults | Where-Object { $name -ieq 'all' -or $_.name -ieq $name })
    if (-not $targets.Count) { Say ("  no vault folder named `"{0}`". type  vault  to see them" -f $name) 'Red'; return }
    Say ""; foreach ($v in $targets) { Say ("  {0}  -back to {1}  -a normal folder again, anyone can read it" -f $v.name, $v.path) }
    $a = Read-Line "  type YES to take it out of the vault > "
    if ($a.Trim() -ne 'YES') { Say "  cancelled"; return }
    $keys = Read-VaultUnlock $s
    if (-not $keys) { return }
    # whatever is open is saved back first, so nothing is lost
    $ids = @($targets | ForEach-Object { $_.id }); $script:VaultLastClose = @()
    $cl = @(Close-VaultItems { param($i) $ids -contains $i.vault } $script:User)
    if (@($cl | Where-Object { -not $_.Done }).Count) { Say "  some open files are still in use: close the program first. nothing was taken out." 'Red'; return }
    $s = Read-VaultState
    $bad = 0
    foreach ($t in $targets) {
        $v = @($s.vaults | Where-Object { $_.id -eq $t.id })[0]
        $es = @(Get-VaultEntries $v); $n = 0; $err = 0
        if (-not (Test-VaultLinkFree $v.path)) { Say ("  FAIL  a folder on {0} is a link: not taken out" -f $v.path) 'Red'; $bad++; continue }
        New-Item -ItemType Directory -Path $v.path -Force | Out-Null
        foreach ($e in $es) {
            $out = Join-Path $v.path $e.Rel
            if (Test-Path -LiteralPath $out) { $err++; Say ("  FAIL  {0} already exists" -f $out) 'Red'; continue }
            try { [void](Read-VaultFile $e.Gv $out $keys.Priv); $n++ } catch { $err++; Say ("  FAIL  {0}  {1}" -f $e.Rel, $_.Exception.Message) 'Red' }
        }
        if (-not (Test-VaultTestMode) -or (Test-GuardAdmin)) { Invoke-Icacls @($v.path, '/setowner', $script:User, '/T', '/C') | Out-Null }
        if ($err) { $bad++; Say ("  {0}: {1} file(s) not taken out: the vault keeps all of them." -f $v.name, $err) 'Red'; continue }
        Remove-Item -LiteralPath (Get-VaultDir $v) -Recurse -Force -EA SilentlyContinue
        Update-VaultState { param($st) $st.vaults = @($st.vaults | Where-Object { $_.id -ne $v.id }) }
        Ok "taken out" ("{0}  -{1} files  -{2}" -f $v.name, $n, $v.path)
    }
    $keys.Priv.Dispose()
    Say ""
    if ($bad) { Say "  NOT everything was taken out (see above)." 'Red' } else { Say "  Folder is out of the Vault." 'Green' }
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
    # under the status block, only while something is open
    try {
        $s = Read-VaultState
        if ($s -and @($s.open).Count) { Say ("vault     {0} item(s) open, readable by any program: type  close  when done" -f @($s.open).Count) 'Yellow' }
    } catch { }
}
function Test-GuardVaultInUse { $s = Read-VaultState; return [bool]($s -and @($s.vaults).Count) }
function Remove-GuardVaultSystem {
    # uninstall, only when no vault folder is left: the chip key, the account, the empty roots
    $s = Read-VaultState
    if ($s -and @($s.vaults).Count) { return $false }
    if ($s) { Remove-VaultChipKey $s.keyName; foreach ($t in @(Get-VaultStatePath)) { Remove-Item -LiteralPath $t -Force -EA SilentlyContinue } }
    if (-not (Get-GuardTestEnv 'GUARD_VAULT_NOACCOUNT')) { try { Remove-LocalUser -Name (Get-VaultAccount) -ErrorAction Stop } catch { } }
    if (-not (Test-VaultTestMode)) {
        foreach ($d in [IO.DriveInfo]::GetDrives()) {
            if ($d.DriveType -ne 'Fixed') { continue }
            $r = Join-Path $d.RootDirectory.FullName 'guard-vault'
            $there = $false; try { $there = Test-Path -LiteralPath $r -ErrorAction Stop } catch { }
            if ($there) { Remove-Item -LiteralPath (Join-Path $r 'vault-keys.json') -Force -EA SilentlyContinue; if (-not (Get-ChildItem -LiteralPath $r -Force -EA SilentlyContinue)) { Remove-Item -LiteralPath $r -Force -EA SilentlyContinue } }
        }
    }
    return $true
}
