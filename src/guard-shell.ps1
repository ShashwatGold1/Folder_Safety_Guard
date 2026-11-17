# guard-shell.ps1 — the interactive program. Command handlers are separate functions so they
# can be driven by tests. Input goes through $script:InputProvider (a queue in tests, Read-Host live).

. "$PSScriptRoot\guard-core.ps1"
. "$PSScriptRoot\guard-config.ps1"

$script:Cfg  = $null
$script:User = $null
$script:Editing = @{}   # path -> $true while a folder is in 'edit' (unlocked) state

# ---- input / output -------------------------------------------------------
function Read-Line([string]$Prompt) {
    # tests: answers come from a queue, or from GUARD_ANSWERS ("1;YES;...") across processes.
    # GUARD_ANSWERS is ignored in an admin process unless an admin set HKLM GUARD_TEST=1, so an
    # agent can't pre-answer YES prompts with setx.
    $ans = Get-GuardTestEnv 'GUARD_ANSWERS'
    if (-not $script:InputQueue -and $ans) {
        $script:InputQueue = New-Object System.Collections.Queue
        foreach ($x in ($ans -split ';')) { $script:InputQueue.Enqueue($x) }
        $env:GUARD_ANSWERS = ''
    }
    if ($script:InputQueue -and $script:InputQueue.Count -gt 0) {
        $v = $script:InputQueue.Dequeue()
        Write-Host ($Prompt + $v) -ForegroundColor DarkGray
        return $v
    }
    # not Read-Host: it always adds ': ' after the prompt
    Write-Host -NoNewline $Prompt
    $v = [Console]::ReadLine()
    if ($null -eq $v) { return '' }   # input closed = cancel
    return $v.Trim()
}
function Say([string]$t, [string]$c = 'Gray') { Write-Host $t -ForegroundColor $c }
function Ok([string]$label, [string]$detail) { Write-Host ("  {0,-9} {1,-40} ok" -f $label, $detail) -ForegroundColor Green }

# ---- helpers --------------------------------------------------------------
function Cur { if ($script:Cfg.folders.Count -eq 0) { return $null }; return $script:Cfg.folders[$script:Cfg.current] }
# NB: a function returning a 1-item array hands back the bare item; callers wrap it: @(Folder-Skip $f)
function Folder-Skip($f) { if ($f.skip) { return @($f.skip) } else { return @() } }
function Test-GuardPlace([string]$path, [string]$except = '') {
    # Returns why $path can't be a protected folder, or $null if it can.
    # Nested protected folders would strip each other's rules, so they are refused.
    if (-not (Split-Path $path -Parent)) { return "a whole drive can't be protected. pick a folder on it" }
    foreach ($sys in @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData)) {
        if ($sys -and (($path -ieq $sys) -or $path.StartsWith($sys.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase))) { return "Windows and program folders can't be protected: $sys" }
    }
    foreach ($o in $script:Cfg.folders) {
        if ($except -and ($o.path -ieq $except)) { continue }
        $op = $o.path.TrimEnd('\') + '\'; $pp = $path.TrimEnd('\') + '\'
        if ($pp.StartsWith($op, [StringComparison]::OrdinalIgnoreCase)) { return "already protected as part of $($o.path)" }
        if ($op.StartsWith($pp, [StringComparison]::OrdinalIgnoreCase)) { return "this folder holds the protected folder $($o.path). remove that one first, then init here" }
    }
    return $null
}
function Test-AboveShared($f) {
    # true if another locked protected folder sits in the same folder above (it still needs that rule)
    $above = Split-Path $f.path -Parent
    foreach ($o in $script:Cfg.folders) {
        if ($o.path -eq $f.path -or $o.editing) { continue }
        if ((Split-Path $o.path -Parent) -eq $above) { return $true }
    }
    return $false
}
function Get-GuardItems([string]$Folder) {
    # files AND subfolders, for delete / move / list
    return Get-ChildItem -LiteralPath $Folder -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '_guard.json' }
}
function Find-Matches($f, [string]$name) {
    $items = Get-GuardItems $f.path
    if (-not $name) { return $items }
    return $items | Where-Object { $_.Name -like "*$name*" }
}
function Format-Item($x) {
    $size = '  folder'; if (-not $x.PSIsContainer) { $size = '{0,8:N0} B' -f $x.Length }
    $rel = $x.FullName.Substring((Cur).path.Length).TrimStart('\')
    return ("{0,-34} {1:yyyy-MM-dd HH:mm}  {2}" -f $rel, $x.LastWriteTime, $size)
}

function Unlock-GuardItem($x) {
    # file, or a subfolder with everything in it
    if ($x.PSIsContainer) {
        foreach ($c in (Get-ChildItem -LiteralPath $x.FullName -Recurse -Force -EA SilentlyContinue)) { Invoke-Icacls @($c.FullName, '/remove:d', $script:User) | Out-Null }
        Invoke-Icacls @($x.FullName, '/remove:d', $script:User) | Out-Null
    } else { Unlock-GuardFile -Path $x.FullName -User $script:User | Out-Null }
}
function Relock-GuardItem($f, [string]$path) {
    # after a failed delete/cut: lock whatever is still there, open files too
    if (-not (Test-Path -LiteralPath $path)) { return }
    $sk = @(Folder-Skip $f)
    if (Test-Path -LiteralPath $path -PathType Container) {
        Lock-GuardSubfolder -Path $path -User $script:User | Out-Null
        foreach ($c in (Get-ChildItem -LiteralPath $path -Recurse -Force -EA SilentlyContinue)) {
            if ($c.PSIsContainer) { Lock-GuardSubfolder -Path $c.FullName -User $script:User | Out-Null }
            else { Lock-GuardFile -Path $c.FullName -User $script:User -Skip $sk -Force | Out-Null }
        }
    } else { Lock-GuardFile -Path $path -User $script:User -Skip $sk -Force | Out-Null }
}
function Give-ToUser([string]$path) {
    # a copy or cut item outside guard is yours again: you own it, normal permissions
    if (-not (Test-Path -LiteralPath $path)) { return }
    Invoke-Icacls @($path, '/setowner', $script:User, '/T', '/C') | Out-Null
    Invoke-Icacls @($path, '/reset', '/T', '/C') | Out-Null
}
function Select-Menu([string[]]$Options, [int]$Default = 1) {
    # Numbered menu, '>' on the choice. Real console: ↑ ↓ or a digit moves it, Enter picks,
    # Esc cancels (0). Tests / piped input: one typed line, as before.
    $n = $Options.Count
    $nums = (1..$n) -join ' or '
    $live = $true
    try { if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { $live = $false } } catch { $live = $false }
    if (($script:InputQueue -and $script:InputQueue.Count) -or (Get-GuardTestEnv 'GUARD_ANSWERS')) { $live = $false }
    if (-not $live) {
        for ($i = 0; $i -lt $n; $i++) { $m = ' '; if ($i -eq $Default - 1) { $m = '>' }; Say ("  {0} {1}  {2}" -f $m, ($i+1), $Options[$i]) }
        $a = Read-Line ("  type {0} then Enter > " -f $nums)
        if ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $n) { return [int]$a }
        for ($i = 0; $i -lt $n; $i++) { if ($a -and ($Options[$i] -like "$a*")) { return $i + 1 } }
        return 0
    }
    $sel = $Default
    $hint = "  type {0} or ↑ ↓ then Enter > " -f $nums
    $width = 0; try { $width = [Console]::BufferWidth - 1 } catch { $width = 79 }
    $draw = {
        for ($i = 0; $i -lt $n; $i++) {
            $m = ' '; $c = 'Gray'; if ($i -eq $sel - 1) { $m = '>'; $c = 'Cyan' }
            Write-Host (("  {0} {1}  {2}" -f $m, ($i+1), $Options[$i]).PadRight($width)) -ForegroundColor $c
        }
        Write-Host -NoNewline (($hint + $sel).PadRight($width))
    }
    & $draw
    $top = [Console]::CursorTop - $n
    while ($true) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq 'Enter') { Write-Host ""; return $sel }
        if ($k.Key -eq 'Escape') { Write-Host ""; return 0 }
        if ($k.Key -eq 'UpArrow' -and $sel -gt 1) { $sel-- }
        elseif ($k.Key -eq 'DownArrow' -and $sel -lt $n) { $sel++ }
        elseif ($k.KeyChar -match '\d' -and [int]"$($k.KeyChar)" -ge 1 -and [int]"$($k.KeyChar)" -le $n) { $sel = [int]"$($k.KeyChar)" }
        else { continue }
        try { [Console]::SetCursorPosition(0, $top) } catch { }
        & $draw
    }
}

