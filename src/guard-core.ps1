# guard-core.ps1 — locking engine, no UI. Dot-sourced by guard.ps1, the watcher, and tests.
# All functions return a result object; they never write to the host.

$ErrorActionPreference = 'Stop'

$script:GuardVersion = '1.0'
$script:GuardRuntime = @('guard.ps1','guard-shell.ps1','guard-core.ps1','guard-config.ps1','guard-watch.ps1','guard-badges.ps1','guard-sign.ps1')
$script:EnvKey       = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'

# ---- paths a program without admin rights can't redirect --------------------------------
# guard never takes a folder path from an environment variable: in an administrator account's
# normal session any program can set them (setx, HKCU\Environment), and the elevated guard
# would inherit the fake values (fake config folder, fake Windows folder for icacls...). These
# come from the kernel (GetSystemDirectory) and from HKLM, which only administrators can change.
function Get-GuardSystemDir { return [Environment]::SystemDirectory }                        # C:\Windows\System32
function Get-GuardWindowsDir { return (Split-Path ([Environment]::SystemDirectory) -Parent) } # C:\Windows
function Get-GuardMachineValue([string]$Key, [string]$Name) {
    # raw HKLM value from the 64-bit view, %SystemDrive% / %SystemRoot% filled in by hand
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $k = $base.OpenSubKey($Key)
        if (-not $k) { return $null }
        try { $v = [string]$k.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } finally { $k.Close() }
    } finally { $base.Close() }
    if (-not $v) { return $null }
    $v = $v -ireplace '%SystemDrive%', (Get-GuardWindowsDir).Substring(0, 2)
    return ($v -ireplace '%SystemRoot%', (Get-GuardWindowsDir))
}
function Get-GuardProgramFiles { return (Get-GuardMachineValue 'SOFTWARE\Microsoft\Windows\CurrentVersion' 'ProgramFilesDir') }
function Get-GuardProgramFilesX86 { return (Get-GuardMachineValue 'SOFTWARE\Microsoft\Windows\CurrentVersion' 'ProgramFilesDir (x86)') }
function Get-GuardProgramData { return (Get-GuardMachineValue 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' 'ProgramData') }
function Get-GuardPowerShellExe { return (Join-Path (Get-GuardSystemDir) 'WindowsPowerShell\v1.0\powershell.exe') }
function Get-GuardTool([string]$Exe) { return (Join-Path (Get-GuardSystemDir) $Exe) }        # icacls.exe, cmd.exe ...
function Set-GuardSafeModulePath {
    # load PowerShell modules only from folders only administrators can change: otherwise a
    # module planted in Documents\WindowsPowerShell\Modules (ScheduledTasks, Storage, ...)
    # would run inside the elevated guard
    $env:PSModulePath = ((Join-Path $PSHOME 'Modules'), (Join-Path (Get-GuardProgramFiles) 'WindowsPowerShell\Modules')) -join ';'
}

function Test-GuardTestMode {
    # Test overrides (GUARD_CONFIG, GUARD_SOURCE, GUARD_TASK, GUARD_ANSWERS, GUARD_USER) are read
    # from the environment ONLY when that can't help an attacker:
    #  - in a process without admin rights (it can't do anything the caller couldn't), or
    #  - when an administrator set GUARD_TEST=1 machine-wide (HKLM, read directly).
    # A limited agent can set user env vars (setx) that elevated processes inherit, but not HKLM.
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $admin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) { return $true }
    $k = $null
    try { $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($script:EnvKey); return ([string]$k.GetValue('GUARD_TEST', '') -eq '1') }
    catch { return $false } finally { if ($k) { $k.Close() } }
}
function Get-GuardTestEnv([string]$Name) {
    $v = [Environment]::GetEnvironmentVariable($Name)
    if (-not $v) { return $null }
    if (Test-GuardTestMode) { return $v }
    return $null
}

$script:GuardTask = 'guard'; $t = Get-GuardTestEnv 'GUARD_TASK'; if ($t) { $script:GuardTask = $t }
# elevated (or SYSTEM): from here on, modules load only from admin-only folders
if ((New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Set-GuardSafeModulePath }

# ---- machine PATH: read and write the raw value, so %SystemRoot% and friends survive ----------
function Get-GuardMachinePath {
    $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($script:EnvKey)
    try { return [string]$k.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } finally { $k.Close() }
}
function Set-GuardMachinePath([string]$Value) {
    $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($script:EnvKey, $true)
    try { $k.SetValue('Path', $Value, [Microsoft.Win32.RegistryValueKind]::ExpandString) } finally { $k.Close() }
    Send-GuardEnvChange
}
function Send-GuardEnvChange {
    # tell Explorer (and new terminals it starts) that the environment changed
    try {
        if (-not ('GuardNative.Env' -as [type])) {
            Add-Type -Namespace GuardNative -Name Env -MemberDefinition '[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessageTimeout(IntPtr h, uint m, UIntPtr w, string l, uint f, uint t, out UIntPtr r);'
        }
        $r = [UIntPtr]::Zero
        [GuardNative.Env]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 3000, [ref]$r) | Out-Null
    } catch { }
}
function Test-GuardPathHas([string]$Raw, [string]$Dir) {
    foreach ($p in ($Raw -split ';')) { if ($p -and ($p.TrimEnd('\') -ieq $Dir.TrimEnd('\'))) { return $true } }
    return $false
}
function Add-GuardMachinePath([string]$Dir) {
    $raw = Get-GuardMachinePath
    if (Test-GuardPathHas $raw $Dir) { return $false }
    Set-GuardMachinePath ($raw.TrimEnd(';') + ';' + $Dir); return $true
}
function Remove-GuardMachinePath([string]$Dir) {
    $raw = Get-GuardMachinePath
    if (-not (Test-GuardPathHas $raw $Dir)) { return $false }
    $keep = @($raw -split ';' | Where-Object { $_ -and ($_.TrimEnd('\') -ine $Dir.TrimEnd('\')) })
    Set-GuardMachinePath ($keep -join ';'); return $true
}
# A one-line guard.cmd in C:\Windows too: that folder is on the PATH of every terminal, also ones
# opened before the install, whose PATH can't be refreshed. Only admins can write there.
function Get-GuardShimPath { return (Join-Path (Get-GuardWindowsDir) 'guard.cmd') }
function Get-GuardShimText([string]$Dir) { return "@powershell -NoProfile -ExecutionPolicy Bypass -File `"$Dir\guard.ps1`" %*`r`n" }
function Add-GuardShim([string]$Dir) {
    $p = Get-GuardShimPath; $t = Get-GuardShimText $Dir
    if ((Test-Path -LiteralPath $p) -and ([IO.File]::ReadAllText($p) -eq $t)) { return $false }
    [IO.File]::WriteAllText($p, $t, (New-Object Text.ASCIIEncoding)); return $true
}
function Test-GuardShimFor([string]$Dir) {
    # only ever remove the C:\Windows\guard.cmd that points at this install
    $p = Get-GuardShimPath
    return ((Test-Path -LiteralPath $p) -and ([IO.File]::ReadAllText($p) -like "*`"$Dir\guard.ps1`"*"))
}

# ---- signed releases ----------------------------------------------------------------------
# guard installs and updates only files listed in a release list (release.json: version, commit,
# SHA-256 of every file) signed with the release key. That key lives in the TPM chip of the
# publisher's PC, needs a PIN and administrator rights to use, and can't be copied out. Someone
# who gets into the GitHub account (or an AI agent pushing code) can change main, but can't make
# a list this key accepts. guard-sign.ps1 -Setup writes the key below (and the same in install.ps1).
$script:GuardReleaseKey  = ''
$script:GuardReleaseBase = 'https://raw.githubusercontent.com/ShashwatGold1/Folder_Safety_Guard'

function Get-GuardReleaseKey {
    $k = Get-GuardTestEnv 'GUARD_RELEASE_KEY'; if ($k) { return $k }
    return $script:GuardReleaseKey
}
function Get-GuardReleaseBase {
    $b = Get-GuardTestEnv 'GUARD_RELEASE_URL'; if ($b) { return $b.TrimEnd('/') }
    return $script:GuardReleaseBase
}
function Get-GuardReleaseFiles {
    # every file a release lists, as its path in the repo
    return @('install.ps1') + @($script:GuardRuntime | ForEach-Object { "src/$_" })
}
function Get-GuardBytes([string]$Url) {
    # raw bytes: hashes are over exactly what was served (https, or file:// in tests)
    $w = New-Object Net.WebClient
    try { return $w.DownloadData($Url) } finally { $w.Dispose() }
}
function Get-GuardSha256([byte[]]$Bytes) {
    return -join ([Security.Cryptography.SHA256]::Create().ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') })
}
function Test-GuardReleaseSig([byte[]]$Data, [byte[]]$Sig, [string]$Key) {
    # RSA-2048+ PKCS#1 SHA-256 over the exact bytes; $Key = base64 modulus, exponent 65537
    if (-not $Key -or -not $Data -or -not $Sig) { return $false }
    try {
        $p = New-Object Security.Cryptography.RSAParameters
        $p.Modulus = [Convert]::FromBase64String($Key); $p.Exponent = [byte[]](1, 0, 1)
        if ($p.Modulus.Length -lt 256) { return $false }
        $rsa = New-Object Security.Cryptography.RSACng; $rsa.ImportParameters($p)
        return $rsa.VerifyData($Data, $Sig, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    } catch { return $false }
}
function Read-GuardRelease([byte[]]$Json, [byte[]]$Sig, [string]$Key) {
    # the release list, only when the signature is right and every field is well formed; else throws
    if (-not $Key) { throw 'this guard has no release key yet: no update can be checked' }
    if (-not (Test-GuardReleaseSig $Json $Sig $Key)) { throw 'the release list is not signed with the guard release key' }
    $o = (New-Object Text.UTF8Encoding($false)).GetString($Json) | ConvertFrom-Json
    if ($o.name -ne 'guard' -or "$($o.version)" -notmatch '^\d+(\.\d+){1,3}$' -or "$($o.commit)" -notmatch '^[0-9a-f]{40}$') { throw 'the release list is malformed' }
    foreach ($f in Get-GuardReleaseFiles) { if ("$($o.files.$f)" -notmatch '^[0-9a-f]{64}$') { throw "the release list has no hash for $f" } }
    return $o
}
function Get-GuardRelease {
    # @{ Ok; Release; Why; Offline }: the newest signed release list from GitHub
    $base = Get-GuardReleaseBase
    try { $j = Get-GuardBytes "$base/main/release.json"; $s = Get-GuardBytes "$base/main/release.sig" }
    catch { return @{ Ok = $false; Offline = $true; Why = "can't reach GitHub" } }
    try {
        $sig = [Convert]::FromBase64String(([Text.Encoding]::ASCII.GetString($s)).Trim())
        return @{ Ok = $true; Release = (Read-GuardRelease $j $sig (Get-GuardReleaseKey)) }
    } catch { return @{ Ok = $false; Offline = $false; Why = $_.Exception.Message } }
}
function Save-GuardReleaseFiles($Release, [string]$Dir) {
    # downloads every file of the release from ITS commit, checks each hash, writes them flat in
    # $Dir (an admin-only folder). Any mismatch: throws, and nothing in $Dir may be used.
    $base = Get-GuardReleaseBase
    foreach ($f in Get-GuardReleaseFiles) {
        $b = Get-GuardBytes "$base/$($Release.commit)/$f"
        if ((Get-GuardSha256 $b) -ne $Release.files.$f) { throw "$f from GitHub doesn't match the signed release list" }
        [IO.File]::WriteAllBytes((Join-Path $Dir (Split-Path $f -Leaf)), $b)
    }
}

function Get-GuardRemoteVersion {
    # Newest SIGNED version number, or $null when offline or not signed.
    $r = Get-GuardRelease
    if ($r.Ok) { return [string]$r.Release.version }
    return $null
}

function Test-GuardNewer {
    param([string]$Remote, [string]$Local = $script:GuardVersion)
    if (-not $Remote) { return $false }
    try { return ([version]$Remote -gt [version]$Local) } catch { return $false }
}

function Stop-GuardWatch {
    # Stop every running background guard started from $Dir (or from anywhere when $Dir is blank).
    param([string]$Dir = '')
    $n = 0
    try { Stop-ScheduledTask -TaskName $script:GuardTask -ErrorAction Stop } catch { }
    $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
             Where-Object { $_.CommandLine -like '*guard-watch.ps1*' -and $_.ProcessId -ne $PID }
    $ids = @()
    foreach ($p in $procs) {
        if ($Dir -and ($p.CommandLine -notlike "*$Dir*")) { continue }
        $ids += $p.ProcessId
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; $n++ } catch { }
    }
    # wait until they are really gone, so none writes its status file after we clean up
    for ($i = 0; $i -lt 40; $i++) {
        if (-not ($ids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })) { break }
        Start-Sleep -Milliseconds 250
    }
    return $n
}

function Start-GuardWatch {
    # Only for a real install: the scheduled task (runs as SYSTEM), else a direct start from an
    # install folder. A source checkout (tests) never starts one: it would outlive the test.
    param([string]$Dir, [string]$User)
    try { Get-ScheduledTask -TaskName $script:GuardTask -ErrorAction Stop | Out-Null; Start-ScheduledTask -TaskName $script:GuardTask; return 'task' } catch { }
    if (-not (Test-Path -LiteralPath (Join-Path $Dir 'guard.cmd'))) { return $null }
    Start-Process (Get-GuardPowerShellExe) -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$Dir\guard-watch.ps1`" -User `"$User`""
    return 'direct'
}

# Files that are never locked and can always be deleted.
$script:BuiltinSkip = @('~$*', '*.tmp', '*.temp', '*.crdownload', '*.part', 'Thumbs.db', 'desktop.ini')

function Get-GuardUser {
    # The account guard denies delete to = the interactive user who owns the files.
    return [Security.Principal.WindowsIdentity]::GetCurrent().Name  # e.g. DESKTOP-xxx\ojhas
}

function Test-GuardNoUser([string]$User) {
    # An empty account name makes icacls put the rule on BUILTIN (S-1-5-32) instead of on you:
    # the lock looks done and protects nothing. Every lock refuses it, so the failure shows.
    return [string]::IsNullOrWhiteSpace($User)
}

function Test-GuardSkip {
    param([string]$Name, [string[]]$Extra = @())
    foreach ($pat in ($script:BuiltinSkip + $Extra)) {
        if ($Name -like $pat) { return $true }
    }
    return $false
}

function Test-GuardBusy {
    # True if the file is open in another program (can't change its ACL cleanly).
    # Read access + share None: fails only if another program has it open. (ReadWrite would also
    # fail on every read-only file, and those would then never be locked.)
    param([string]$Path)
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'None')
        $fs.Close(); $fs.Dispose()
        return $false
    } catch { return $true }
}

function Invoke-Icacls {
    # Pass args as a plain array; PowerShell quotes each for us. Never add quotes by hand.
    # Errors come back in the result, never as an exception: in PowerShell 5.1 icacls's stderr,
    # redirected under ErrorActionPreference=Stop, would throw and kill the shell or the watcher.
    param([string[]]$IcaclsArgs)
    $ErrorActionPreference = 'Continue'
    $out = & (Get-GuardTool 'icacls.exe') @IcaclsArgs 2>&1 | ForEach-Object { "$_" }
    return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Code = $LASTEXITCODE; Out = ($out -join "`n") }
}

function Lock-GuardFile {
    # Deny delete on one file for the guard user. Skips temp/busy files.
    # -Force: lock even if open (used to put a lock back after a delete/move that failed)
    param([string]$Path, [string]$User, [string[]]$Skip = @(), [switch]$Force)
    $name = Split-Path $Path -Leaf
    if (Test-GuardNoUser $User) { return [pscustomobject]@{ Path=$Path; State='fail'; Reason='no account to lock for' } }
    if (Test-GuardSkip -Name $name -Extra $Skip) { return [pscustomobject]@{ Path=$Path; State='skipped'; Reason='skip-list' } }
    if (-not $Force -and (Test-GuardBusy -Path $Path)) { return [pscustomobject]@{ Path=$Path; State='waiting'; Reason='open in another program' } }
    if (Test-GuardAdmin) { Invoke-Icacls @($Path, '/setowner', 'NT AUTHORITY\SYSTEM') | Out-Null }
    $r = Invoke-Icacls @($Path, '/deny', ($User+':(DE)'))
    if ($r.Ok) { return [pscustomobject]@{ Path=$Path; State='locked' } }
    return [pscustomobject]@{ Path=$Path; State='fail'; Reason=$r.Out }
}

function Unlock-GuardFile {
    param([string]$Path, [string]$User)
    $r = Invoke-Icacls @($Path, '/remove:d', $User)
    if ($r.Ok) { return [pscustomobject]@{ Path=$Path; State='unlocked' } }
    return [pscustomobject]@{ Path=$Path; State='fail'; Reason=$r.Out }
}

function Test-GuardAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Set-GuardOwnerSystem {
    # Make SYSTEM the owner of the folder and everything in it, and give the user read/write
    # back so files still open and programs can still add new files. Admin only.
    param([string]$Folder, [string]$User)
    if (-not (Test-GuardAdmin)) { return [pscustomobject]@{ Ok=$false; Reason='not admin' } }
    if (Test-GuardNoUser $User) { return [pscustomobject]@{ Ok=$false; Reason='no account to lock for' } }
    $r1 = Invoke-Icacls @($Folder, '/setowner', 'NT AUTHORITY\SYSTEM', '/T', '/C')
    # cut inheritance (keep copies), then replace the user's Full Control with Modify:
    # read, write, add files, but no permission changes and no take-ownership.
    $r2 = Invoke-Icacls @($Folder, '/inheritance:d')
    $r3 = Invoke-Icacls @($Folder, '/remove:g', $User, '/T', '/C')
    # Broad grants copied from above can carry Full Control (= change permissions, delete inside):
    # CREATOR OWNER:F on a drive root gives every new item's creator Full Control, and a group
    # the user is in (Everyone, Users, Authenticated Users, INTERACTIVE) may hold F or M.
    # Remove them all; groups that could see the folder before get read-only back.
    $broad = @('S-1-3-0','S-1-1-0','S-1-5-11','S-1-5-32-545','S-1-5-4')
    $had = @()
    try {
        foreach ($a in (Get-Acl -LiteralPath $Folder).Access) {
            if ($a.AccessControlType -ne 'Allow') { continue }
            try { $sid = $a.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { continue }
            if (($broad -contains $sid) -and ($had -notcontains $sid)) { $had += $sid }
        }
    } catch { }
    foreach ($sid in $broad) { Invoke-Icacls @($Folder, '/remove:g', "*$sid", '/T', '/C') | Out-Null }
    foreach ($sid in $had) { if ($sid -ne 'S-1-3-0') { Invoke-Icacls @($Folder, '/grant', "*${sid}:(OI)(CI)RX") | Out-Null } }
    $r4 = Invoke-Icacls @($Folder, '/grant', ($User+':(OI)(CI)M'))
    # OWNER RIGHTS = Modify: files the user creates can't have their lock changed by the user either
    $r5 = Invoke-Icacls @($Folder, '/grant', '*S-1-3-4:(OI)(CI)M')
    return [pscustomobject]@{ Ok=($r1.Ok -and $r2.Ok -and $r3.Ok -and $r4.Ok -and $r5.Ok); Out=($r1.Out,$r2.Out,$r3.Out,$r4.Out,$r5.Out -join "`n") }
}

function Set-GuardOwnerUser {
    # Give ownership back to the user (used by remove/uninstall). Admin only.
    param([string]$Folder, [string]$User)
    if (-not (Test-GuardAdmin)) { return [pscustomobject]@{ Ok=$false; Reason='not admin' } }
    $r = Invoke-Icacls @($Folder, '/setowner', $User, '/T', '/C')
    $r2 = Invoke-Icacls @($Folder, '/reset', '/T', '/C')   # back to normal inherited permissions
    return [pscustomobject]@{ Ok=($r.Ok -and $r2.Ok); Out=($r.Out + "`n" + $r2.Out) }
}

function Lock-GuardFolder {
    # Three rules: the folder can't be deleted/renamed AND can't delete its own children (DE,DC);
    # the folder above can't delete this folder through its key (DC).
    param([string]$Folder, [string]$User)
    $above = Split-Path $Folder -Parent
    if (Test-GuardNoUser $User) { return [pscustomobject]@{ Folder=$false; FolderOut='no account to lock for'; Above=$false; AboveOut='no account to lock for'; Ok=$false } }
    $r1 = Invoke-Icacls @($Folder, '/deny', ($User+':(DE,DC)'))
    $r2 = Invoke-Icacls @($above,  '/deny', ($User+':(DC)'))
    return [pscustomobject]@{
        Folder = $r1.Ok; FolderOut = $r1.Out
        Above  = $r2.Ok; AboveOut  = $r2.Out
        Ok     = ($r1.Ok -and $r2.Ok)
    }
}

function Unlock-GuardFolder {
    # -KeepAbove: another protected folder lives in the same folder above and still needs its rule.
    param([string]$Folder, [string]$User, [switch]$KeepAbove)
    $above = Split-Path $Folder -Parent
    $r1 = Invoke-Icacls @($Folder, '/remove:d', $User)
    if ($KeepAbove) { return [pscustomobject]@{ Ok = $r1.Ok; FolderOut=$r1.Out; AboveOut='kept' } }
    $r2 = Invoke-Icacls @($above,  '/remove:d', $User)
    return [pscustomobject]@{ Ok = ($r1.Ok -and $r2.Ok); FolderOut=$r1.Out; AboveOut=$r2.Out }
}

function Get-GuardFiles {
    # Every file under the folder, subfolders included.
    param([string]$Folder)
    return Get-ChildItem -LiteralPath $Folder -Recurse -File -Force -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -ne '_guard.json' }
}

function Lock-GuardSubfolder {
    # A subfolder can't be renamed or moved out (DE) and can't delete what is inside it (DC).
    # Its files are locked one by one too.
    param([string]$Path, [string]$User)
    if (Test-GuardNoUser $User) { return $false }
    if (Test-GuardAdmin) { Invoke-Icacls @($Path, '/setowner', 'NT AUTHORITY\SYSTEM') | Out-Null }
    return (Invoke-Icacls @($Path, '/deny', ($User+':(DE,DC)'))).Ok
}

function Get-GuardSubfolders {
    param([string]$Folder)
    return Get-ChildItem -LiteralPath $Folder -Recurse -Directory -Force -ErrorAction SilentlyContinue
}

function Lock-GuardTree {
    # Lock the folder, the folder above, every subfolder and every file. Returns counts + the not-locked list.
    # -ShouldStop: checked before every item; returning $true stops early (background guard: config changed).
    param([string]$Folder, [string]$User, [string[]]$Skip = @(), [scriptblock]$ShouldStop = $null)
    $folderRes = Lock-GuardFolder -Folder $Folder -User $User
    $locked = 0; $waiting = @(); $skipped = 0; $failed = @(); $stopped = $false
    foreach ($d in (Get-GuardSubfolders -Folder $Folder)) {
        if ($ShouldStop -and (& $ShouldStop)) { $stopped = $true; break }
        Lock-GuardSubfolder -Path $d.FullName -User $User | Out-Null
    }
    foreach ($f in (Get-GuardFiles -Folder $Folder)) {
        if ($stopped -or ($ShouldStop -and (& $ShouldStop))) { $stopped = $true; break }
        $r = Lock-GuardFile -Path $f.FullName -User $User -Skip $Skip
        switch ($r.State) {
            'locked'  { $locked++ }
            'skipped' { $skipped++ }
            'waiting' { $waiting += [pscustomobject]@{ Name=$f.Name; Reason=$r.Reason; Path=$f.FullName } }
            'fail'    { $failed  += [pscustomobject]@{ Name=$f.Name; Reason=$r.Reason; Path=$f.FullName } }
        }
    }
    # Explorer badges: the files not locked get the red one
    if (-not $stopped) { Set-GuardBadgeOpen -Folder $Folder -Paths @(@($waiting) + @($failed) | ForEach-Object { $_.Path }) }
    return [pscustomobject]@{
        FolderOk = $folderRes.Ok; FolderRes = $folderRes
        Locked = $locked; Skipped = $skipped; Waiting = $waiting; Failed = $failed; Stopped = $stopped
    }
}

function Unlock-GuardTree {
    param([string]$Folder, [string]$User, [switch]$KeepAbove)
    $n = 0
    foreach ($f in (Get-GuardFiles -Folder $Folder)) {
        $r = Unlock-GuardFile -Path $f.FullName -User $User
        if ($r.State -eq 'unlocked') { $n++ }
    }
    foreach ($d in (Get-GuardSubfolders -Folder $Folder)) { Invoke-Icacls @($d.FullName, '/remove:d', $User) | Out-Null }
    $folderRes = Unlock-GuardFolder -Folder $Folder -User $User -KeepAbove:$KeepAbove
    return [pscustomobject]@{ FolderOk = $folderRes.Ok; Unlocked = $n }
}

# the badges Explorer shows on protected folders and files
. "$PSScriptRoot\guard-badges.ps1"
