# guard-config.ps1 — the memory: config.json (fast copy) + _guard.json in every protected folder.
# Dot-sourced after guard-core.ps1.

# Overridable so tests can redirect away from C:\ProgramData.
if (-not $script:GuardConfigPath) {
    $t = Get-GuardTestEnv 'GUARD_CONFIG'   # tests only; ignored in admin processes unless HKLM GUARD_TEST=1
    if ($t) { $script:GuardConfigPath = $t }
    else { $script:GuardConfigPath = Join-Path $env:ProgramData 'guard\config.json' }
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
    if (Test-Path -LiteralPath $script:GuardConfigPath) {
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
                $t = [datetime]$c.saved
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
