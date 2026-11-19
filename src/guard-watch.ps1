# guard-watch.ps1 — the background guard. Runs as SYSTEM from a logon task (or by hand in tests).
# Full-checks every protected folder, then locks each new finished file as it lands.
#  - reads only config.json (restoring old memory is the user's choice, never done here)
#  - config changed -> stop any full check at once, reload, lock only what changed
#  - writes a heartbeat (watch-status.json) incl. which config it has loaded, so the shell
#    can wait until the background guard has seen an 'edit' before it unlocks anything
#  - leaves folders in 'edit' alone until the user's next logon
param([string]$User, [switch]$Once)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$here\guard-core.ps1"
. "$here\guard-config.ps1"

if (-not $User) { $User = Get-GuardTestEnv 'GUARD_USER' }
if (-not $User) { try { $User = Get-GuardUser } catch { } }

$dataDir    = Split-Path $script:GuardConfigPath -Parent
$statusFile = Join-Path $dataDir 'watch-status.json'
$errorFile  = Join-Path $dataDir 'watch-error.log'
$script:LastFull = $null; $script:LastLock = $null; $script:Latest = $null; $script:LoadedSaved = $null

# any crash: write down why (guard shows STOPPED; the task restarts us), then end
trap {
    try { "{0:o}  {1}`r`n{2}" -f (Get-Date), $_.Exception.Message, $_.ScriptStackTrace | Add-Content -LiteralPath $errorFile } catch { }
    break
}

function Write-WatchStatus($msg) {
    try {
        if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }
        $json = [pscustomobject]@{
            alive    = (Get-Date).ToString('o')
            lastFull = $script:LastFull
            lastLock = $script:LastLock
            config   = $script:LoadedSaved      # 'saved' stamp of the config this guard acts on
            version  = $script:GuardVersion
            latest   = $script:Latest
            note     = $msg
        } | ConvertTo-Json
        # write aside, then swap in: a reader never sees a half-written file
        $tmp = "$statusFile.tmp"
        [IO.File]::WriteAllText($tmp, $json)
        Move-Item -LiteralPath $tmp -Destination $statusFile -Force
    } catch { }
}

function Config-Stamp {
    try { return (Get-Item -LiteralPath $script:GuardConfigPath -ErrorAction Stop).LastWriteTimeUtc.Ticks } catch { return 0 }
}

function Load-WatchConfig {
    # only a config.json written by guard (owner SYSTEM / Administrators) is acted on
    $c = $null
    if (Test-GuardTrustedFile $script:GuardConfigPath) { $c = Read-GuardJson -Path $script:GuardConfigPath }
    if (-not $c) { $c = New-GuardConfig }
    $script:LoadedSaved = $c.saved
    return $c
}

function Get-LogonTime {
    # The user's current logon = when their Explorer started. $null if unknown.
    try {
        $e = Get-Process explorer -IncludeUserName -ErrorAction Stop | Where-Object { $_.UserName -eq $User } |
             Sort-Object StartTime | Select-Object -First 1
        if ($e) { return $e.StartTime }
    } catch { }
    try { return (Get-Process explorer -ErrorAction Stop | Sort-Object StartTime | Select-Object -First 1).StartTime } catch { }
    return $null
}

function Expire-Edits($cfg) {
    # A folder left in 'edit' locks again once the user has logged on after the edit started.
    $logon = Get-LogonTime
    if (-not $logon) { return $false }
    $changed = $false
    foreach ($f in $cfg.folders) {
        if ($f.editing -and $f.editingSince -and ([datetime]$f.editingSince -lt $logon)) {
            $f.editing = $false; $changed = $true
        }
    }
    if ($changed) { Save-GuardConfig -Config $cfg -User $User; $script:LoadedSaved = $cfg.saved }
    return $changed
}

function Lock-Folders($cfg, $paths) {
    # Lock the given folders (all when $paths is $null). Stops early if config.json changes.
    # Returns $false if it stopped early.
    $script:StopStamp = Config-Stamp
    $stop = { (Config-Stamp) -ne $script:StopStamp }
    foreach ($f in $cfg.folders) {
        if ($paths -and ($paths -notcontains $f.path)) { continue }
        if ($f.editing) { continue }
        if (-not (Test-Path -LiteralPath $f.path)) { continue }
        $skip = @(); if ($f.skip) { $skip = @($f.skip) }
        $r = Lock-GuardTree -Folder $f.path -User $User -Skip $skip -ShouldStop $stop
        if ($r.Stopped) { return $false }
    }
    return $true
}

function Full-Check($cfg) {
    Expire-Edits $cfg | Out-Null
    $done = Lock-Folders $cfg $null
    if ($done) { $script:LastFull = (Get-Date).ToString('o'); Write-WatchStatus 'full check done' }
    return $done
}

# ---- start ----------------------------------------------------------------
Initialize-GuardDataDir | Out-Null   # the data folder: only SYSTEM and administrators may write in it
$stamp = Config-Stamp          # taken BEFORE loading: a change while we start is never missed
$cfg = Load-WatchConfig
Write-WatchStatus 'starting'
$needFull = -not (Full-Check $cfg)
if ($Once) { return }

$signal = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
$script:Watchers = @()

