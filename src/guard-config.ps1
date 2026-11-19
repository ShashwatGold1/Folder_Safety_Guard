# guard-config.ps1 — the memory: config.json (fast copy) + _guard.json in every protected folder.
# Dot-sourced after guard-core.ps1.

# Overridable so tests can redirect away from C:\ProgramData.
$script:GuardConfigIsTest = [bool]$script:GuardConfigPath
if (-not $script:GuardConfigPath) {
    $t = Get-GuardTestEnv 'GUARD_CONFIG'   # tests only; ignored in admin processes unless HKLM GUARD_TEST=1
    if ($t) { $script:GuardConfigPath = $t; $script:GuardConfigIsTest = $true }
    else { $script:GuardConfigPath = Join-Path (Get-GuardProgramData) 'guard\config.json' }
}

# ---- the data folder: only SYSTEM and administrators may write in it ----------------------
# C:\ProgramData lets every user create files and folders inside its subfolders. A program
# without admin rights could then plant a config.json (folders, skip lists), a badges.txt or a
# status file that the elevated guard would trust. So the folder gets permissions of its own
# (inherited ones removed), its owner is Administrators, and guard trusts only files owned by
# SYSTEM or Administrators: files a normal process creates are owned by that user.
$script:TrustedOwners = @('S-1-5-18', 'S-1-5-32-544')   # SYSTEM, Administrators
function Test-GuardTrustedOwner([string]$Path) {
    try { $o = (Get-Acl -LiteralPath $Path -ErrorAction Stop).GetOwner([Security.Principal.SecurityIdentifier]).Value } catch { return $false }
    return ($script:TrustedOwners -contains $o)
}
function Test-GuardTrustedFile([string]$Path) {
    # tests point the config somewhere of their own: nothing to check there
    if ($script:GuardConfigIsTest) { return $true }
    return (Test-GuardTrustedOwner $Path)
}
function Initialize-GuardDataDir {
    # Creates the data folder, or repairs one an older guard (or an attacker) left behind.
    # Returns the names of files it removed because they weren't written by guard. Admin only.
    $dir = Split-Path $script:GuardConfigPath -Parent
    if ($script:GuardConfigIsTest) { if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }; return @() }
    if (-not (Test-GuardAdmin)) { return @() }
    $removed = @()
    if ((Test-Path -LiteralPath $dir) -and -not (Test-GuardTrustedOwner $dir)) {
        # made by someone else before guard: nothing in it can be trusted
        $removed += @(Get-ChildItem -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        Invoke-Icacls @($dir, '/setowner', '*S-1-5-32-544', '/T', '/C') | Out-Null
        Invoke-Icacls @($dir, '/reset', '/T', '/C') | Out-Null
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Invoke-Icacls @($dir, '/setowner', '*S-1-5-32-544') | Out-Null
    Invoke-Icacls @($dir, '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-32-545:(OI)(CI)RX') | Out-Null
    foreach ($x in @(Get-ChildItem -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue)) {
        if (Test-GuardTrustedOwner $x.FullName) { Invoke-Icacls @($x.FullName, '/reset') | Out-Null; continue }
        $removed += $x.Name
        Remove-Item -LiteralPath $x.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    return @($removed | Select-Object -Unique)
}

function New-GuardConfig {
    return [pscustomobject]@{
        version = '1.0'
        current = 0
        folders = @()   # each: @{ path; name; skip=@(); added }
        saved   = (Get-Date).ToString('o')
    }
}

function Read-GuardJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json } catch { return $null }
}

function Write-GuardJsonFile {
    param([string]$Path, $Config)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = $Config | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Save-GuardConfig {
    # Write the master copy and a hidden _guard.json into every protected folder.
    param($Config, [string]$User)
    # one stamp for every copy: identical copies, and the background guard can report which it has
    $Config.saved = (Get-Date).ToString('o')
    if (-not (Test-Path -LiteralPath (Split-Path $script:GuardConfigPath -Parent))) { Initialize-GuardDataDir | Out-Null }
    Write-GuardJsonFile -Path $script:GuardConfigPath -Config $Config
    Write-GuardBadges -Config $Config   # Explorer badges follow every change
    foreach ($f in $Config.folders) {
        if (-not (Test-Path -LiteralPath $f.path)) { continue }
        $jp = Join-Path $f.path '_guard.json'
        # must unlock before overwriting (it is a protected file), then re-lock
        if ($User -and (Test-Path -LiteralPath $jp)) { Unlock-GuardFile -Path $jp -User $User | Out-Null }
        try {
            Write-GuardJsonFile -Path $jp -Config $Config
            (Get-Item -LiteralPath $jp -Force).Attributes = 'Hidden'
            if ($User) { Lock-GuardFile -Path $jp -User $User | Out-Null }
        } catch { }
    }
}

function Load-GuardConfig {
    # Master copy if present; else rebuild from the newest _guard.json found.
    # (a config.json guard didn't write itself is ignored: see Initialize-GuardDataDir)
    if ((Test-Path -LiteralPath $script:GuardConfigPath) -and (Test-GuardTrustedFile $script:GuardConfigPath)) {
        $c = Read-GuardJson -Path $script:GuardConfigPath
        if ($c) { return $c }
    }
    $found = Find-GuardMemory
    if ($found) { return $found }
    return New-GuardConfig
}

$script:MemoryFoundIn = $null   # set by Find-GuardMemory: the folder whose _guard.json was used

function Find-GuardMemory {
    # Search likely places for any _guard.json; return the newest config it holds.
    $places = @(
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('MyDocuments'),
        (Join-Path $env:USERPROFILE 'Downloads'),
        [Environment]::GetFolderPath('MyPictures')
    )
    foreach ($d in ([IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady } | ForEach-Object { $_.RootDirectory.FullName })) { $places += $d }
    $best = $null; $bestTime = [datetime]::MinValue
    foreach ($place in ($places | Select-Object -Unique)) {
        # SYSTEM has no Documents/Pictures: those come back empty
        if (-not $place -or -not (Test-Path -LiteralPath $place)) { continue }
        Get-ChildItem -LiteralPath $place -Filter '_guard.json' -Recurse -Force -Depth 4 -ErrorAction SilentlyContinue | ForEach-Object {
            $c = Read-GuardJson -Path $_.FullName
            if ($c -and $c.saved) {
                $t = [datetime]::MinValue; try { $t = [datetime]$c.saved } catch { }
                # a date in the future can't be real: a planted file trying to win
                if ($t -gt (Get-Date).AddDays(1)) { return }
                if ($t -gt $bestTime) { $bestTime = $t; $best = $c; $script:MemoryFoundIn = $_.DirectoryName }
            }
        }
    }
    return $best
}

function Get-FolderName {
    param([string]$Path)
    return Split-Path $Path -Leaf
}