function Confirm-YesNo([string]$question, [string]$No = 'no') {
    Say ""; Say "  $question"
    return ((Select-Menu @('yes', $No)) -eq 1)
}

# ---- status block ---------------------------------------------------------
function Read-WatchStatus {
    # the background guard may be writing it right now: try a few times
    $file = Join-Path (Split-Path $script:GuardConfigPath -Parent) 'watch-status.json'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    for ($i = 0; $i -lt 5; $i++) {
        try { return (Get-Content -LiteralPath $file -Raw -ErrorAction Stop | ConvertFrom-Json) } catch { Start-Sleep -Milliseconds 100 }
    }
    return $null
}

function Wait-WatchSync {
    # After saving config: wait (max 20 s) until the background guard reports it acts on this
    # config, so it can't lock something we are about to unlock. No background guard: no wait.
    if ((Get-WatchState).Text -ne 'running') { return }
    $want = [string]$script:Cfg.saved
    for ($i = 0; $i -lt 80; $i++) {
        $s = Read-WatchStatus
        if ($s -and ([string]$s.config -eq $want)) { return }
        Start-Sleep -Milliseconds 250
    }
}

function Get-WatchState {
    # Reads the background guard's heartbeat. Returns @{ Text; Color; Detail }.
    $s = Read-WatchStatus
    if (-not $s -or -not $s.alive) { return @{ Text='NOT RUNNING'; Color='Red'; Detail='new files are not locked  ·  restart the PC or reinstall' } }
    $age = ((Get-Date) - [datetime]$s.alive).TotalSeconds
    if ($age -gt 120) { return @{ Text='NOT RUNNING'; Color='Red'; Detail=('last seen {0:yyyy-MM-dd HH:mm}  ·  restart the PC or reinstall' -f [datetime]$s.alive) } }
    $d = 'last full check —'
    if ($s.lastFull) { $d = 'last full check {0:HH:mm}' -f [datetime]$s.lastFull }
    return @{ Text='running'; Color='Gray'; Detail=$d }
}

function Show-Status {
    $line = ('-' * 86)
    $w = Get-WatchState
    Say $line
    if ($script:Cfg.folders.Count -eq 0) {
        Say "folder    none yet"
        Say ("guard     {0,-26} nothing to protect" -f $w.Text) $w.Color
        Say $line
        Say ""
        Show-NextLines
        return
    }
    for ($i = 0; $i -lt $script:Cfg.folders.Count; $i++) {
        $f = $script:Cfg.folders[$i]
        $mark = ''; if ($i -eq $script:Cfg.current) { $mark = '  ·  current' }
        $exists = Test-Path -LiteralPath $f.path
        $nf = ("{0} of {1}" -f ($i+1), $script:Cfg.folders.Count)
        Say ("folder    {0,-26} {1}{2}" -f $f.name, $nf, $mark)
        Say ("path      {0}" -f $f.path)
        if (-not $exists) {
            Say ("files     —")
            Say ("lock      —") 'Red'
            Say ("guard     {0,-26} folder NOT FOUND" -f $w.Text) 'Red'
        } else {
            $files = Get-GuardFiles -Folder $f.path
            $editing = $script:Editing[$f.path] -or $f.editing
            $lockState = 'LOCKED'; $lockColor = 'Green'
            if ($editing) { $lockState = 'UNLOCKED'; $lockColor = 'Red' }
            Say ("files     {0}" -f $files.Count)
            Say ("lock      {0,-26} owner SYSTEM  ·  folder + folder above + {1} files" -f $lockState, $files.Count) $lockColor
            Say ("guard     {0,-26} {1}" -f $w.Text, $w.Detail) $w.Color
        }
        if ($i -lt $script:Cfg.folders.Count - 1) { Say "" }
    }
    Say $line
    Say ""
    Show-NextLines
}