function Start-Watchers($cfg) {
    foreach ($w in $script:Watchers) { try { $w.EnableRaisingEvents = $false; $w.Dispose() } catch { } }
    Get-EventSubscriber -ErrorAction SilentlyContinue | Unregister-Event -ErrorAction SilentlyContinue
    $script:Watchers = @()
    foreach ($f in $cfg.folders) {
        if (-not (Test-Path -LiteralPath $f.path)) { continue }
        try {
            $w = New-Object IO.FileSystemWatcher $f.path
            $w.IncludeSubdirectories = $true
            $w.InternalBufferSize = 65536
            $w.EnableRaisingEvents = $true
            $md = [pscustomobject]@{ Q = $signal }
            $sb = { $Event.MessageData.Q.Enqueue($Event.SourceEventArgs.FullPath) }
            Register-ObjectEvent -InputObject $w -EventName Created -Action $sb -MessageData $md | Out-Null
            Register-ObjectEvent -InputObject $w -EventName Renamed -Action $sb -MessageData $md | Out-Null
            $script:Watchers += $w
        } catch { }
    }
}

Start-Watchers $cfg
Write-WatchStatus "watching $($script:Watchers.Count) folders"

$tick = 0.7; $sinceSweep = 0.0; $sinceBeat = 0.0
$sinceUpdate = 21600.0 - 60   # first update check one minute after start, then every 6 hours
while ($true) { try {
    Start-Sleep -Milliseconds 700

    # config changed (init / remove / edit / resume / move folder)? checked every tick, before
    # new files are handled, so a folder just put in 'edit' is never locked by mistake
    $now = Config-Stamp
    if ($now -ne $stamp) {
        $old = $cfg
        $stamp = $now
        $cfg = Load-WatchConfig
        Start-Watchers $cfg
        Write-WatchStatus 'config reloaded'          # the shell waits for this before unlocking
        # lock only what changed: new folders, and folders that just left 'edit'
        $was = @{}; foreach ($f in $old.folders) { $was[$f.path] = $f }
        $todo = @()
        foreach ($f in $cfg.folders) {
            $o = $was[$f.path]
            if (-not $o -or ($o.editing -and -not $f.editing)) { $todo += $f.path }
        }
        # stopped early (config changed again) -> next tick reloads, then a full check catches up
        if ($todo.Count -and -not (Lock-Folders $cfg $todo)) { $needFull = $true; continue }
    }

    $p = $null
    while ($signal.TryDequeue([ref]$p)) {
        $folder = $null
        foreach ($f in $cfg.folders) { if ($p.StartsWith($f.path + '\', [StringComparison]::OrdinalIgnoreCase)) { $folder = $f; break } }
        if (-not $folder) { continue }
        if ($folder.editing) { continue }
        $skip = @(); if ($folder.skip) { $skip = @($folder.skip) }
        if (Test-Path -LiteralPath $p -PathType Container) {
            # new or renamed-in subfolder: lock it and anything already inside
            Lock-GuardSubfolder -Path $p -User $User | Out-Null
            foreach ($x in (Get-ChildItem -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue)) {
                if ($x.PSIsContainer) { Lock-GuardSubfolder -Path $x.FullName -User $User | Out-Null }
                elseif ($x.Name -ne '_guard.json') { Lock-GuardFile -Path $x.FullName -User $User -Skip $skip | Out-Null }
            }
            $script:LastLock = (Get-Date).ToString('o'); Write-WatchStatus 'locked new folder'
            continue
        }
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        if ((Split-Path $p -Leaf) -eq '_guard.json') { continue }
        $r = Lock-GuardFile -Path $p -User $User -Skip $skip
        if ($r.State -eq 'locked') { $script:LastLock = (Get-Date).ToString('o'); Write-WatchStatus 'locked new file' }
        if ($r.State -ne 'skipped') { Set-GuardBadgeFile -Path $p -Locked:($r.State -eq 'locked') }   # red badge until it is locked
    }

    $sinceUpdate += $tick
    if ($sinceUpdate -ge 21600) {
        $sinceUpdate = 0
        $v = Get-GuardRemoteVersion          # offline -> $null -> no update line
        if ($v) { $script:Latest = $v }
        Write-WatchStatus 'update check'
    }

    $sinceBeat += $tick
    if ($sinceBeat -ge 30) { $sinceBeat = 0; Write-WatchStatus 'alive' }

    # every 5 minutes: lock anything missed (a file still open earlier, a missed event)
    $sinceSweep += $tick
    if ($sinceSweep -ge 300 -or $needFull) {
        $sinceSweep = 0
        $needFull = -not (Full-Check $cfg)    # stopped early by a config change -> retry after reload
    }
} catch {
    # one bad moment (a file vanished mid-lock...) must not end the background guard:
    # write it down (log kept under 1 MB), catch up with a full check, keep going
    try { if ((Get-Item -LiteralPath $errorFile -EA Stop).Length -gt 1MB) { Remove-Item -LiteralPath $errorFile -Force } } catch { }
    try { "{0:o}  {1}`r`n{2}" -f (Get-Date), $_.Exception.Message, $_.ScriptStackTrace | Add-Content -LiteralPath $errorFile } catch { }
    $needFull = $true
    Start-Sleep -Seconds 2
} }
