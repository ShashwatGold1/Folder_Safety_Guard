# guard-core.ps1 — locking engine, no UI. Dot-sourced by guard.ps1, the watcher, and tests.
# All functions return a result object; they never write to the host.

$ErrorActionPreference = 'Stop'

# Files that are never locked and can always be deleted.
$script:BuiltinSkip = @('~$*', '*.tmp', '*.temp', '*.crdownload', '*.part', 'Thumbs.db', 'desktop.ini')

function Get-GuardUser {
    # The account guard denies delete to = the interactive user who owns the files.
    return [Security.Principal.WindowsIdentity]::GetCurrent().Name  # e.g. DESKTOP-xxx\ojhas
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
    param([string]$Path)
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
        $fs.Close(); $fs.Dispose()
        return $false
    } catch { return $true }
}

function Invoke-Icacls {
    # Pass args as a plain array; PowerShell quotes each for us. Never add quotes by hand.
    param([string[]]$IcaclsArgs)
    $out = & icacls.exe @IcaclsArgs 2>&1
    return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Code = $LASTEXITCODE; Out = ($out -join "`n") }
}

function Lock-GuardFile {
    # Deny delete on one file for the guard user. Skips temp/busy files.
    param([string]$Path, [string]$User, [string[]]$Skip = @())
    $name = Split-Path $Path -Leaf
    if (Test-GuardSkip -Name $name -Extra $Skip) { return [pscustomobject]@{ Path=$Path; State='skipped'; Reason='skip-list' } }
    if ($name -like '_guard.json') { } # the memory file is locked like any other
    if (Test-GuardBusy -Path $Path)  { return [pscustomobject]@{ Path=$Path; State='waiting'; Reason='open in another program' } }
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

function Lock-GuardFolder {
    # Three rules: the folder can't be deleted/renamed AND can't delete its own children (DE,DC);
    # the folder above can't delete this folder through its key (DC).
    param([string]$Folder, [string]$User)
    $above = Split-Path $Folder -Parent
    $r1 = Invoke-Icacls @($Folder, '/deny', ($User+':(DE,DC)'))
    $r2 = Invoke-Icacls @($above,  '/deny', ($User+':(DC)'))
    return [pscustomobject]@{
        Folder = $r1.Ok; FolderOut = $r1.Out
        Above  = $r2.Ok; AboveOut  = $r2.Out
        Ok     = ($r1.Ok -and $r2.Ok)
    }
}

function Unlock-GuardFolder {
    param([string]$Folder, [string]$User)
    $above = Split-Path $Folder -Parent
    $r1 = Invoke-Icacls @($Folder, '/remove:d', $User)
    $r2 = Invoke-Icacls @($above,  '/remove:d', $User)
    return [pscustomobject]@{ Ok = ($r1.Ok -and $r2.Ok); FolderOut=$r1.Out; AboveOut=$r2.Out }
}

function Get-GuardFiles {
    # Every file under the folder, subfolders included.
    param([string]$Folder)
    return Get-ChildItem -LiteralPath $Folder -Recurse -File -Force -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -ne '_guard.json' }
}

function Lock-GuardTree {
    # Lock the folder, the folder above, and every file. Returns counts + the not-locked list.
    param([string]$Folder, [string]$User, [string[]]$Skip = @())
    $folderRes = Lock-GuardFolder -Folder $Folder -User $User
    $locked = 0; $waiting = @(); $skipped = 0; $failed = @()
    foreach ($f in (Get-GuardFiles -Folder $Folder)) {
        $r = Lock-GuardFile -Path $f.FullName -User $User -Skip $Skip
        switch ($r.State) {
            'locked'  { $locked++ }
            'skipped' { $skipped++ }
            'waiting' { $waiting += [pscustomobject]@{ Name=$f.Name; Reason=$r.Reason } }
            'fail'    { $failed  += [pscustomobject]@{ Name=$f.Name; Reason=$r.Reason } }
        }
    }
    return [pscustomobject]@{
        FolderOk = $folderRes.Ok; FolderRes = $folderRes
        Locked = $locked; Skipped = $skipped; Waiting = $waiting; Failed = $failed
    }
}

function Unlock-GuardTree {
    param([string]$Folder, [string]$User)
    $n = 0
    foreach ($f in (Get-GuardFiles -Folder $Folder)) {
        $r = Unlock-GuardFile -Path $f.FullName -User $User
        if ($r.State -eq 'unlocked') { $n++ }
    }
    $folderRes = Unlock-GuardFolder -Folder $Folder -User $User
    return [pscustomobject]@{ FolderOk = $folderRes.Ok; Unlocked = $n }
}