# ---- command table --------------------------------------------------------
function Show-Table {
    $g = @"
-------------------- Guard ---------------------

folders                   show all protected folders
use <n>                   switch to folder n
init                      protect the folder the terminal is in
init <path>               protect the folder at path
update                    install the newest guard
cls                       clear screen
help <command>            explain a command
help all                  explain every command
uninstall                 remove guard
exit                      close guard

------------ All protected folders -------------

edit all                  unlock every folder
resume all                lock every folder
remove all                stop protecting every folder
skip all <pattern>        add files that are never locked, in every folder

---------------- Current folder ----------------

list                      show files and folders
delete <name>             delete files or folders
delete all                delete everything in the folder
move <name>               copy or cut files or folders
move all                  copy or cut everything in the folder
move folder               move the protected folder somewhere else
edit                      unlock the folder
resume                    lock the folder
remove                    stop protecting the folder
skip                      show files that are never locked
skip <pattern>            add files that are never locked
skip remove <pattern>     take a pattern out
"@
    Say $g 'Gray'
    Say ""; Say ""
}

# ---- commands -------------------------------------------------------------
function Cmd-List($arg) {
    if ($arg -eq 'all') {
        foreach ($f in $script:Cfg.folders) {
            Say ""; Say ("  {0}   {1}" -f $f.name, $f.path) 'Cyan'
            Get-GuardFiles -Folder $f.path | Sort-Object LastWriteTime -Descending |
                ForEach-Object { Say ("   {0,-28} {1:yyyy-MM-dd HH:mm}  {2,8:N0} B" -f $_.Name, $_.LastWriteTime, $_.Length) }
        }
        Say ""; return
    }
    $f = Cur; if (-not $f) { Say "  no folder protected yet" 'Red'; return }
    $items = @(Get-GuardItems $f.path | Sort-Object LastWriteTime -Descending)
    $nd = @($items | Where-Object { $_.PSIsContainer }).Count
    Say ""; Say ("  {0} files, {1} folders, newest first" -f ($items.Count - $nd), $nd)
    $i = 1; foreach ($x in $items) { Say ("  {0,3}  {1}" -f $i, (Format-Item $x)); $i++ }
    Say ""
}

