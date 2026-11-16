# guard-shell.ps1 — the interactive program. Command handlers are separate functions so they
# can be driven by tests. Input goes through $script:InputProvider (a queue in tests, Read-Host live).

. "$PSScriptRoot\guard-core.ps1"
. "$PSScriptRoot\guard-config.ps1"

$script:Cfg  = $null
$script:User = $null
$script:Editing = @{}   # path -> $true while a folder is in 'edit' (unlocked) state

# ---- input / output -------------------------------------------------------
function Read-Line([string]$Prompt) {
    if ($script:InputQueue -and $script:InputQueue.Count -gt 0) {
        $v = $script:InputQueue.Dequeue()
        Write-Host ($Prompt + $v) -ForegroundColor DarkGray
        return $v
    }
    return Read-Host -Prompt $Prompt
}
function Say([string]$t, [string]$c = 'Gray') { Write-Host $t -ForegroundColor $c }
function Ok([string]$label, [string]$detail) { Write-Host ("  {0,-9} {1,-40} ok" -f $label, $detail) -ForegroundColor Green }

# ---- helpers --------------------------------------------------------------
function Cur { if ($script:Cfg.folders.Count -eq 0) { return $null }; return $script:Cfg.folders[$script:Cfg.current] }
function Folder-Skip($f) { if ($f.skip) { return @($f.skip) } else { return @() } }
function Find-Matches($f, [string]$name) {
    $files = Get-GuardFiles -Folder $f.path
    if (-not $name) { return $files }
    return $files | Where-Object { $_.Name -like "*$name*" }
}
function Confirm-YesNo([string]$question) {
    Say ""; Say "  $question"
    Say "  > 1  yes"
    Say "    2  no"
    $a = Read-Line "  type 1 or 2 then Enter > "
    return ($a -eq '1' -or $a -match '^(y|yes)$')
}

# ---- status block ---------------------------------------------------------
function Show-Status {
    $line = ('-' * 86)
    Say $line
    if ($script:Cfg.folders.Count -eq 0) {
        Say "folder    none yet"
        Say "guard     running                    nothing to protect"
        Say $line
        Say ""
        Say "next      init   (this folder)   /   init <path>" 'Yellow'
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
            Say ("guard     running                    folder NOT FOUND") 'Red'
        } else {
            $files = Get-GuardFiles -Folder $f.path
            $editing = $script:Editing[$f.path]
            $lockState = 'LOCKED'; $lockColor = 'Green'
            if ($editing) { $lockState = 'UNLOCKED'; $lockColor = 'Red' }
            Say ("files     {0}" -f $files.Count)
            Say ("lock      {0,-26} owner SYSTEM  ·  folder + folder above + {1} files" -f $lockState, $files.Count) $lockColor
            Say ("guard     running                    last full check (live)")
        }
        if ($i -lt $script:Cfg.folders.Count - 1) { Say "" }
    }
    Say $line
    Say ""
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
    $files = Get-GuardFiles -Folder $f.path | Sort-Object LastWriteTime -Descending
    Say ""; Say ("  {0} files, newest first" -f $files.Count)
    $i = 1; foreach ($x in $files) { Say ("  {0,3}  {1,-28} {2:yyyy-MM-dd HH:mm}  {3,8:N0} B" -f $i, $x.Name, $x.LastWriteTime, $x.Length); $i++ }
    Say ""
}

