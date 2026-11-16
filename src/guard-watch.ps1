# guard-watch.ps1 — the background guard. Runs as SYSTEM from a logon task (or by hand in tests).
# Full-checks every protected folder, then locks each new finished file as it lands.
param([string]$User, [switch]$Once)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$here\guard-core.ps1"
. "$here\guard-config.ps1"

if (-not $User) { $User = $env:GUARD_USER }
if (-not $User) { try { $User = Get-GuardUser } catch { } }

$statusFile = Join-Path $env:ProgramData 'guard\watch-status.json'

function Write-WatchStatus($msg) {
    try {
        $dir = Split-Path $statusFile -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [pscustomobject]@{ alive=(Get-Date).ToString('o'); note=$msg } | ConvertTo-Json | Set-Content -LiteralPath $statusFile -Encoding UTF8
    } catch { }
}

function Full-Check {
    $cfg = Load-GuardConfig
    foreach ($f in $cfg.folders) {
        if (-not (Test-Path -LiteralPath $f.path)) { continue }
        $skip = @(); if ($f.skip) { $skip = @($f.skip) }
        Lock-GuardTree -Folder $f.path -User $User -Skip $skip | Out-Null
    }
    Write-WatchStatus "full check done"
    return $cfg
}

Full-Check | Out-Null
if ($Once) { return }

# Poll loop: a FileSystemWatcher signals us (low latency), but the actual locking is done
# here in the main scope where the functions exist. A periodic sweep is the safety net.
$signal = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
$watchers = @()
$cfg = Load-GuardConfig
foreach ($f in $cfg.folders) {
    if (-not (Test-Path -LiteralPath $f.path)) { continue }
    $w = New-Object IO.FileSystemWatcher $f.path
    $w.IncludeSubdirectories = $true
    $w.EnableRaisingEvents = $true
    $md = [pscustomobject]@{ Q = $signal }
    $sb = { $Event.MessageData.Q.Enqueue($Event.SourceEventArgs.FullPath) }
    Register-ObjectEvent -InputObject $w -EventName Created -Action $sb -MessageData $md | Out-Null
    Register-ObjectEvent -InputObject $w -EventName Renamed -Action $sb -MessageData $md | Out-Null
    $watchers += $w
}
Write-WatchStatus "watching $($watchers.Count) folders"

$sinceSweep = 0
while ($true) {
    Start-Sleep -Milliseconds 700
    $hit = $false; $p = $null
    while ($signal.TryDequeue([ref]$p)) {
        $hit = $true
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        $name = Split-Path $p -Leaf
        if ($name -eq '_guard.json') { continue }
        if (Test-GuardSkip -Name $name) { continue }
        # which folder's skip list applies
        $skip = @()
        foreach ($f in $cfg.folders) { if ($p.StartsWith($f.path, [StringComparison]::OrdinalIgnoreCase)) { if ($f.skip) { $skip = @($f.skip) }; break } }
        if (Test-GuardSkip -Name $name -Extra $skip) { continue }
        Lock-GuardFile -Path $p -User $User -Skip $skip | Out-Null
    }
    if ($hit) { Write-WatchStatus 'locked new file(s)' }
    $sinceSweep += 0.7
    if ($sinceSweep -ge 300) { $cfg = Full-Check; $sinceSweep = 0 }
}