function Cmd-Delete($arg) {
    $f = Cur; if (-not $f) { Say "  no folder protected yet" 'Red'; return }
    if ($arg -eq 'all') {
        $files = Get-GuardFiles -Folder $f.path
        $sz = ($files | Measure-Object Length -Sum).Sum
        Say ""; Say ("  This empties the folder: {0} files, {1:N0} B." -f $files.Count, $sz)
        $a = Read-Line "  type YES to continue, anything else to cancel > "
        if ($a -ne 'YES') { Say "  cancelled"; return }
        # top level only: a subfolder goes with everything in it
        $top = @(Get-ChildItem -LiteralPath $f.path -Force -EA SilentlyContinue | Where-Object { $_.Name -ne '_guard.json' })
        $n = 0
        foreach ($x in $top) { if (Remove-GuardedFile $f $x) { $n++ } }
        Ok "deleted" ("{0} of {1} items  ·  folder kept, still protected" -f $n, $top.Count); return
    }
    # (not $matches: that is PowerShell's automatic variable, and -match below would overwrite it)
    $hits = @(Find-Matches $f $arg)
    if ($hits.Count -eq 0) { Say "  no file matches `"$arg`"  ·  type  list  to see names"; return }
    $chosen = @()
    if ($hits.Count -eq 1) { $chosen = $hits }
    else {
        Say ""; Say "  Which files?"
        $i = 1; foreach ($m in $hits) { Say ("  {0,3}  {1}" -f $i, (Format-Item $m)); $i++ }
        $a = Read-Line "  type numbers (e.g. 1 3), all, or n > "
        if ($a -eq 'all') { $chosen = $hits }
        elseif ($a -match '^(n|no)?$') { Say "  cancelled"; return }
        else { foreach ($n in ($a -split '\s+')) { if ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $hits.Count) { $chosen += $hits[[int]$n-1] } } }
    }
    if ($chosen.Count -eq 0) { Say "  nothing chosen"; return }
    $what = "{0} item(s)" -f $chosen.Count
    $nf = @($chosen | Where-Object { $_.PSIsContainer }).Count
    if ($nf) { $what += (" ({0} folder(s), with everything inside)" -f $nf) }
    if (-not (Confirm-YesNo ("Delete {0}?" -f $what))) { Say "  cancelled"; return }
    foreach ($x in $chosen) {
        if (-not (Test-Path -LiteralPath $x.FullName)) { continue }   # was inside a folder deleted just before
        if (Remove-GuardedFile $f $x) { Ok "deleted" $x.Name }
    }
}

function Remove-GuardedFile($f, $x) {
    # Unlock, delete (a folder with all it holds). If it fails (open in Word, path too long...),
    # lock whatever is left again and say so.
    Unlock-GuardItem $x
    try {
        if ($x.PSIsContainer) { Remove-Item -LiteralPath $x.FullName -Recurse -Force -ErrorAction Stop }
        else { Remove-Item -LiteralPath $x.FullName -Force -ErrorAction Stop }
        return $true
    } catch {
        Relock-GuardItem $f $x.FullName
        Say ("  FAIL  {0}  not deleted, still protected  ·  {1}" -f $x.Name, $_.Exception.Message) 'Red'
        return $false
    }
}

function Cmd-Move($arg) {
    $f = Cur; if (-not $f) { Say "  no folder protected yet" 'Red'; return }
    if ($arg -eq 'folder') {
        $dest = Read-Line "  Where to? type a folder path then Enter > "
        if (-not $dest) { Say "  cancelled"; return }
        # an existing folder = move inside it, keeping the name
        if (Test-Path -LiteralPath $dest -PathType Container) { $dest = Join-Path $dest (Get-FolderName $f.path) }
        if (Test-Path -LiteralPath $dest) { Say "  already exists: $dest" 'Red'; return }
        $bad = Test-GuardPlace $dest $f.path
        if ($bad) { Say "  $bad" 'Red'; return }
        $old = $f.path
        $f | Add-Member -NotePropertyName editing -NotePropertyValue $true -Force
        Save-GuardConfig -Config $script:Cfg -User $script:User      # background guard: hands off
        Wait-WatchSync
        Unlock-GuardTree -Folder $old -User $script:User -KeepAbove:(Test-AboveShared $f) | Out-Null
        try { Move-Item -LiteralPath $old -Destination $dest -ErrorAction Stop }
        catch {
            Say "  move failed: $($_.Exception.Message)" 'Red'
            Lock-GuardTree -Folder $old -User $script:User -Skip (Folder-Skip $f) | Out-Null
            $f.editing = $false; Save-GuardConfig -Config $script:Cfg -User $script:User
            return
        }
        $f.path = $dest; $f.name = Get-FolderName $dest; $f.editing = $false
        Set-GuardOwnerSystem -Folder $dest -User $script:User | Out-Null   # other drive = new files, new owner
        $r = Lock-GuardTree -Folder $dest -User $script:User -Skip (Folder-Skip $f)
        Save-GuardConfig -Config $script:Cfg -User $script:User
        Ok "moved" ("{0}  ·  {1} files locked" -f $dest, $r.Locked)
        Ok "memory" "_guard.json updated  ·  new path saved"
        return
    }
    $files = @(Find-Matches $f $arg)
    if ($arg -eq 'all') {
        # top level only: subfolders keep their shape at the destination
        $files = @(Get-ChildItem -LiteralPath $f.path -Force -EA SilentlyContinue | Where-Object { $_.Name -ne '_guard.json' })
        Say ""; Say ("  This copies or cuts everything in the folder: {0} items." -f $files.Count)
        $a = Read-Line "  type YES to continue, anything else to cancel > "
        if ($a -ne 'YES') { Say "  cancelled"; return }
    }
    if ($files.Count -eq 0) { Say "  no file matches `"$arg`""; return }
    $dest = Read-Line "  Where to? type a folder path then Enter > "
    if (-not $dest) { Say "  cancelled"; return }
    if (-not (Test-Path -LiteralPath $dest)) {
        if (Confirm-YesNo "$dest does not exist. Create it?") { New-Item -ItemType Directory -Path $dest -Force | Out-Null } else { Say "  cancelled"; return }
    }
    $dp = (Resolve-Path -LiteralPath $dest).ProviderPath
    if ($dp.TrimEnd('\') -ieq $f.path.TrimEnd('\') -or $dp.StartsWith($f.path.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { Say "  pick a folder outside $($f.name)" 'Red'; return }
    Say ""; Say "  Cut or copy?"
    $cc = Select-Menu @('cut', 'copy')
    if ($cc -eq 0) { Say "  cancelled"; return }
    $cut = ($cc -eq 1)
    foreach ($x in $files) {
        if (-not (Test-Path -LiteralPath $x.FullName)) { continue }   # inside a folder moved just before
        $target = Join-Path $dp $x.Name
        if ($cut) {
            Unlock-GuardItem $x
            try { Move-Item -LiteralPath $x.FullName -Destination $dp -Force -ErrorAction Stop; Give-ToUser $target; Ok "moved" $x.Name }
            catch {
                # still here (or partly): lock what is left, say so
                Relock-GuardItem $f $x.FullName
                Say ("  FAIL  {0}  not moved, still protected  ·  {1}" -f $x.Name, $_.Exception.Message) 'Red'
            }
        } else {
            try {
                if ($x.PSIsContainer) { Copy-Item -LiteralPath $x.FullName -Destination $dp -Recurse -Force -ErrorAction Stop }
                else { Copy-Item -LiteralPath $x.FullName -Destination $dp -Force -ErrorAction Stop }
                Give-ToUser $target; Ok "copied" $x.Name
            }
            catch { Say ("  FAIL  {0}  not copied  ·  {1}" -f $x.Name, $_.Exception.Message) 'Red' }
        }
    }
}

function Cmd-Edit($arg) {
    $targets = @()
    if ($arg -eq 'all') { $targets = $script:Cfg.folders } else { $c = Cur; if ($c) { $targets = @($c) } }
    if ($targets.Count -eq 0) { Say "  no folder protected yet" 'Red'; return }
    # tell the background guard first, and wait until it has seen it, then unlock
    foreach ($f in $targets) {
        $f | Add-Member -NotePropertyName editing -NotePropertyValue $true -Force
        $f | Add-Member -NotePropertyName editingSince -NotePropertyValue ((Get-Date).ToString('o')) -Force
    }
    Save-GuardConfig -Config $script:Cfg -User $script:User
    Wait-WatchSync
    foreach ($f in $targets) {
        Unlock-GuardTree -Folder $f.path -User $script:User -KeepAbove:(Test-AboveShared $f) | Out-Null
        $script:Editing[$f.path] = $true
        Ok "unlocked" $f.name
    }
    Say "  edit, save, rename, delete freely. locks again at next logon, or type  resume"
}

function Cmd-Resume($arg) {
    $targets = @()
    if ($arg -eq 'all') { $targets = $script:Cfg.folders } else { $c = Cur; if ($c) { $targets = @($c) } }
    foreach ($f in $targets) {
        $r = Lock-GuardTree -Folder $f.path -User $script:User -Skip (Folder-Skip $f)
        $script:Editing.Remove($f.path)
        $f | Add-Member -NotePropertyName editing -NotePropertyValue $false -Force
        Ok "locked" ("{0}  ·  {1} files" -f $f.name, $r.Locked)
    }
    if ($targets.Count) { Save-GuardConfig -Config $script:Cfg -User $script:User }
    if ((Get-WatchState).Text -ne 'running') {
        $how = Start-GuardWatch -Dir $script:InstallDir -User $script:User
        if ($how) { Ok "started" "background guard" }
    }
}

function Cmd-Init($arg) {
    $path = $arg
    if (-not $path) { $path = (Get-Location).Path }
    $path = (Resolve-Path -LiteralPath $path -ErrorAction SilentlyContinue).Path
    if (-not $path) { Say "  not found: $arg" 'Red'; return }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { Say "  not a folder: $path" 'Red'; return }
    foreach ($f in $script:Cfg.folders) { if ($f.path -eq $path) { Say "  already protected  ·  type  use"; return } }
    $bad = Test-GuardPlace $path
    if ($bad) { Say "  $bad" 'Red'; return }
    # a folder that carries guard memory from an earlier install: offer to restore its whole list
    $mem = Read-GuardJson -Path (Join-Path $path '_guard.json')
    if ($mem -and $mem.folders -and @($mem.folders).Count -gt 0) {
        $known = @($script:Cfg.folders | ForEach-Object { $_.path })
        $new = @($mem.folders | Where-Object { $known -notcontains $_.path })
        if ($new.Count -gt 0) {
            $done = Invoke-GuardRestore -Memory $mem -Where $path
            if ($done) { return }
        }
    }
    $files = @(Get-GuardFiles -Folder $path)
    $sz = ($files | Measure-Object Length -Sum).Sum
    Say ""; Say ("  {0}  ·  {1}  ·  {2} files  ·  {3:N0} B" -f (Get-FolderName $path), $path, $files.Count, $sz)
    Say ""
    Set-GuardOwnerSystem -Folder $path -User $script:User | Out-Null
    $r = Lock-GuardTree -Folder $path -User $script:User -Skip @()
    Ok "owner" ("folder + {0} files" -f $files.Count)
    Ok "locking" "folder + folder above"
    Ok "locking" ("{0} files" -f $r.Locked)
    $entry = [pscustomobject]@{ path=$path; name=(Get-FolderName $path); skip=@(); added=(Get-Date).ToString('o') }
    $script:Cfg.folders += $entry
    $script:Cfg.current = $script:Cfg.folders.Count - 1
    Save-GuardConfig -Config $script:Cfg -User $script:User
    Ok "memory" "_guard.json written and locked"
    if ($r.Waiting.Count -gt 0) {
        Say ""; Say "  not locked yet"
        foreach ($w in $r.Waiting) { Say ("    {0}   {1}" -f $w.Reason, $w.Name) }
    }
    Say ""; Say ("  {0} folder is successfully protected" -f (Get-FolderName $path)) 'Green'
    Say ("  path        {0}" -f $path)
    Say ("  locked      {0} of {1} files" -f $r.Locked, $files.Count)
}

function Cmd-Remove($arg) {
    $targets = @()
    if ($arg -eq 'all') { $targets = @($script:Cfg.folders) } else { $c = Cur; if ($c) { $targets = @($c) } }
    if ($targets.Count -eq 0) { Say "  no folder to remove"; return }
    if ($arg -eq 'all') {
        Say ""; Say ("  This stops protecting {0} folders. Nothing is deleted." -f $targets.Count)
        $a = Read-Line "  type YES to continue, anything else to cancel > "
        if ($a -ne 'YES') { Say "  cancelled"; return }
    }
    # forget first, so the background guard doesn't lock it again while we unlock
    $keep = @(); foreach ($f in $script:Cfg.folders) { if ($targets -notcontains $f) { $keep += $f } }
    $script:Cfg.folders = $keep
    if ($script:Cfg.current -ge $script:Cfg.folders.Count) { $script:Cfg.current = [Math]::Max(0, $script:Cfg.folders.Count - 1) }
    Save-GuardConfig -Config $script:Cfg -User $script:User
    Wait-WatchSync
    foreach ($f in $targets) {
        if (-not (Test-Path -LiteralPath $f.path)) { Ok "forgot" $f.name; continue }
        Unlock-GuardTree -Folder $f.path -User $script:User -KeepAbove:(Test-AboveShared $f) | Out-Null
        $jp = Join-Path $f.path '_guard.json'
        Unlock-GuardFile -Path $jp -User $script:User | Out-Null
        Remove-Item -LiteralPath $jp -Force -EA SilentlyContinue
        Set-GuardOwnerUser -Folder $f.path -User $script:User | Out-Null
        Ok "unlocked" $f.name
    }
    Ok "removed" "from guard"
}

function Cmd-Skip($arg) {
    $f = Cur; if (-not $f) { Say "  no folder protected yet" 'Red'; return }
    if (-not $arg) {
        Say ""; Say ("  skip list for {0}" -f $f.name)
        Say ("    built-in   " + ($script:BuiltinSkip -join '  '))
        $yours = @(Folder-Skip $f); if ($yours.Count -eq 0) { $yours = @('—') }
        Say ("    yours      " + ($yours -join '  ')); Say ""
        return
    }
    $parts = $arg -split '\s+', 2
    if ($parts[0] -eq 'remove' -and $parts.Count -eq 2) {
        $f.skip = @(Folder-Skip $f | Where-Object { $_ -ne $parts[1] })
        Save-GuardConfig -Config $script:Cfg -User $script:User
        Ok "removed" $parts[1]; return
    }
    if ($parts[0] -eq 'all' -and $parts.Count -eq 2) {
        foreach ($x in $script:Cfg.folders) {
            $x.skip = @(@(Folder-Skip $x) + @($parts[1]) | Select-Object -Unique)
            if (Test-Path -LiteralPath $x.path) { foreach ($y in (Get-GuardFiles -Folder $x.path)) { if ($y.Name -like $parts[1]) { Unlock-GuardFile -Path $y.FullName -User $script:User | Out-Null } } }
        }
        Save-GuardConfig -Config $script:Cfg -User $script:User
        Ok "added" ("{0} to all folders" -f $parts[1]); return
    }
    $f.skip = @(@(Folder-Skip $f) + @($arg) | Select-Object -Unique)
    # unlock anything already locked that now matches
    foreach ($x in (Get-GuardFiles -Folder $f.path)) { if ($x.Name -like $arg) { Unlock-GuardFile -Path $x.FullName -User $script:User | Out-Null } }
    Save-GuardConfig -Config $script:Cfg -User $script:User
    Ok "added" ("{0} to {1}" -f $arg, $f.name)
}

function Cmd-Folders {
    Say ""
    for ($i = 0; $i -lt $script:Cfg.folders.Count; $i++) {
        $f = $script:Cfg.folders[$i]; $star = ' '; if ($i -eq $script:Cfg.current) { $star = '*' }
        $state = 'LOCKED'; if (-not (Test-Path -LiteralPath $f.path)) { $state = 'NOT FOUND' }
        Say (" {0} {1}  {2,-14} {3,-45} {4}" -f $star, ($i+1), $f.name, $f.path, $state)
    }
    Say ""
}

function Cmd-Use($arg) {
    if ($arg -match '^\d+$') {
        $n = [int]$arg
        if ($n -ge 1 -and $n -le $script:Cfg.folders.Count) { $script:Cfg.current = $n - 1; Save-GuardConfig -Config $script:Cfg -User $script:User; Say "  switched" }
        else { Say "  no folder $n" 'Red' }
    } else { Say "  use <number>" 'Red' }
}

# ---- restore (memory from an earlier install) ------------------------------
function Invoke-GuardRestore {
    # Shows the folders an old _guard.json lists, asks once, then protects the ones that exist.
    # Returns $true if restored, $false if the user chose to start fresh.
    param($Memory, [string]$Where)
    $list = @($Memory.folders)
    Say ""; Say ("  guard memory found in {0}. it lists {1} protected folders:" -f $Where, $list.Count)
    $i = 1
    foreach ($f in $list) {
        if (Test-Path -LiteralPath $f.path -PathType Container) {
            $n = @(Get-GuardFiles -Folder $f.path).Count
            Say ("    {0}  {1,-44} found      {2} files" -f $i, $f.path, $n)
        } else { Say ("    {0}  {1,-44} not found" -f $i, $f.path) 'Red' }
        $i++
    }
    $found = @($list | Where-Object { Test-Path -LiteralPath $_.path -PathType Container })
    if ($found.Count -eq 0) { Say "  none of them exist on this PC"; return $false }
    if (-not (Confirm-YesNo ("Restore protection for the {0} found folders?" -f $found.Count) 'no, start fresh')) { Say "  starting fresh"; return $false }

    $files = 0; $locked = 0
    foreach ($f in $found) {
        # access first: on a new Windows the old account is a stranger, even with the same name
        Set-GuardOwnerSystem -Folder $f.path -User $script:User | Out-Null
        $r = Lock-GuardTree -Folder $f.path -User $script:User -Skip (Folder-Skip $f)
        $files += @(Get-GuardFiles -Folder $f.path).Count; $locked += $r.Locked
    }
    Ok "access" ("your account given access to {0} folder(s)" -f $found.Count)
    Ok "owner" ("folders + {0} files now owned by SYSTEM" -f $files)
    Ok "locking" ("folders, folders above, {0} files" -f $locked)

    # merge: keep what we already protect, add the remembered ones
    $known = @($script:Cfg.folders | ForEach-Object { $_.path })
    foreach ($f in $list) {
        if ($known -contains $f.path) { continue }
        $f | Add-Member -NotePropertyName editing -NotePropertyValue $false -Force
        if (-not $f.skip) { $f | Add-Member -NotePropertyName skip -NotePropertyValue @() -Force }
        $script:Cfg.folders += $f
    }
    Save-GuardConfig -Config $script:Cfg -User $script:User
    $missing = $list.Count - $found.Count
    $m = "_guard.json updated in {0}" -f $found.Count
    if ($missing) { $m += ("  ·  {0} missing kept in the list" -f $missing) }
    Ok "memory" $m
    Say ""; Say ("  {0} folders are successfully protected" -f $found.Count) 'Green'
    return $true
}

# ---- help -----------------------------------------------------------------
$script:HelpShort = [ordered]@{
    'folders'='list protected folders with their numbers · * marks the current one'
    'use'='make folder number n the current one · numbers come from folders'
    'init'='protect the folder the terminal is in, or the one at path · locks folder, folder above, every file'
    'update'='install the newest guard from GitHub · protected folders untouched'
    'cls'="clear the screen and show the command table and every folder's status again"
    'help'='help <command> explains one command · help all explains every command'
    'uninstall'='remove guard from this PC · unlocks everything, removes the background guard · files stay on the disk'
    'exit'='close the guard window · protection keeps running in the background'
    'list'='show files in the current folder, newest first, with date and size · list all = every folder'
    'delete'='delete files or folders · matches by part of the name · picker if many · always asks first · delete all = type YES'
    'move'='copy or cut files or folders · asks where to, then cut or copy · move folder = move the protected folder itself'
    'edit'='unlock the folder · save, rename, delete work · locks again at next logon or with resume · edit all = every folder'
    'resume'='lock the folder again now · also happens by itself at every logon · resume all = every folder'
    'remove'='stop protecting the folder · files stay on the disk · remove all = every folder, type YES'
    'skip'='show, add (skip *.bak) or take out (skip remove *.bak) files that are never locked · skip all <pattern> = every folder'
}
$script:HelpLong = @{
    'edit'=@'
Removes the lock from the folder, the folder above and every file. Save from
Word, Excel, Photoshop, rename, delete, all work. The background guard stops
locking new files there. Type  resume  to lock again. If you forget, the next
logon locks everything by itself. While unlocked, AI agents can delete in that
folder too.
'@
    'resume'=@'
Locks the folder, the folder above and every file again right now, and the
background guard goes back to locking every new file the moment it is saved.
resume all does it for every protected folder.
'@
    'init'=@'
Protects a folder: SYSTEM becomes the owner, the folder can't be deleted or
renamed, the folder above can't delete it, and every file inside can't be
deleted. New files are locked as soon as they finish saving. No question is
asked. If the folder holds guard memory from an earlier install, guard offers
to protect every folder that memory lists.
'@
    'delete'=@'
The only way to delete inside a protected folder without unlocking it.
delete amazon  finds every file and folder with "amazon" in its name. One
match: asks yes or no. Many: shows a numbered list, type the numbers. A folder
goes with everything in it. delete all  empties the folder (the folder itself
stays protected) and needs  YES  typed. Nothing goes to the
Recycle Bin. If something can't be deleted (open in another program), guard
says FAIL and it stays protected.
'@
    'move'=@'
move <name>  picks files or folders the same way as delete, asks for a
destination outside the protected folder, then cut or copy. What arrives there
is a normal item you own; with copy, the original stays protected here.
move folder  moves the protected folder itself to a new path and keeps it
protected there.
'@
    'remove'=@'
Stops protecting the current folder. The lock comes off, you become the owner
again, normal permissions come back, and its _guard.json is deleted. Files are
not touched. remove all does every folder and needs  YES.
'@
    'skip'=@'
Files matching a skip pattern are never locked and can always be deleted.
Built in: temp files, Office lock files (~$*), Chrome downloads in progress.
skip *.bak  adds one. skip remove *.bak  takes it out. skip all *.bak  adds it
to every protected folder.
'@
    'update'=@'
Checks GitHub for a newer guard. If there is one, installs it in place: the
program files and the background guard are replaced, protected folders and
their locks are not touched. guard closes after the update; type  guard  again.
'@
    'uninstall'=@'
Removes guard from this PC after you type  YES. Every folder is unlocked and
given back to you, the background guard and its task are removed, the guard
program folder is deleted. The hidden _guard.json in each folder stays: it is
the memory, so a future install can restore everything. Files are never deleted.
'@
}
function Show-Help([string]$what) {
    $what = $what.Trim().ToLower()
    if (-not $what) { Show-Table; return }
    if ($what -eq 'all') {
        foreach ($k in $script:HelpShort.Keys) {
            Say ""; Say ("  {0}" -f $k) 'Cyan'
            if ($script:HelpLong[$k]) { foreach ($l in ($script:HelpLong[$k] -split "`r?`n")) { Say "  $l" } }
            else { Say ("  {0}" -f $script:HelpShort[$k]) }
        }
        Say ""; return
    }
    $k = ($what -split '\s+')[0]
    if (-not $script:HelpShort.Contains($k)) {
        $s = Get-Suggestion $k; $tail = ''; if ($s) { $tail = "  ·  did you mean  $s ?" }
        Say ("  no command `"{0}`"{1}" -f $k, $tail) 'Red'; return
    }
    Say ""; Say ("  {0}" -f $k) 'Cyan'
    if ($script:HelpLong[$k]) { foreach ($l in ($script:HelpLong[$k] -split "`r?`n")) { Say "  $l" } }
    else { Say ("  {0}" -f $script:HelpShort[$k]) }
    Say ""
}

function Get-Distance([string]$a, [string]$b) {
    $d = New-Object 'int[,]' ($a.Length+1), ($b.Length+1)
    for ($i=0; $i -le $a.Length; $i++) { $d.SetValue($i, $i, 0) }
    for ($j=0; $j -le $b.Length; $j++) { $d.SetValue($j, 0, $j) }
    for ($i=1; $i -le $a.Length; $i++) { for ($j=1; $j -le $b.Length; $j++) {
        $c = 1; if ($a[$i-1] -eq $b[$j-1]) { $c = 0 }
        $up = $d.GetValue($i-1, $j) + 1
        $left = $d.GetValue($i, $j-1) + 1
        $diag = $d.GetValue($i-1, $j-1) + $c
        $d.SetValue([Math]::Min([Math]::Min($up, $left), $diag), $i, $j)
    } }
    return $d.GetValue($a.Length, $b.Length)
}
function Get-Suggestion([string]$word) {
    $best = $null; $bd = 99
    foreach ($k in $script:HelpShort.Keys) { $x = Get-Distance $word $k; if ($x -lt $bd) { $bd = $x; $best = $k } }
    if ($bd -le 2) { return $best }; return $null
}

# ---- error report -----------------------------------------------------------
function New-GuardIssueUrl([string]$Command, [string]$Message, [string]$Where) {
    # A pre-filled GitHub issue. Opens in the browser; nothing is sent until the user submits it.
    $os = [Environment]::OSVersion.Version
    $body = @"
**What I typed**
``$Command``

**What guard said**
``````
$Message
$Where
``````

guard $($script:GuardVersion) · PowerShell $($PSVersionTable.PSVersion) · Windows build $($os.Build)
"@
    $title = "guard error: " + ($Message -split "`n")[0]
    if ($title.Length -gt 120) { $title = $title.Substring(0, 120) }
    return ('https://github.com/ShashwatGold1/Folder_Safety_Guard/issues/new?title={0}&body={1}' -f [uri]::EscapeDataString($title), [uri]::EscapeDataString($body))
}

function Open-GuardIssue([string]$Url) {
    # explorer.exe hands the link to the user's normal (not admin) browser
    if (Get-GuardTestEnv 'GUARD_NOBROWSER') { return $false }
    try { Start-Process explorer.exe -ArgumentList "`"$Url`""; return $true } catch { return $false }
}

# ---- update / uninstall ---------------------------------------------------
$script:InstallDir = $PSScriptRoot

function Cmd-Update {
    $v = Get-GuardRemoteVersion
    if (-not $v) { Say "  can't reach GitHub right now. try again later." 'Red'; return $true }
    if (-not (Test-GuardNewer $v)) { Say ("  you have the newest version ({0})" -f $script:GuardVersion); return $true }
    $tmp = Join-Path $env:TEMP ('guard-install-' + [guid]::NewGuid().ToString('N') + '.ps1')
    try {
        $text = Get-GuardSourceText 'install.ps1'
        [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding($true)))
    } catch { Say "  download failed: $($_.Exception.Message)" 'Red'; return $true }
    & $tmp -Prefix $script:InstallDir -NoElevate -Update -From $script:GuardVersion -To $v -ForUser $script:User
    Remove-Item $tmp -Force -EA SilentlyContinue
    return $false    # the program files changed under us: close, user types guard again
}

function Cmd-Uninstall {
    $folders = @($script:Cfg.folders)
    $n = 0; foreach ($f in $folders) { if (Test-Path -LiteralPath $f.path) { $n += @(Get-GuardFiles -Folder $f.path).Count } }
    Say ""; Say ("  This removes guard from this PC. Protected folders: {0}, files: {1}. Nothing is deleted." -f $folders.Count, $n)
    $a = Read-Line "  type YES to continue, anything else to cancel > "
    if ($a -ne 'YES') { Say "  cancelled"; return $true }
    Say ""
    # 1 stop the background guard first, so nothing locks again behind us
    Stop-GuardWatch -Dir $script:InstallDir | Out-Null
    # 2 give every folder back
    foreach ($f in $folders) {
        if (-not (Test-Path -LiteralPath $f.path)) { Ok "skipped" ("{0}  (not found)" -f $f.path); continue }
        $c = @(Get-GuardFiles -Folder $f.path).Count
        Unlock-GuardTree -Folder $f.path -User $script:User | Out-Null
        Unlock-GuardFile -Path (Join-Path $f.path '_guard.json') -User $script:User | Out-Null
        Set-GuardOwnerUser -Folder $f.path -User $script:User | Out-Null
        Ok "unlocked" ("{0}  ({1} files)  owner back to you" -f $f.path, $c)
    }
    if ($folders.Count) { Ok "kept" "_guard.json in every folder (memory, so a future install can restore)" }
    # 3 task, path, program, data
    try { Unregister-ScheduledTask -TaskName $script:GuardTask -Confirm:$false -ErrorAction Stop; Ok "removed" ("task `"{0}`"" -f $script:GuardTask) } catch { Ok "removed" "task (was not there)" }
    try {
        # raw registry value: keeps %SystemRoot% etc. as they are (REG_EXPAND_SZ)
        if (Remove-GuardMachinePath $script:InstallDir) { Ok "removed" "path entry" } else { Ok "removed" "path entry (was not there)" }
    } catch { Say "  FAIL  path: $($_.Exception.Message)" 'Red' }
    # only delete a real install folder (has guard.cmd), never a source checkout
    if (Test-Path -LiteralPath (Join-Path $script:InstallDir 'guard.cmd')) {
        # guard.cmd is still running (it started us): remove the folder
        # 2 s after guard closes, or Windows prints
        # "The system cannot find the path specified."
        $dir = $script:InstallDir.TrimEnd('\')
        Start-Process cmd.exe -WindowStyle Hidden -ArgumentList "/c ping -n 3 127.0.0.1 >nul & rd /s /q `"$dir`""
        Ok "removed" $dir
    }
    $data = Split-Path $script:GuardConfigPath -Parent
    Remove-Item -LiteralPath $data -Recurse -Force -EA SilentlyContinue
    Ok "removed" $data
    Say "  done. bye."
    return $false
}

# ---- lines under the status block -----------------------------------------
function Show-NextLines {
    $w = Get-WatchState
    $s = Read-WatchStatus
    $printed = $false
    if ($s -and (Test-GuardNewer $s.latest)) {
        Say "update    New version is available. Type  update  to keep guard up to date." 'Yellow'; $printed = $true
    }
    $next = $null
    if ($script:Cfg.folders.Count -eq 0) { $next = 'init   (this folder)   /   init <path>' }
    else {
        for ($i = 0; $i -lt $script:Cfg.folders.Count; $i++) {
            $f = $script:Cfg.folders[$i]
            $isCur = ($i -eq $script:Cfg.current)
            if (-not (Test-Path -LiteralPath $f.path)) {
                if ($isCur) { $next = 'remove  to forget it  /  init <new path>' } else { $next = "type  use $($i+1)  then  remove  to forget it, or  init <new path>" }
                break
            }
        }
        if (-not $next -and $w.Text -ne 'running') { $next = 'resume   (locks everything and restarts the background guard)' }
    }
    if ($next) { Say ("next      {0}" -f $next) 'Yellow'; $printed = $true }
    if ($printed) { Say "" }
}

# ---- dispatcher -----------------------------------------------------------
function Invoke-GuardCommand([string]$raw) {
    $raw = $raw.Trim()
    if (-not $raw) { return $true }
    $sp = $raw -split '\s+', 2
    $cmd = $sp[0].ToLower(); $arg = ''; if ($sp.Count -gt 1) { $arg = $sp[1] }
    switch ($cmd) {
        'list'    { Cmd-List $arg }
        'delete'  { Cmd-Delete $arg }
        'move'    { Cmd-Move $arg }
        'edit'    { Cmd-Edit $arg }
        'resume'  { Cmd-Resume $arg }
        'init'    { Cmd-Init $arg }
        'remove'  { Cmd-Remove $arg }
        'skip'    { Cmd-Skip $arg }
        'folders' { Cmd-Folders }
        'use'     { Cmd-Use $arg }
        'cls'       { Clear-Host; Show-Table }
        'help'      { Show-Help $arg }
        'update'    { return (Cmd-Update) }
        'uninstall' { return (Cmd-Uninstall) }
        'exit'      { return $false }
        default     {
            $s = Get-Suggestion $cmd; $tail = ''; if ($s) { $tail = "  ·  did you mean  $s ?" }
            Say ("  unknown command `"{0}`"{1}" -f $cmd, $tail) 'Red'
        }
    }
    return $true
}