function Cmd-Delete($arg) {
    $f = Cur; if (-not $f) { Say "  no folder protected yet" 'Red'; return }
    if ($arg -eq 'all') {
        $files = Get-GuardFiles -Folder $f.path
        $sz = ($files | Measure-Object Length -Sum).Sum
        Say ""; Say ("  This empties the folder: {0} files, {1:N0} B." -f $files.Count, $sz)
        $a = Read-Line "  type YES to continue, anything else to cancel > "
        if ($a -cne 'YES') { Say "  cancelled"; return }
        foreach ($x in $files) { Unlock-GuardFile -Path $x.FullName -User $script:User | Out-Null; Remove-Item -LiteralPath $x.FullName -Force -EA SilentlyContinue }
        Ok "deleted" ("{0} files" -f $files.Count); return
    }
    $matches = @(Find-Matches $f $arg)
    if ($matches.Count -eq 0) { Say "  no file matches `"$arg`"  ·  type  list  to see names"; return }
    $chosen = @()
    if ($matches.Count -eq 1) { $chosen = $matches }
    else {
        Say ""; Say "  Which files?"
        $i = 1; foreach ($m in $matches) { Say ("  {0,3}  {1,-28} {2:yyyy-MM-dd HH:mm}" -f $i, $m.Name, $m.LastWriteTime); $i++ }
        $a = Read-Line "  type numbers (e.g. 1 3), all, or n > "
        if ($a -eq 'all') { $chosen = $matches }
        elseif ($a -match '^(n|no)?$') { Say "  cancelled"; return }
        else { foreach ($n in ($a -split '\s+')) { if ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $matches.Count) { $chosen += $matches[[int]$n-1] } } }
    }
    if ($chosen.Count -eq 0) { Say "  nothing chosen"; return }
    if (-not (Confirm-YesNo ("Delete {0} file(s)?" -f $chosen.Count))) { Say "  cancelled"; return }
    foreach ($x in $chosen) {
        Unlock-GuardFile -Path $x.FullName -User $script:User | Out-Null
        Remove-Item -LiteralPath $x.FullName -Force -EA SilentlyContinue
        Ok "deleted" $x.Name
    }
}

function Cmd-Move($arg) {
    $f = Cur; if (-not $f) { Say "  no folder protected yet" 'Red'; return }
    if ($arg -eq 'folder') {
        $dest = Read-Line "  Where to? type a folder path then Enter > "
        if (-not $dest) { Say "  cancelled"; return }
        Unlock-GuardTree -Folder $f.path -User $script:User | Out-Null
        try { Move-Item -LiteralPath $f.path -Destination $dest -Force -ErrorAction Stop } catch { Say "  move failed: $($_.Exception.Message)" 'Red'; return }
        $f.path = $dest; $f.name = Get-FolderName $dest
        Lock-GuardTree -Folder $dest -User $script:User -Skip (Folder-Skip $f) | Out-Null
        Save-GuardConfig -Config $script:Cfg -User $script:User
        Ok "moved" $dest; return
    }
    $files = @(Find-Matches $f $arg)
    if ($arg -eq 'all') { $files = @(Get-GuardFiles -Folder $f.path) }
    if ($files.Count -eq 0) { Say "  no file matches `"$arg`""; return }
    $dest = Read-Line "  Where to? type a folder path then Enter > "
    if (-not $dest) { Say "  cancelled"; return }
    if (-not (Test-Path -LiteralPath $dest)) {
        if (Confirm-YesNo "$dest does not exist. Create it?") { New-Item -ItemType Directory -Path $dest -Force | Out-Null } else { Say "  cancelled"; return }
    }
    Say ""; Say "  Cut or copy?"; Say "  > 1  cut"; Say "    2  copy"
    $cc = Read-Line "  type 1 or 2 then Enter > "
    $cut = ($cc -eq '1' -or $cc -match '^cut$')
    foreach ($x in $files) {
        if ($cut) { Unlock-GuardFile -Path $x.FullName -User $script:User | Out-Null; Move-Item -LiteralPath $x.FullName -Destination $dest -Force -EA SilentlyContinue; Ok "moved" $x.Name }
        else      { Copy-Item -LiteralPath $x.FullName -Destination $dest -Force -EA SilentlyContinue; Ok "copied" $x.Name }
    }
}

function Cmd-Edit($arg) {
    $targets = @()
    if ($arg -eq 'all') { $targets = $script:Cfg.folders } else { $c = Cur; if ($c) { $targets = @($c) } }
    foreach ($f in $targets) {
        Unlock-GuardTree -Folder $f.path -User $script:User | Out-Null
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
        Ok "locked" ("{0}  ·  {1} files" -f $f.name, $r.Locked)
    }
}

function Cmd-Init($arg) {
    $path = $arg
    if (-not $path) { $path = (Get-Location).Path }
    $path = (Resolve-Path -LiteralPath $path -ErrorAction SilentlyContinue).Path
    if (-not $path) { Say "  not found: $arg" 'Red'; return }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { Say "  not a folder: $path" 'Red'; return }
    foreach ($f in $script:Cfg.folders) { if ($f.path -eq $path) { Say "  already protected  ·  type  use"; return } }
    $files = @(Get-GuardFiles -Folder $path)
    $sz = ($files | Measure-Object Length -Sum).Sum
    Say ""; Say ("  {0}  ·  {1}  ·  {2} files  ·  {3:N0} B" -f (Get-FolderName $path), $path, $files.Count, $sz)
    Say ""
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
    foreach ($f in $targets) {
        Unlock-GuardTree -Folder $f.path -User $script:User | Out-Null
        $jp = Join-Path $f.path '_guard.json'
        Unlock-GuardFile -Path $jp -User $script:User | Out-Null
        Remove-Item -LiteralPath $jp -Force -EA SilentlyContinue
        Ok "unlocked" $f.name
    }
    $keep = @(); foreach ($f in $script:Cfg.folders) { if ($targets -notcontains $f) { $keep += $f } }
    $script:Cfg.folders = $keep
    if ($script:Cfg.current -ge $script:Cfg.folders.Count) { $script:Cfg.current = [Math]::Max(0, $script:Cfg.folders.Count - 1) }
    Save-GuardConfig -Config $script:Cfg -User $script:User
    Ok "removed" "from guard"
}

function Cmd-Skip($arg) {
    $f = Cur; if (-not $f) { Say "  no folder protected yet" 'Red'; return }
    if (-not $arg) {
        Say ""; Say ("  skip list for {0}" -f $f.name)
        Say ("    built-in   " + ($script:BuiltinSkip -join '  '))
        $yours = Folder-Skip $f; if ($yours.Count -eq 0) { $yours = @('—') }
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
        foreach ($x in $script:Cfg.folders) { $x.skip = @((Folder-Skip $x) + $parts[1] | Select-Object -Unique) }
        Save-GuardConfig -Config $script:Cfg -User $script:User
        Ok "added" ("{0} to all folders" -f $parts[1]); return
    }
    $f.skip = @((Folder-Skip $f) + $arg | Select-Object -Unique)
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
        'cls'     { Clear-Host; Show-Table }
        'help'    { Show-Table }
        'exit'    { return $false }
        default   { Say ("  unknown command `"{0}`"" -f $cmd) 'Red' }
    }
    return $true
}
