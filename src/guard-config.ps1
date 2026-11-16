# guard-config.ps1 — the memory: config.json (fast copy) + _guard.json in every protected folder.
# Dot-sourced after guard-core.ps1.

# Overridable so tests can redirect away from C:\ProgramData.
if (-not $script:GuardConfigPath) { $script:GuardConfigPath = Join-Path $env:ProgramData 'guard\config.json' }

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
    $Config.saved = (Get-Date).ToString('o')
    $json = $Config | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Save-GuardConfig {
    # Write the master copy and a hidden _guard.json into every protected folder.
    param($Config, [string]$User)
    Write-GuardJsonFile -Path $script:GuardConfigPath -Config $Config
    foreach ($f in $Config.folders) {
        if (-not (Test-Path -LiteralPath $f.path)) { continue }
        $jp = Join-Path $f.path '_guard.json'
        # must unlock before overwriting (it is a protected file), then re-lock
        if ($User) { Unlock-GuardFile -Path $jp -User $User | Out-Null }
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
        if (-not (Test-Path -LiteralPath $place)) { continue }
        Get-ChildItem -LiteralPath $place -Filter '_guard.json' -Recurse -Force -Depth 4 -ErrorAction SilentlyContinue | ForEach-Object {
            $c = Read-GuardJson -Path $_.FullName
            if ($c -and $c.saved) {
                $t = [datetime]$c.saved
                if ($t -gt $bestTime) { $bestTime = $t; $best = $c }
            }
        }
    }
    return $best
}

function Get-FolderName {
    param([string]$Path)
    return Split-Path $Path -Leaf
}
