# guard-shell.ps1 — the interactive program. Command handlers are separate functions so they
# can be driven by tests. Input goes through $script:InputProvider (a queue in tests, Read-Host live).

. "$PSScriptRoot\guard-core.ps1"
. "$PSScriptRoot\guard-config.ps1"

$script:Cfg  = $null
$script:User = $null
$script:Editing = @{}   # path -> $true while a folder is in 'edit' (unlocked) state

# ---- input / output -------------------------------------------------------
$script:GuardCommands = @('list','delete','move','edit','resume','init','remove','skip','folders','use','cls','help','update','uninstall','exit')
$script:History = New-Object System.Collections.Generic.List[string]

function Get-PathCompletions([string]$typed, [switch]$Dirs) {
    # "C:\Us" -> C:\Users ; "..\do" -> ..\docs ; relative to the terminal's folder, like cmd
    $typed = $typed.TrimStart('"')
    $cut = $typed.LastIndexOfAny([char[]]'\/')
    $dir = ''; $pre = $typed
    if ($cut -ge 0) { $dir = $typed.Substring(0, $cut + 1); $pre = $typed.Substring($cut + 1) }
    elseif ($typed -match '^[A-Za-z]:$') { return @($typed + '\') }
    $base = $dir; if (-not $base) { $base = (Get-Location).ProviderPath }
    elseif (-not [IO.Path]::IsPathRooted($base)) { $base = Join-Path (Get-Location).ProviderPath $base }
    $items = @(Get-ChildItem -LiteralPath $base -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name.StartsWith($pre, [StringComparison]::OrdinalIgnoreCase) })
    if ($Dirs) { $items = @($items | Where-Object { $_.PSIsContainer }) }
    return @($items | Sort-Object Name | ForEach-Object { $dir + $_.Name })
}

function Get-GuardCompletions([string]$line, [switch]$Paths) {
    # what Tab can put in place of the word being typed: @{ Base = text kept; Items = choices }
    if ($Paths) { return @{ Base = ''; Items = @(Get-PathCompletions $line -Dirs) } }
    $lead = $line.Length - $line.TrimStart().Length
    $t = $line.TrimStart()
    if ($t -notmatch '\s') {   # still typing the command
        return @{ Base = $line.Substring(0, $lead); Items = @($script:GuardCommands | Where-Object { $_.StartsWith($t, [StringComparison]::OrdinalIgnoreCase) }) }
    }
    $m = [regex]::Match($t, '^(\S+\s+)(.*)$')
    $cmd = $m.Groups[1].Value.Trim().ToLower(); $arg = $m.Groups[2].Value
    $base = $line.Substring(0, $lead) + $m.Groups[1].Value
    $words = @()
    switch ($cmd) {
        'init'   { return @{ Base = $base; Items = @(Get-PathCompletions $arg -Dirs) } }
        'help'   {
            # the start table: headings, rows and explanations; the row puts its topic in the line
            $rows = @($script:TableRows | Where-Object { $_[1].StartsWith($arg, [StringComparison]::OrdinalIgnoreCase) })
            return @{ Base = $base; Items = @($rows | ForEach-Object { $_[1] })
                      Labels = @($rows | ForEach-Object { '{0,-26}{1}' -f $_[2], $_[3] })
                      Groups = @($rows | ForEach-Object { $_[0] }) }
        }
        'use'    { $words = @(1..([Math]::Max(1, @($script:Cfg.folders).Count)) | ForEach-Object { "$_" }) }
        'skip'   { $words = @('all', 'remove') }
        { $_ -in 'edit','resume','remove' } { $words = @('all') }
        { $_ -in 'list' } { $words = @('all') }
        { $_ -in 'delete','move' } {
            $words = @('all'); if ($cmd -eq 'move') { $words += 'folder' }
            $f = $null; if ($script:Cfg -and @($script:Cfg.folders).Count) { $f = Cur }
            if ($f -and (Test-Path -LiteralPath $f.path)) {
                $words += @(Get-GuardItems $f.path | Select-Object -First 5000 | ForEach-Object { $_.Name } | Sort-Object -Unique)
            }
        }
    }
    return @{ Base = $base; Items = @($words | Where-Object { $_.StartsWith($arg, [StringComparison]::OrdinalIgnoreCase) }) }
}

function Get-CommonStart([string[]]$Words) {
    # the longest start all words share, ignoring case ("edit","exit" -> "e")
    $s = $Words[0]
    foreach ($x in $Words) { while ($s -and -not $x.StartsWith($s, [StringComparison]::OrdinalIgnoreCase)) { $s = $s.Substring(0, $s.Length - 1) } }
    return $s
}

function Read-GuardInput([string]$Prompt, [switch]$Paths) {
    # One line from the keyboard. Tab: one match = filled in; several = filled in as far as they
    # agree, and a list opens under the line: Up/Down (or Tab/Shift+Tab) move, Enter takes the
    # marked one, typing more narrows the list, Esc closes it. No list: Up/Down = earlier lines,
    # Esc = clear the line. Plain ReadLine when piped.
    Write-Host -NoNewline $Prompt
    $piped = $true; try { $piped = [Console]::IsInputRedirected } catch { }
    if ($piped) { return [Console]::ReadLine() }
    $buf = ''; $pos = 0; $shown = 0; $listShown = 0
    $top = [Console]::CursorTop; $left = [Console]::CursorLeft
    $hist = $script:History.Count; $saved = ''
    $menu = $null      # @{ Base = text before the word; Items = choices; Sel = marked one }
    $m = ''; if ($script:GuardMargin) { $m = ' ' }
    $maxRows = 8
    $refresh = {   # dot-sourced: the list again, for the word now before the cursor
        $c = Get-GuardCompletions $buf.Substring(0, $pos) -Paths:$Paths
        if (@($c.Items).Count -eq 0) { $menu = $null } else { $menu = @{ Base = $c.Base; Items = @($c.Items); Labels = $c.Labels; Groups = $c.Groups; Sel = 0 } }
    }
    $take = {      # dot-sourced: put the marked choice in the line, close the list
        $head = $menu.Base + $menu.Items[$menu.Sel]
        $buf = $head + $buf.Substring($pos); $pos = $head.Length; $menu = $null
    }
    $draw = {      # dot-sourced: the line, then the list under it; updates $top / $shown / $listShown
        $w = [Console]::BufferWidth
        [Console]::SetCursorPosition($left, $top)
        $pad = [Math]::Max(0, $shown - $buf.Length)
        Microsoft.PowerShell.Utility\Write-Host -NoNewline ($buf + (' ' * $pad))   # (names with é, ü... show right)
        # writing past the bottom scrolls the window: the line start moved up with it
        $end = $left + $buf.Length + $pad
        $want = $top + [Math]::Floor([Math]::Max(0, $end - 1) / $w)
        if ($end -gt 0 -and [Console]::CursorTop -lt $want) { $top -= ($want - [Console]::CursorTop) }
        $shown = $buf.Length
        $rows = @()
        if ($menu) {
            $n = $menu.Items.Count
            # each choice starts right under the word being completed, the > two columns before it
            $at0 = ($left + $menu.Base.Length) % $w
            if ($at0 -lt 2 -or $at0 -gt $w - 12) { $at0 = 2 + $m.Length }
            $pre = ' ' * ($at0 - 2)
            # every row: text, colour, choice number (-1 = a heading or a blank line)
            $disp = New-Object System.Collections.ArrayList
            $last = $null; $selRow = 0
            for ($i = 0; $i -lt $n; $i++) {
                if ($menu.Groups) {
                    # help: the start table's headings, no blank lines (Tab.md)
                    $g = $menu.Groups[$i]
                    if ($g -ne $last) { [void]$disp.Add(@(($pre + '  ' + $script:TableHeads[$g]), 'Gray', -1)); $last = $g }
                }
                $label = $menu.Items[$i]; if ($menu.Labels) { $label = $menu.Labels[$i] }
                $mark = '  '; $col = 'Gray'; if ($i -eq $menu.Sel) { $mark = '> '; $col = 'Green'; $selRow = $disp.Count }
                [void]$disp.Add(@(($pre + $mark + $label), $col, $i))
            }
            $limit = $maxRows; if ($menu.Groups) { try { $limit = [Math]::Max($maxRows, [Console]::WindowHeight - 4) } catch { } }
            $vis = [Math]::Min($limit, $disp.Count)
            $first = [Math]::Max(0, [Math]::Min($selRow - [Math]::Floor($vis / 2), $disp.Count - $vis))
            for ($r = $first; $r -lt $first + $vis; $r++) { $rows += ,@($disp[$r][0], $disp[$r][1]) }
        }
        $below = $top + [Math]::Floor([Math]::Max(0, $left + [Math]::Max($buf.Length, 1) - 1) / $w) + 1
        $need = [Math]::Max($rows.Count, $listShown)
        if ($need -gt 0) {
            # room under the line first: at the bottom of the window, scroll up (the line moves too)
            $over = $below + $need - [Console]::BufferHeight
            if ($over -gt 0) { [Console]::SetCursorPosition(0, [Console]::BufferHeight - 1); [Console]::Write("`n" * $over); $top -= $over; $below -= $over }
            for ($r = 0; $r -lt $need; $r++) {
                [Console]::SetCursorPosition(0, $below + $r)
                $t = ''; $col = 'Gray'; if ($r -lt $rows.Count) { $t = $rows[$r][0]; $col = $rows[$r][1] }
                if ($t.Length -gt $w - 1) { $t = $t.Substring(0, $w - 1) }
                # the host's own writer (not [Console]::Write): ↑ ↓ show as arrows, not as ?
                Microsoft.PowerShell.Utility\Write-Host -NoNewline $t.PadRight($w - 1) -ForegroundColor $col
            }
        }
        $listShown = $rows.Count
        $at = $left + $pos
        [Console]::SetCursorPosition($at % $w, $top + [Math]::Floor($at / $w))
    }
    while ($true) {
        $k = [Console]::ReadKey($true)
        $shift = [bool]($k.Modifiers -band [ConsoleModifiers]::Shift)
        if ($menu) {
            # the list is open
            $n = $menu.Items.Count
            switch ($k.Key) {
                'UpArrow'   { $menu.Sel = ($menu.Sel - 1 + $n) % $n }
                'DownArrow' { $menu.Sel = ($menu.Sel + 1) % $n }
                'Tab'       { if ($shift) { $menu.Sel = ($menu.Sel - 1 + $n) % $n } else { $menu.Sel = ($menu.Sel + 1) % $n } }
                'Enter'     { . $take }
                'Escape'    { $menu = $null }
                'Backspace' { if ($pos -gt 0) { $buf = $buf.Remove($pos - 1, 1); $pos--; . $refresh } else { $menu = $null } }
                default     {
                    $ch = $k.KeyChar
                    if ($ch -eq ' ') { $buf = $buf.Insert($pos, ' '); $pos++; $menu = $null }
                    elseif ($ch -and -not [char]::IsControl($ch)) { $buf = $buf.Insert($pos, [string]$ch); $pos++; . $refresh }
                    else {
                        # Left, Right, Home, End, Delete: close the list, then do it
                        $menu = $null
                        switch ($k.Key) {
                            'LeftArrow'  { if ($pos -gt 0) { $pos-- } }
                            'RightArrow' { if ($pos -lt $buf.Length) { $pos++ } }
                            'Home'       { $pos = 0 }
                            'End'        { $pos = $buf.Length }
                            'Delete'     { if ($pos -lt $buf.Length) { $buf = $buf.Remove($pos, 1) } }
                        }
                    }
                }
            }
            . $draw
            continue
        }
        switch ($k.Key) {
            'Enter'     {
                $pos = $buf.Length; . $draw; [Console]::WriteLine()
                if ($buf.Trim() -and -not $Paths) { $script:History.Add($buf) }
                return $buf
            }
            'Tab'       {
                $c = Get-GuardCompletions $buf.Substring(0, $pos) -Paths:$Paths
                $items = @($c.Items)
                if ($items.Count -eq 1) {
                    $head = $c.Base + $items[0]; $buf = $head + $buf.Substring($pos); $pos = $head.Length
                } elseif ($items.Count -gt 1) {
                    # fill in as far as all choices agree, then show them
                    $common = Get-CommonStart $items
                    if ($common.Length -gt ($pos - $c.Base.Length)) {
                        $head = $c.Base + $common; $buf = $head + $buf.Substring($pos); $pos = $head.Length
                    }
                    $menu = @{ Base = $c.Base; Items = $items; Labels = $c.Labels; Groups = $c.Groups; Sel = 0 }
                }
            }
            'Backspace' { if ($pos -gt 0) { $buf = $buf.Remove($pos - 1, 1); $pos-- } }
            'Delete'    { if ($pos -lt $buf.Length) { $buf = $buf.Remove($pos, 1) } }
            'LeftArrow' { if ($pos -gt 0) { $pos-- } }
            'RightArrow'{ if ($pos -lt $buf.Length) { $pos++ } }
            'Home'      { $pos = 0 }
            'End'       { $pos = $buf.Length }
            'Escape'    { $buf = ''; $pos = 0 }
            'UpArrow'   {
                if ($hist -gt 0) { if ($hist -eq $script:History.Count) { $saved = $buf }; $hist--; $buf = $script:History[$hist]; $pos = $buf.Length }
            }
            'DownArrow' {
                if ($hist -lt $script:History.Count) {
                    $hist++; if ($hist -eq $script:History.Count) { $buf = $saved } else { $buf = $script:History[$hist] }; $pos = $buf.Length
                }
            }
            default     {
                if ($k.KeyChar -and -not [char]::IsControl($k.KeyChar)) { $buf = $buf.Insert($pos, [string]$k.KeyChar); $pos++ }
            }
        }
        . $draw
    }
}

function Read-Line([string]$Prompt, [switch]$Paths) {
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
    $v = Read-GuardInput $Prompt -Paths:$Paths
    if ($null -eq $v) { return '' }   # input closed = cancel
    return $v.Trim()
}
# One space of margin on the left of everything guard prints, guard> included. Real console
# only: there the cursor column says whether a line is starting. Tests and logs get plain text.
$script:GuardMargin = $false
try { $script:GuardMargin = -not [Console]::IsOutputRedirected } catch { }
function Write-Host {
    param([Parameter(Position = 0, ValueFromRemainingArguments = $true)][object[]]$Object,
          [switch]$NoNewline, [object]$Separator = ' ', [ConsoleColor]$ForegroundColor, [ConsoleColor]$BackgroundColor)
    $p = @{}
    foreach ($k in 'NoNewline', 'ForegroundColor', 'BackgroundColor') { if ($PSBoundParameters.ContainsKey($k)) { $p[$k] = $PSBoundParameters[$k] } }
    $text = (@($Object) | ForEach-Object { "$_" }) -join [string]$Separator
    if ($script:GuardMargin) {
        try {
            if ([Console]::CursorLeft -eq 0) { $text = ' ' + $text }
            $text = $text -replace "`n", "`n "
            # rows padded to the full width (menus) would now wrap: give the space back at the end
            $max = [Console]::BufferWidth - 1
            # (only padding is cut: real text on a long line still wraps as before)
            $text = (($text -split "`n") | ForEach-Object { if ($_.Length -gt $max -and $_.Substring($max).Trim() -eq '') { $_.Substring(0, $max) } else { $_ } }) -join "`n"
        } catch { }
    }
    Microsoft.PowerShell.Utility\Write-Host $text @p
}

function Say([string]$t, [string]$c = 'Gray') { Write-Host $t -ForegroundColor $c }

# ---- loading dots: "  locking."  "  locking.."  "  locking..."  while a slow step runs ----
# A background thread redraws the line; the step itself prints nothing meanwhile. Real console
# only: tests and logs (output redirected) never see the dots.
function Start-GuardDots([string]$Text, [int]$DelayMs = 0) {
    # -DelayMs: draw only if the step takes longer than that (no flicker on quick steps)
    try { if ([Console]::IsOutputRedirected) { return $null } } catch { return $null }
    if ($script:GuardMargin) { $Text = ' ' + $Text }
    try { [Console]::CursorVisible = $false } catch { }   # the dots show it's working, not a blinking cursor
    $sync = [hashtable]::Synchronized(@{ Stop = $false })
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript({
        param($t, $s, $d)
        for ($i = 0; $i -lt $d / 50 -and -not $s.Stop; $i++) { Start-Sleep -Milliseconds 50 }
        $n = 0
        while (-not $s.Stop) {
            $n = $n % 3 + 1
            # 3 dots back to 1: spaces wipe the old ones, then the cursor goes back after the dots
            [Console]::Write("`r" + $t + ('.' * $n) + (' ' * (3 - $n)) + "`r" + $t + ('.' * $n))
            for ($i = 0; $i -lt 4 -and -not $s.Stop; $i++) { Start-Sleep -Milliseconds 100 }
        }
    }).AddArgument($Text).AddArgument($sync).AddArgument($DelayMs)
    return @{ PS = $ps; Sync = $sync; Run = $ps.BeginInvoke(); Text = $Text }
}
function Stop-GuardDots($h, [switch]$Keep) {
    # -Keep: leave "text..." and go to the next line. Otherwise wipe the line for what comes next.
    if (-not $h) { return }
    $h.Sync.Stop = $true
    try { [void]$h.PS.EndInvoke($h.Run) } catch { }
    $h.PS.Dispose()
    if ($Keep) { [Console]::WriteLine("`r" + $h.Text + '...') }
    else { [Console]::Write("`r" + (' ' * ($h.Text.Length + 3)) + "`r") }
    try { [Console]::CursorVisible = $true } catch { }
}
function Invoke-WithDots([string]$DotsText, [scriptblock]$DotsDo) {
    # (odd names: the block runs in here and sees these, so they must not hide the caller's)
    $dotsHandle = Start-GuardDots $DotsText
    try { & $DotsDo } finally { Stop-GuardDots $dotsHandle }
}

function Request-GuardAdmin([string]$Text, [string]$ArgList) {
    # The UAC prompt, with "Text." "Text.." "Text..." until the admin copy is about to print in
    # this window (it says so through two named events). Returns the process, $null = cancelled.
    $ready = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, "Local\guard-ready-$PID")
    $shown = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, "Local\guard-shown-$PID")
    $dots = Start-GuardDots $Text
    if (-not $dots) { Write-Host ($Text + '...') }
    # the prompt blocks whoever opens it: open it on another thread so the dots keep moving
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript({ param($a) try { Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -PassThru -ArgumentList $a } catch { } }).AddArgument($ArgList)
    $run = $ps.BeginInvoke()
    $p = $null; $t0 = $null
    try {
        while ($true) {
            if ($null -eq $t0 -and $run.IsCompleted) {
                $p = @($ps.EndInvoke($run)) | Select-Object -First 1
                if (-not $p) { break }          # No on the prompt
                $t0 = Get-Date
            }
            if ($ready.WaitOne(100)) { break }
            # an admin copy that never signals (it opened its own window, or failed): stop waiting
            if ($p -and ($p.HasExited -or ((Get-Date) - $t0).TotalSeconds -gt 20)) { break }
        }
    } finally {
        Stop-GuardDots $dots -Keep
        [void]$shown.Set()          # the line is done: the admin copy may print now
        $ps.Dispose()
    }
    return $p
}

function Wait-GuardCallerDots([int]$CallerPid) {
    # admin copy: the waiting window is drawing "Requesting Admin Access..." - let it end the line
    if (-not $CallerPid) { return }
    try {
        $shown = [Threading.EventWaitHandle]::OpenExisting("Local\guard-shown-$CallerPid")
        $ready = [Threading.EventWaitHandle]::OpenExisting("Local\guard-ready-$CallerPid")
        [void]$ready.Set(); [void]$shown.WaitOne(3000)
    } catch { }
}
# result rows, as in Flow.md: label, what, (optional) plain-words meaning, ok at column 81
function Ok([string]$label, [string]$detail, [string]$meaning = '') {
    $body = "{0,-9} {1}" -f $label, $detail
    if ($meaning) { $body = "{0,-9} {1,-25} {2}" -f $label, $detail, $meaning }
    Write-Host ("  {0} ok" -f $body.PadRight(76)) -ForegroundColor Green
}
function Format-Size([double]$b) {
    if ($b -ge 1GB) { return '{0:0.0} GB' -f ($b / 1GB) }
    if ($b -ge 1MB) { return '{0:0.0} MB' -f ($b / 1MB) }
    if ($b -ge 1KB) { return '{0:0.0} KB' -f ($b / 1KB) }
    return '{0:0} B' -f $b
}
function Format-When($t) {
    # 21:04 today  /  2026-07-30
    if (-not $t) { return '' }
    $t = [datetime]$t
    if ($t.Date -eq (Get-Date).Date) { return ('{0:HH:mm} today' -f $t) }
    return ('{0:yyyy-MM-dd}' -f $t)
}
function N([int]$n, [string]$word) { if ($n -eq 1) { return "1 $word" }; return "$n ${word}s" }   # 1 file / 2 files
function Test-Quiet { [bool](Get-GuardTestEnv 'GUARD_NOBROWSER') }   # tests: no browser, no Explorer windows

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
function Format-Item($x, [switch]$Where) {
    # amazon-checkout.png     2026-11-15 21:04    1.2 MB   (-Where: + the folder it is in)
    $size = 'folder'; if (-not $x.PSIsContainer) { $size = Format-Size $x.Length }
    $base = (Cur).path
    $rel = $x.FullName; if ($rel.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { $rel = $rel.Substring($base.Length).TrimStart('\') }
    $s = "{0,-28} {1:yyyy-MM-dd HH:mm}  {2,8}" -f $rel, $x.LastWriteTime, $size
    if ($Where) { $s += "   " + (Split-Path $x.FullName -Parent) }
    return $s
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
            $m = ' '; $c = 'Gray'; if ($i -eq $sel - 1) { $m = '>'; $c = 'Green' }
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

function Select-Items([string[]]$Rows) {
    # Pick one or more rows. Last row is 'all'. Real console: ↑ ↓ move the '>', Enter picks it;
    # or type numbers (1 3) then Enter. Picked rows turn green. Esc or n = cancel.
    # Returns the picked row numbers (1-based), all rows for 'all', or @() for cancel.
    $all = $Rows.Count + 1
    $opts = @($Rows) + @('all')
    $live = $true
    try { if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { $live = $false } } catch { $live = $false }
    if (($script:InputQueue -and $script:InputQueue.Count) -or (Get-GuardTestEnv 'GUARD_ANSWERS')) { $live = $false }
    $parse = {
        param([string]$a)
        $a = $a.Trim()
        if (-not $a -or $a -match '^(n|no)$') { return @() }
        if ($a -eq 'all') { return @(1..$Rows.Count) }
        $p = @()
        foreach ($t in ($a -split '[\s,]+')) {
            if ($t -match '^\d+$') {
                $v = [int]$t
                if ($v -eq $all) { return @(1..$Rows.Count) }
                if ($v -ge 1 -and $v -le $Rows.Count -and $p -notcontains $v) { $p += $v }
            }
        }
        return $p
    }
    $hint = "  type numbers ({0}) or ↑ ↓ then Enter > " -f $(if ($Rows.Count -ge 3) { '1 3' } else { '1 2' })
    if (-not $live) {
        for ($i = 0; $i -lt $opts.Count; $i++) { $m = ' '; if ($i -eq 0) { $m = '>' }; Say ("  {0} {1}  {2}" -f $m, ($i+1), $opts[$i]) }
        return @(& $parse (Read-Line $hint))
    }
    $sel = 1; $buf = ''
    $width = 0; try { $width = [Console]::BufferWidth - 1 } catch { $width = 79 }
    $draw = {
        param($picked)
        for ($i = 0; $i -lt $opts.Count; $i++) {
            $m = ' '; $c = 'Gray'
            if ($i -eq $sel - 1) { $m = '>'; $c = 'Green' }
            if ($picked -and ($picked -contains ($i + 1))) { $c = 'Green' }
            Write-Host (("  {0} {1}  {2}" -f $m, ($i+1), $opts[$i]).PadRight($width)) -ForegroundColor $c
        }
        Write-Host -NoNewline (($hint + $buf).PadRight($width))
    }
    & $draw @()
    $top = [Console]::CursorTop - $opts.Count
    while ($true) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq 'Escape') { Write-Host ""; return @() }
        if ($k.Key -eq 'Enter') {
            $picked = @()
            if ($buf.Trim()) { $picked = @(& $parse $buf) }
            elseif ($sel -eq $all) { $picked = @(1..$Rows.Count) }
            else { $picked = @($sel) }
            try { [Console]::SetCursorPosition(0, $top) } catch { }
            & $draw $picked; Write-Host ""
            return $picked
        }
        if ($k.Key -eq 'UpArrow' -and $sel -gt 1) { $sel-- }
        elseif ($k.Key -eq 'DownArrow' -and $sel -lt $opts.Count) { $sel++ }
        elseif ($k.Key -eq 'Backspace') { if ($buf.Length) { $buf = $buf.Substring(0, $buf.Length - 1) } }
        elseif ($k.KeyChar -match '[0-9 ,a-zA-Z]') { $buf += $k.KeyChar }
        else { continue }
        try { [Console]::SetCursorPosition(0, $top) } catch { }
        & $draw @()
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
    Invoke-WithDots '  telling the background guard' {
        for ($i = 0; $i -lt 80; $i++) {
            $s = Read-WatchStatus
            if ($s -and ([string]$s.config -eq $want)) { return }
            Start-Sleep -Milliseconds 250
        }
    }
}

function Get-WatchState {
    # Reads the background guard's heartbeat. Returns @{ Text; Color; Detail; Running }.
    $s = Read-WatchStatus
    if (-not $s -or -not $s.alive) { return @{ Text='STOPPED'; Color='Red'; Detail='never started  ·  restart the PC or reinstall'; Running=$false } }
    $age = ((Get-Date) - [datetime]$s.alive).TotalSeconds
    if ($age -gt 120) { return @{ Text='STOPPED'; Color='Red'; Detail=('last seen {0:yyyy-MM-dd HH:mm}' -f [datetime]$s.alive); Running=$false } }
    $d = 'last full check —'
    if ($s.lastFull) { $d = 'last full check {0:HH:mm}' -f [datetime]$s.lastFull }
    if ($s.lastLock) { $d += ('  ·  last file locked {0}' -f ((Format-When $s.lastLock) -replace ' today$', '')) }
    return @{ Text='running'; Color='Green'; Detail=$d; Running=$true }
}

function Test-ItemLocked([string]$Path) {
    # true if the user has a deny-delete rule on it
    try {
        foreach ($a in (Get-Acl -LiteralPath $Path).Access) {
            if ($a.AccessControlType -eq 'Deny' -and $a.IdentityReference.Value -ieq $script:User -and $a.FileSystemRights.ToString() -match 'Delete') { return $true }
        }
    } catch { }
    return $false
}

function Get-FolderState($f) {
    # What the status block needs for one folder.
    $st = [ordered]@{ Exists = (Test-Path -LiteralPath $f.path -PathType Container); Files = 0; Newest = $null; Missing = 0; Editing = $false }
    if (-not $st.Exists) { return [pscustomobject]$st }
    $files = @(Get-GuardFiles -Folder $f.path)
    $st.Files = $files.Count
    $st.Newest = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $st.Editing = [bool]($script:Editing[$f.path] -or $f.editing)
    if (-not $st.Editing -and $files.Count -le 5000) {
        $sk = @(Folder-Skip $f)
        foreach ($x in $files) {
            if (Test-GuardSkip -Name $x.Name -Extra $sk) { continue }
            if (-not (Test-ItemLocked $x.FullName)) { $st.Missing++ }
        }
    }
    return [pscustomobject]$st
}

function Show-FolderBlock($f, [int]$i, $w) {
    $n = $script:Cfg.folders.Count
    $mark = ''; if ($i -eq $script:Cfg.current) { $mark = '  ·  current' }
    $st = $script:FolderStates[$f.path]; if (-not $st) { $st = Get-FolderState $f }
    $script:FolderStates[$f.path] = $st   # for the next line (not on $f: that would be saved to config.json)
    if (-not $st.Exists) {
        Say ("folder    {0,-26} {1} of {2}{3}  ·  NOT FOUND" -f $f.name, ($i+1), $n, $mark) 'Red'
        Say ("path      {0}" -f $f.path)
        Say  "files     —"
        Say  "lock      —"
        Say ("guard     {0}" -f $w.Text) $w.Color
        return
    }
    Say ("folder    {0,-26} {1} of {2}{3}" -f $f.name, ($i+1), $n, $mark)
    Say ("path      {0}" -f $f.path)
    $fl = "files     {0}" -f $st.Files
    if ($st.Newest) { $fl = "{0,-36} newest  {1}  {2}" -f $fl, $st.Newest.Name, (Format-When $st.Newest.LastWriteTime) }
    if ($st.Missing -gt 0) {
        if ($w.Running) { $fl += ("  ·  {0} waiting" -f $st.Missing) } else { $fl += ("  ·  {0} NOT locked" -f $st.Missing) }
    }
    Say $fl
    $what = "owner SYSTEM  ·  folder + folder above"
    if ($st.Editing) {
        Say ("lock      {0,-26} editing  ·  locks at next logon" -f 'UNLOCKED') 'Red'
        Say ("guard     {0,-26} not locking new files while editing" -f $w.Text) $w.Color
        return
    }
    $locked = $st.Files - $st.Missing
    if ($locked -gt 0) { $what += (" + {0} files" -f $locked) }
    if ($st.Missing -gt 0 -and -not $w.Running) { Say ("lock      {0,-26} {1}" -f 'PARTIAL', $what) 'Red' }
    else { Say ("lock      {0,-26} {1}" -f 'LOCKED', $what) 'Green' }
    Say ("guard     {0,-26} {1}" -f $w.Text, $w.Detail) $w.Color
}

function Show-Status([switch]$All) {
    # -All: every protected folder (start, cls). Otherwise only the current one.
    $line = ('-' * 86)
    $w = Get-WatchState
    $script:FolderStates = @{}
    # count first (big folders take a moment), then print the block in one go
    $show = @(); if ($All) { $show = @($script:Cfg.folders) } elseif ($script:Cfg.folders.Count) { $show = @(Cur) }
    if ($show.Count) {
        $dotsH = Start-GuardDots '  checking folders' 300
        try { foreach ($f in $show) { $script:FolderStates[$f.path] = Get-FolderState $f } } finally { Stop-GuardDots $dotsH }
    }
    Say $line
    if ($script:Cfg.folders.Count -eq 0) {
        Say "folder    none yet"
        Say ("guard     {0,-26} nothing to protect" -f $w.Text) $w.Color
    } elseif ($All) {
        for ($i = 0; $i -lt $script:Cfg.folders.Count; $i++) {
            Show-FolderBlock $script:Cfg.folders[$i] $i $w
            if ($i -lt $script:Cfg.folders.Count - 1) { Say "" }
        }
    } else {
        Show-FolderBlock (Cur) $script:Cfg.current $w
    }
    Say $line
    Say ""
    Show-NextLines $w
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
    if (-not (Cur)) { Say "  no folder protected yet" 'Red'; return }
    $targets = @(Cur); if ($arg -eq 'all') { $targets = @($script:Cfg.folders) }
    $keep = $script:Cfg.current
    foreach ($f in $targets) {
        if (-not (Test-Path -LiteralPath $f.path)) { Say ""; Say ("  {0,-14} {1}   NOT FOUND" -f $f.name, $f.path) 'Red'; continue }
        $script:Cfg.current = [array]::IndexOf(@($script:Cfg.folders), $f)   # Format-Item shows names relative to this folder
        $items = @(Get-GuardItems $f.path | Sort-Object LastWriteTime -Descending)
        $nd = @($items | Where-Object { $_.PSIsContainer }).Count
        $count = N ($items.Count - $nd) 'file'; if ($nd) { $count += (", " + (N $nd 'folder')) }
        Say ""
        if ($arg -eq 'all') { Say ("  {0,-14} {1}   {2}" -f $f.name, $f.path, $count) 'Cyan' }
        else { Say ("  {0}, newest first" -f $count) }
        $i = 1; foreach ($x in $items) { Say ("  {0,3}  {1}" -f $i, (Format-Item $x)); $i++ }
    }
    $script:Cfg.current = $keep
    Say ""
}

function Cmd-Delete($arg) {
    $f = Cur; if (-not $f) { Say "  no folder protected yet" 'Red'; return }
    if ($arg -eq 'all') {
        $files = @(Get-GuardFiles -Folder $f.path)
        $sz = ($files | Measure-Object Length -Sum).Sum
        Say ""; Say ("  This empties the folder: {0} files, {1}." -f $files.Count, (Format-Size $sz))
        $a = Read-Line "  type YES to continue, anything else to cancel > "
        if ($a -ne 'YES') { Say "  cancelled"; return }
        Say ""
        # top level only: a subfolder goes with everything in it
        $top = @(Get-ChildItem -LiteralPath $f.path -Force -EA SilentlyContinue | Where-Object { $_.Name -ne '_guard.json' })
        $failed = 0
        foreach ($x in $top) { if (-not (Remove-GuardedFile $f $x)) { $failed++ } }
        $left = @(Get-GuardFiles -Folder $f.path).Count
        Ok "unlocked" ("{0} files" -f $files.Count)
        Ok "deleted" ("{0} files" -f ($files.Count - $left))
        if ($left -eq 0) { Say "  folder is empty and still protected" }
        else { Say ("  {0} files could not be deleted and are still locked" -f $left) 'Red' }
        return
    }
    # (not $matches: that is PowerShell's automatic variable, and -match below would overwrite it)
    $hits = @(Find-Matches $f $arg)
    if ($hits.Count -eq 0) { Say "  no file matches `"$arg`"  ·  type  list  to see names"; return }
    $chosen = @(Pick-Items $hits)
    if ($chosen.Count -eq 0) { Say "  cancelled"; return }
    $nf = @($chosen | Where-Object { $_.PSIsContainer }).Count
    if ($chosen.Count -eq 1) {
        $q = 'Delete this file?'; if ($nf) { $q = 'Delete this folder and everything in it?' }
    } else {
        $q = "Delete {0} files?" -f $chosen.Count
        if ($nf) { $q = "Delete {0} items? ({1} folders, with everything in them)" -f $chosen.Count, $nf }
    }
    if (-not (Confirm-YesNo $q)) { Say "  cancelled"; return }
    Say ""
    foreach ($x in $chosen) {
        if (-not (Test-Path -LiteralPath $x.FullName)) { continue }   # was inside a folder deleted just before
        if (Remove-GuardedFile $f $x) {
            if ($chosen.Count -eq 1) { Ok "unlocked" $x.Name }
            Ok "deleted" $x.Name
        }
    }
    Say ("  {0} still locked" -f (N @(Get-GuardFiles -Folder $f.path).Count 'file'))
}

function Pick-Items($hits) {
    # One match: show it and use it. Many: 'Which files?' picker. Returns the chosen items.
    if ($hits.Count -eq 1) { Say ""; Say ("  {0}" -f (Format-Item $hits[0] -Where)); return @($hits[0]) }
    Say ""; Say "  Which files?"
    $rows = @($hits | ForEach-Object { Format-Item $_ -Where })
    $nums = @(Select-Items $rows)
    return @($nums | ForEach-Object { $hits[$_ - 1] })
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
        $nfiles = @(Get-GuardFiles -Folder $f.path).Count
        Say ""; Say ("  {0}  ·  {1}  ·  {2} files" -f $f.name, $f.path, $nfiles)
        Say ""; Say "  Where to?"
        $dest = (Read-Line "  type a folder path then Enter (Tab completes) > " -Paths).Trim('"')
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
        Say ""
        Invoke-WithDots '  unlocking' { Unlock-GuardTree -Folder $old -User $script:User -KeepAbove:(Test-AboveShared $f) | Out-Null }
        Ok "unlocked" ("folder, folder above, {0} files" -f $nfiles)
        $moveErr = $null
        Invoke-WithDots '  moving' { try { Move-Item -LiteralPath $old -Destination $dest -ErrorAction Stop } catch { $_ } } | ForEach-Object { $moveErr = $_ }
        if ($moveErr) {
            Say "  FAIL  move  $($moveErr.Exception.Message)" 'Red'
            Invoke-WithDots '  locking again' { Lock-GuardTree -Folder $old -User $script:User -Skip (Folder-Skip $f) | Out-Null }
            $f.editing = $false; Save-GuardConfig -Config $script:Cfg -User $script:User
            Say "  not moved. still protected at the old place." 'Red'
            return
        }
        Ok "moved" $dest
        $f.path = $dest; $f.name = Get-FolderName $dest; $f.editing = $false
        $r = Invoke-WithDots '  locking' {
            Set-GuardOwnerSystem -Folder $dest -User $script:User | Out-Null   # other drive = new files, new owner
            Lock-GuardTree -Folder $dest -User $script:User -Skip (Folder-Skip $f)
        }
        Ok "locking" ("folder, folder above ({0}), {1} files" -f (Split-Path (Split-Path $dest -Parent) -Leaf), $r.Locked)
        Save-GuardConfig -Config $script:Cfg -User $script:User
        Ok "memory" "_guard.json updated in all folders  ·  new path saved"
        Say ""; Say "  Folder is Moved and Protected Successfully." 'Green'
        Say ("  path        {0}" -f $dest)
        Say  "  note        programs that save here (e.g. the Chrome extension) must be pointed to the new path"
        return
    }
    if ($arg -eq 'all') {
        # top level only: subfolders keep their shape at the destination
        $files = @(Get-ChildItem -LiteralPath $f.path -Force -EA SilentlyContinue | Where-Object { $_.Name -ne '_guard.json' })
        if ($files.Count -eq 0) { Say "  the folder is empty"; return }
    } else {
        $hits = @(Find-Matches $f $arg)
        if ($hits.Count -eq 0) { Say "  no file matches `"$arg`"  ·  type  list  to see names"; return }
        $files = @(Pick-Items $hits)
        if ($files.Count -eq 0) { Say "  cancelled"; return }
    }
    Say ""; Say "  Where to?"
    $dest = Read-Line "  type a folder path then Enter > "
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
    if ($arg -eq 'all') {
        $verb = 'copies'; if ($cut) { $verb = 'moves' }
        Say ""; Say ("  This {0} {1} items." -f $verb, $files.Count)
        $a = Read-Line "  type YES to continue, anything else to cancel > "
        if ($a -ne 'YES') { Say "  cancelled"; return }
    }
    Say ""
    foreach ($x in $files) {
        if (-not (Test-Path -LiteralPath $x.FullName)) { continue }   # inside a folder moved just before
        $target = Join-Path $dp $x.Name
        if ($cut) {
            Unlock-GuardItem $x
            if ($files.Count -eq 1) { Ok "unlocked" $x.Name }
            try { Move-Item -LiteralPath $x.FullName -Destination $dp -Force -ErrorAction Stop; Give-ToUser $target; Ok "moved" $target }
            catch {
                # still here (or partly): lock what is left, say so
                Relock-GuardItem $f $x.FullName
                Say ("  FAIL  {0}  not moved, still protected  ·  {1}" -f $x.Name, $_.Exception.Message) 'Red'
            }
        } else {
            try {
                if ($x.PSIsContainer) { Copy-Item -LiteralPath $x.FullName -Destination $dp -Recurse -Force -ErrorAction Stop }
                else { Copy-Item -LiteralPath $x.FullName -Destination $dp -Force -ErrorAction Stop }
                Give-ToUser $target; Ok "copied" $target
            }
            catch { Say ("  FAIL  {0}  not copied  ·  {1}" -f $x.Name, $_.Exception.Message) 'Red' }
        }
    }
    Say ("  {0} still locked" -f (N @(Get-GuardFiles -Folder $f.path).Count 'file'))
}

function Cmd-Edit($arg) {
    $targets = @()
    if ($arg -eq 'all') { $targets = $script:Cfg.folders } else { $c = Cur; if ($c) { $targets = @($c) } }
    if ($targets.Count -eq 0) { Say "  no folder protected yet" 'Red'; return }
    # tell the background guard first, and wait until it has seen it, then unlock
    $targets = @($targets | Where-Object { Test-Path -LiteralPath $_.path })
    if ($targets.Count -eq 0) { Say "  folder not found" 'Red'; return }
    foreach ($f in $targets) {
        $f | Add-Member -NotePropertyName editing -NotePropertyValue $true -Force
        $f | Add-Member -NotePropertyName editingSince -NotePropertyValue ((Get-Date).ToString('o')) -Force
        $f | Add-Member -NotePropertyName editingFiles -NotePropertyValue (@(Get-GuardFiles -Folder $f.path).Count) -Force
    }
    Save-GuardConfig -Config $script:Cfg -User $script:User
    Wait-WatchSync
    foreach ($f in $targets) {
        Say ""; Say ("  {0}  ·  {1}  ·  {2} files" -f $f.name, $f.path, $f.editingFiles)
        Say ""
        Invoke-WithDots '  unlocking' { Unlock-GuardTree -Folder $f.path -User $script:User -KeepAbove:(Test-AboveShared $f) | Out-Null }
        $script:Editing[$f.path] = $true
        Ok "unlocked" ("folder + folder above + {0} files" -f $f.editingFiles)
        if (-not (Test-Quiet)) {
            # explorer.exe opens the window in the user's normal (not admin) session
            try { Start-Process explorer.exe -ArgumentList "`"$($f.path)`""; Ok "opened" "in Explorer" } catch { }
        }
    }
    Say "  edit, save, rename, delete freely. locks again at next logon, or type  resume"
}

function Cmd-Resume($arg) {
    $targets = @()
    if ($arg -eq 'all') { $targets = $script:Cfg.folders } else { $c = Cur; if ($c) { $targets = @($c) } }
    if ($targets.Count -eq 0) { Say "  no folder protected yet" 'Red'; return }
    Say ""
    foreach ($f in $targets) {
        if (-not (Test-Path -LiteralPath $f.path)) { Say ("  {0}  not found: {1}" -f $f.name, $f.path) 'Red'; continue }
        $now = @(Get-GuardFiles -Folder $f.path).Count
        $found = "{0} files found" -f $now
        if ($f.editing -and $null -ne $f.editingFiles) {
            $d = [int]$f.editingFiles - $now
            if ($d -gt 0) { $found += (" ({0} deleted while editing)" -f $d) }
            elseif ($d -lt 0) { $found += (" ({0} added while editing)" -f (-$d)) }
        }
        if ($targets.Count -gt 1) { Say ("  {0}" -f $f.name) 'Cyan' }
        Say ("  full check   {0}" -f $found)
        $r = Invoke-WithDots '  locking' { Lock-GuardTree -Folder $f.path -User $script:User -Skip (Folder-Skip $f) }
        $script:Editing.Remove($f.path)
        $f | Add-Member -NotePropertyName editing -NotePropertyValue $false -Force
        Write-Host ("  {0} ok" -f ("locked       folder + folder above + {0} files" -f $r.Locked).PadRight(76)) -ForegroundColor Green
        foreach ($x in $r.Waiting) { Say ("  not locked yet   {0}   {1}" -f $x.Reason, $x.Name) 'Yellow' }
    }
    Save-GuardConfig -Config $script:Cfg -User $script:User
    if (-not (Get-WatchState).Running) {
        $how = Start-GuardWatch -Dir $script:InstallDir -User $script:User
        if ($how) { Ok "started" "background guard" }
    }
}

function Cmd-Init($arg) {
    $path = "$arg".Trim().Trim('"')   # init "C:\My Folder" works like  init C:\My Folder
    if (-not $path) { $path = (Get-Location).Path }
    $path = (Resolve-Path -LiteralPath $path -ErrorAction SilentlyContinue).Path
    if (-not $path) { Say "  not found: $arg" 'Red'; return }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { Say "  not a folder: $path" 'Red'; return }
    for ($k = 0; $k -lt $script:Cfg.folders.Count; $k++) {
        if ($script:Cfg.folders[$k].path -ieq $path) { Say ("  already protected  ·  it is folder {0}  ·  type  use {0}" -f ($k+1)); return }
    }
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
    $name = Get-FolderName $path
    # cloud folders: files that are only in the cloud have nothing on the disk to protect
    $cloud = @($files | Where-Object { ([int]$_.Attributes -band (0x1000 -bor 0x40000 -bor 0x400000)) -ne 0 })
    if ($cloud.Count -gt 0) {
        Say ""; Say ("  {0} files in {1} are only in the cloud, not on this PC:" -f $cloud.Count, $name) 'Red'
        $cloud | Select-Object -First 5 | ForEach-Object { Say ("    {0}" -f $_.FullName.Substring($path.Length).TrimStart('\')) }
        if ($cloud.Count -gt 5) { Say ("    ... and {0} more" -f ($cloud.Count - 5)) }
        Say "  fix       right-click the folder in Explorer > Always keep on this device"
        Say "            wait until every file shows a green tick, then  init  again"
        return
    }
    $sz = ($files | Measure-Object Length -Sum).Sum
    $facts = "  {0}  ·  {1}  ·  {2} files  ·  {3}" -f $name, $path, $files.Count, (Format-Size $sz)
    if (-not $arg) { $facts += "  ·  the folder this terminal is in" }
    Say ""; Say $facts
    Say "  (Ctrl+C while locking undoes it)" 'DarkGray'
    Say ""
    $hadOthers = $script:Cfg.folders.Count

    # Ctrl+C while locking: stop and undo. Real console only.
    $stop = $null; $oldTreat = $null
    try { if (-not [Console]::IsInputRedirected) { $oldTreat = [Console]::TreatControlCAsInput; [Console]::TreatControlCAsInput = $true } } catch { }
    if ($null -ne $oldTreat) {
        $stop = {
            while ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                if ($k.Key -eq 'C' -and ($k.Modifiers -band [ConsoleModifiers]::Control)) { return $true }
            }
            return $false
        }
    }
    try {
        $r = Invoke-WithDots '  locking' {
            Set-GuardOwnerSystem -Folder $path -User $script:User | Out-Null
            Lock-GuardTree -Folder $path -User $script:User -Skip @() -ShouldStop $stop
        }
    } finally { if ($null -ne $oldTreat) { try { [Console]::TreatControlCAsInput = $oldTreat } catch { } } }
    if ($r.Stopped) {
        Invoke-WithDots '  undoing' {
            Unlock-GuardTree -Folder $path -User $script:User -KeepAbove:(Test-AboveShared ([pscustomobject]@{ path = $path })) | Out-Null
            Set-GuardOwnerUser -Folder $path -User $script:User | Out-Null
        }
        Say "  cancelled  ·  everything done so far was undone, nothing is locked" 'Yellow'
        return
    }

    $above = Split-Path (Split-Path $path -Parent) -Leaf; if (-not $above) { $above = Split-Path $path -Parent }
    Ok "owner"   ("folder + {0} files" -f $files.Count) "now owned by SYSTEM"
    Ok "locking" "folder" "can't be deleted or renamed"
    Ok "locking" ("folder above ({0})" -f $above) "can't delete inside using the folder key"
    Ok "locking" ("{0} files" -f $r.Locked) "can't be deleted"
    $entry = [pscustomobject]@{ path=$path; name=$name; skip=@(); added=(Get-Date).ToString('o') }
    $script:Cfg.folders += $entry
    $script:Cfg.current = $script:Cfg.folders.Count - 1
    Save-GuardConfig -Config $script:Cfg -User $script:User
    $others = @($script:Cfg.folders | Where-Object { $_.path -ne $path -and (Test-Path -LiteralPath $_.path) }).Count
    $mem = "_guard.json written and locked"
    if ($others -eq 1) { $mem += "  ·  updated in 1 other folder" } elseif ($others -gt 1) { $mem += ("  ·  updated in {0} other folders" -f $others) }
    Ok "memory" $mem
    if ((Get-WatchState).Running) { Wait-WatchSync; Ok "guard" "told about the new folder" }

    # not locked yet: files still being saved, open in a program
    $later = @()
    foreach ($w in $r.Waiting) { $later += [pscustomobject]@{ Reason = $w.Reason; Name = $w.Name } }
    foreach ($x in $files) { if ($x.Name -like '*.crdownload' -or $x.Name -like '*.part') { $later += [pscustomobject]@{ Reason = 'Chrome can still save'; Name = $x.Name } } }
    if ($later.Count -gt 0) {
        Say ""; Say "    not locked yet"
        foreach ($g in ($later | Group-Object Reason)) {
            Say ("    {0}  {1,-34} {2}" -f $g.Count, $g.Name, (($g.Group | ForEach-Object Name) -join ', '))
        }
    }
    Say ""; Say "  Folder is Protected Successfully." 'Green'
    Say ("  path        {0}" -f $path)
    $lk = "  locked      {0} of {1} files" -f $r.Locked, ($files.Count - $r.Skipped)
    if ($hadOthers -gt 0) { $lk += "  ·  switched to this folder" }
    Say $lk
}

function Cmd-Remove($arg) {
    $targets = @()
    if ($arg -eq 'all') { $targets = @($script:Cfg.folders) } else { $c = Cur; if ($c) { $targets = @($c) } }
    if ($targets.Count -eq 0) { Say "  no folder to remove"; return }
    if ($arg -eq 'all') {
        Say ""; Say ("  This stops protecting {0} folders. Nothing is deleted." -f $targets.Count)
        $a = Read-Line "  type YES to continue, anything else to cancel > "
        if ($a -ne 'YES') { Say "  cancelled"; return }
    } else {
        $f = $targets[0]
        $fc = '—'; if (Test-Path -LiteralPath $f.path) { $fc = "{0} files" -f @(Get-GuardFiles -Folder $f.path).Count }
        Say ""; Say ("  {0}  ·  {1}  ·  {2}  ·  files stay, nothing is deleted" -f $f.name, $f.path, $fc)
        if (-not (Confirm-YesNo "Stop protecting this folder?")) { Say "  cancelled"; return }
    }
    Say ""
    $wasCur = Cur
    # forget first, so the background guard doesn't lock it again while we unlock
    $keep = @(); foreach ($f in $script:Cfg.folders) { if ($targets -notcontains $f) { $keep += $f } }
    $script:Cfg.folders = $keep
    $idx = [array]::IndexOf(@($keep), $wasCur)
    if ($idx -ge 0) { $script:Cfg.current = $idx } else { $script:Cfg.current = 0 }
    Save-GuardConfig -Config $script:Cfg -User $script:User
    Wait-WatchSync
    $others = @($keep | Where-Object { Test-Path -LiteralPath $_.path }).Count
    foreach ($f in $targets) {
        if (-not (Test-Path -LiteralPath $f.path)) { Ok "forgot" ("{0}  (not found)" -f $f.path); continue }
        $n = @(Get-GuardFiles -Folder $f.path).Count
        $jp = Join-Path $f.path '_guard.json'
        Invoke-WithDots '  unlocking' {
            Unlock-GuardTree -Folder $f.path -User $script:User -KeepAbove:(Test-AboveShared $f) | Out-Null
            Unlock-GuardFile -Path $jp -User $script:User | Out-Null
            Remove-Item -LiteralPath $jp -Force -EA SilentlyContinue
            Set-GuardOwnerUser -Folder $f.path -User $script:User | Out-Null
        }
        if ($targets.Count -gt 1) { Say ("  {0}" -f $f.name) 'Cyan' }
        Ok "unlocked" ("folder, folder above, {0} files" -f $n)
        Ok "owner" ("folder + {0} files  back to you ({1})" -f $n, ($script:User -split '\\')[-1])
        $m = "_guard.json deleted here"
        if ($others -eq 1) { $m += "  ·  updated in 1 other folder" } elseif ($others -gt 1) { $m += ("  ·  updated in {0} other folders" -f $others) }
        Ok "memory" $m
    }
    Ok "removed" "from guard"
    if ($script:Cfg.folders.Count -gt 0 -and $targets -contains $wasCur) {
        Say ("  switched  to {0} of {1}" -f ($script:Cfg.current + 1), $script:Cfg.folders.Count)
    }
}

function Cmd-Skip($arg) {
    $f = Cur; if (-not $f) { Say "  no folder protected yet" 'Red'; return }
    if (-not $arg) {
        Say ""; Say ("  skip list for {0}  (never locked, can always be deleted)" -f $f.name)
        Say ("    built-in   " + ($script:BuiltinSkip -join '  '))
        $yours = @(Folder-Skip $f); if ($yours.Count -eq 0) { $yours = @('—') }
        Say ("    yours      " + ($yours -join '  '))
        Say  "  skip <pattern>  add  ·  skip all <pattern>  every folder  ·  skip remove <pattern>  take out"
        return
    }
    $parts = $arg -split '\s+', 2
    if ($parts[0] -eq 'remove' -and $parts.Count -eq 2) {
        $p = $parts[1]
        if ($script:BuiltinSkip -contains $p) { Say "  $p is built in and can't be removed" 'Red'; return }
        if (@(Folder-Skip $f) -notcontains $p) { Say ("  {0} is not in the skip list of {1}" -f $p, $f.name) 'Red'; return }
        $f.skip = @(Folder-Skip $f | Where-Object { $_ -ne $p })
        Save-GuardConfig -Config $script:Cfg -User $script:User
        $n = @(Get-GuardFiles -Folder $f.path | Where-Object { $_.Name -like $p }).Count
        Ok "removed" ("{0}  from {1}  ·  {2} matching files lock at the next full check" -f $p, $f.name, $n); return
    }
    if ($parts[0] -eq 'all' -and $parts.Count -eq 2) {
        $p = $parts[1]; $n = 0
        foreach ($x in $script:Cfg.folders) {
            $x.skip = @(@(Folder-Skip $x) + @($p) | Select-Object -Unique)
            if (Test-Path -LiteralPath $x.path) { foreach ($y in (Get-GuardFiles -Folder $x.path)) { if ($y.Name -like $p) { Unlock-GuardFile -Path $y.FullName -User $script:User | Out-Null; $n++ } } }
        }
        Save-GuardConfig -Config $script:Cfg -User $script:User
        Ok "added" ("{0}  to all {1} folders" -f $p, $script:Cfg.folders.Count)
        if ($n) { Ok "unlocked" ("{0} files that match" -f $n) }
        return
    }
    $f.skip = @(@(Folder-Skip $f) + @($arg) | Select-Object -Unique)
    # unlock anything already locked that now matches
    $n = 0
    foreach ($x in (Get-GuardFiles -Folder $f.path)) { if ($x.Name -like $arg) { Unlock-GuardFile -Path $x.FullName -User $script:User | Out-Null; $n++ } }
    Save-GuardConfig -Config $script:Cfg -User $script:User
    Say ""
    Ok "added" ("{0}  to {1}" -f $arg, $f.name)
    if ($n) { Ok "unlocked" ("{0} files that match" -f $n) }
}

function Cmd-Folders {
    Say ""
    if ($script:Cfg.folders.Count -eq 0) { Say "  no folder protected yet"; return }
    for ($i = 0; $i -lt $script:Cfg.folders.Count; $i++) {
        $f = $script:Cfg.folders[$i]; $star = ' '; if ($i -eq $script:Cfg.current) { $star = '*' }
        if (Test-Path -LiteralPath $f.path) {
            $st = 'LOCKED'; if ($f.editing) { $st = 'UNLOCKED' }
            $fc = "{0} files" -f @(Get-GuardFiles -Folder $f.path).Count
            Say (" {0} {1}  {2,-15} {3,-40} {4,-10} {5}" -f $star, ($i+1), $f.name, $f.path, $fc, $st)
        } else {
            Say (" {0} {1}  {2,-15} {3,-40} {4,-10} {5}" -f $star, ($i+1), $f.name, $f.path, '—', 'NOT FOUND') 'Red'
        }
    }
    Say "  type  use <n>  to switch"
}

function Cmd-Use($arg) {
    if ($arg -match '^\d+$') {
        $n = [int]$arg
        if ($n -ge 1 -and $n -le $script:Cfg.folders.Count) { $script:Cfg.current = $n - 1; Save-GuardConfig -Config $script:Cfg -User $script:User; Say "  switched" }
        else { Say ("  no folder {0}  ·  type  folders  to see the numbers" -f $n) 'Red' }
    } else { Say "  use <number>  ·  type  folders  to see the numbers" 'Red' }
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
        $r = Invoke-WithDots ("  locking {0}" -f $f.name) {
            # access first: on a new Windows the old account is a stranger, even with the same name
            Set-GuardOwnerSystem -Folder $f.path -User $script:User | Out-Null
            Lock-GuardTree -Folder $f.path -User $script:User -Skip (Folder-Skip $f)
        }
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
    Say ""; if ($found.Count -eq 1) { Say "  Folder is Protected Successfully." 'Green' } else { Say ("  {0} Folders are Protected Successfully." -f $found.Count) 'Green' }
    return $true
}

# ---- help -----------------------------------------------------------------
# The start table as data, for the help list under  guard> help  + Tab: heading, row as the
# table shows it, and the  help  topic that row opens.
$script:TableHeads = @{
    'guard'   = '-------------------- Guard ---------------------'
    'all'     = '------------ All protected folders -------------'
    'current' = '---------------- Current folder ----------------'
}
$script:TableRows = @(
    @('guard', 'folders', 'folders', 'show all protected folders'),
    @('guard', 'use', 'use <n>', 'switch to folder n'),
    @('guard', 'init', 'init', 'protect the folder the terminal is in'),
    @('guard', 'init', 'init <path>', 'protect the folder at path'),
    @('guard', 'update', 'update', 'install the newest guard'),
    @('guard', 'cls', 'cls', 'clear screen'),
    @('guard', 'help', 'help <command>', 'explain a command'),
    @('guard', 'all', 'help all', 'explain every command'),
    @('guard', 'uninstall', 'uninstall', 'remove guard'),
    @('guard', 'exit', 'exit', 'close guard'),
    @('all', 'edit', 'edit all', 'unlock every folder'),
    @('all', 'resume', 'resume all', 'lock every folder'),
    @('all', 'remove', 'remove all', 'stop protecting every folder'),
    @('all', 'skip', 'skip all <pattern>', 'add files that are never locked, in every folder'),
    @('current', 'list', 'list', 'show files and folders'),
    @('current', 'delete', 'delete <name>', 'delete files or folders'),
    @('current', 'delete', 'delete all', 'delete everything in the folder'),
    @('current', 'move', 'move <name>', 'copy or cut files or folders'),
    @('current', 'move', 'move all', 'copy or cut everything in the folder'),
    @('current', 'move', 'move folder', 'move the protected folder somewhere else'),
    @('current', 'edit', 'edit', 'unlock the folder'),
    @('current', 'resume', 'resume', 'lock the folder'),
    @('current', 'remove', 'remove', 'stop protecting the folder'),
    @('current', 'skip', 'skip', 'show files that are never locked'),
    @('current', 'skip', 'skip <pattern>', 'add files that are never locked'),
    @('current', 'skip', 'skip remove <pattern>', 'take a pattern out')
)

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
Removes the lock from the folder, the folder above and every file, and opens
the folder in Explorer. Save from Word, Excel, Photoshop, rename, delete, all
work. The background guard stops
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
Stops protecting the current folder, after one yes / no question. The lock
comes off, you become the owner again, normal permissions come back, and its
_guard.json is deleted. Files are not touched. remove all does every folder
and needs  YES.
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
function Show-HelpTable {
    $t = @"

  -------------------- Guard ---------------------

  folders                 list protected folders with their numbers · * marks the current one
  use <n>                 make folder number n the current one · numbers come from folders
  init                    protect the folder the terminal is in · no question asked · locks folder, folder above, every file
  init <path>             same, for the folder at path
  update                  install the newest guard from GitHub · protected folders untouched
  cls                     clear the screen and show the command table and every folder's status again
  help <command>          longer explanation of one command
  help all                longer explanation of every command
  uninstall               remove guard from this PC · unlocks everything, removes the background guard · files stay on the disk
  exit                    close the guard window · protection keeps running in the background

  ------------ All protected folders -------------

  edit all                unlock every protected folder · locks again at next logon or with resume all
  resume all              lock every protected folder now
  remove all              stop protecting every folder · type YES · files stay on the disk
  skip all <pattern>      add a never-locked pattern to every protected folder

  ---------------- Current folder ----------------

  list                    show files and folders in the current folder, newest first, with date and size
  delete <name>           delete files or folders · matches by part of the name · picker if many · always asks first
  delete all              delete everything in the folder · type YES
  move <name>             copy or cut files or folders · same picking as delete · asks where to, then cut or copy
  move all                copy or cut everything in the folder · type YES
  move folder             move the protected folder itself to a new path · stays protected there
  edit                    unlock the folder and open it in Explorer · save, rename, delete work · locks again at next logon or with resume
  resume                  lock the folder again now · also happens by itself at every logon
  remove                  stop protecting the folder · files stay on the disk, just not protected
  skip                    show files that are never locked and can always be deleted (temp files)
  skip <pattern>          add a pattern, e.g. skip *.bak
  skip remove <pattern>   take a pattern out · built-in ones can't be removed

"@
    Say $t
}

function Show-Help([string]$what) {
    $what = $what.Trim().ToLower()
    if (-not $what) { Show-HelpTable; return }
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
function Hide-Paths([string]$t) {
    # the report never carries file or folder names: C:\Users\me\Tax\x.pdf -> <path>
    return ($t -replace '[A-Za-z]:\\[^\s"''<>|]*', '<path>' -replace '\\\\[^\s"''<>|]+', '<path>')
}

function New-GuardIssueUrl([string]$Command, [string]$Message, [string]$Where) {
    # A pre-filled GitHub issue. Opens in the browser; nothing is sent until the user submits it.
    # Only: guard version, the command word, Windows and PowerShell versions, the error line.
    $os = [Environment]::OSVersion.Version
    $word = (($Command.Trim() -split '\s+')[0])
    $Message = Hide-Paths $Message; $Where = Hide-Paths $Where
    $body = @"
**Command**
``$word``

**Error**
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
    $v = Invoke-WithDots '  checking for a new version' { Get-GuardRemoteVersion }
    if (-not $v) { Say "  can't reach GitHub right now. try again later." 'Red'; return $true }
    if (-not (Test-GuardNewer $v)) { Say ("  you have the newest version ({0})" -f $script:GuardVersion); return $true }
    $tmp = Join-Path $env:TEMP ('guard-install-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $text = Invoke-WithDots '  downloading' { try { Get-GuardSourceText 'install.ps1' } catch { $null } }
    if (-not $text) { Say "  download failed. check the internet connection and try again." 'Red'; return $true }
    try { [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding($true))) }
    catch { Say "  download failed: $($_.Exception.Message)" 'Red'; return $true }
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
    Invoke-WithDots '  stopping the background guard' { Stop-GuardWatch -Dir $script:InstallDir | Out-Null }
    # 2 give every folder back
    foreach ($f in $folders) {
        if (-not (Test-Path -LiteralPath $f.path)) { Ok "skipped" ("{0}  (not found)" -f $f.path); continue }
        $c = @(Get-GuardFiles -Folder $f.path).Count
        Invoke-WithDots ("  unlocking {0}" -f $f.name) {
            Unlock-GuardTree -Folder $f.path -User $script:User | Out-Null
            Unlock-GuardFile -Path (Join-Path $f.path '_guard.json') -User $script:User | Out-Null
            Set-GuardOwnerUser -Folder $f.path -User $script:User | Out-Null
        }
        Ok "unlocked" ("{0}  ({1} files)  owner back to you" -f $f.path, $c)
    }
    if ($folders.Count) { Ok "kept" "_guard.json in every folder (memory, so a future install can restore)" }
    # 3 task, path, program, data
    try { Unregister-ScheduledTask -TaskName $script:GuardTask -Confirm:$false -ErrorAction Stop; Ok "removed" ("task `"{0}`"" -f $script:GuardTask) } catch { Ok "removed" "task (was not there)" }
    try {
        # raw registry value: keeps %SystemRoot% etc. as they are (REG_EXPAND_SZ)
        if (Remove-GuardMachinePath $script:InstallDir) { Ok "removed" "path entry" } else { Ok "removed" "path entry (was not there)" }
    } catch { Say "  FAIL  path: $($_.Exception.Message)" 'Red' }
    # guard.cmd is still running (it started us): remove it and the folder 2 s after guard
    # closes, or Windows prints "The system cannot find the path specified."
    $later = @(); $shimGone = $false
    $dir = $script:InstallDir.TrimEnd('\')
    if (Test-GuardShimFor $dir) { $later += "del /f /q `"$(Get-GuardShimPath)`""; $shimGone = $true }
    # only delete a real install folder (has guard.cmd), never a source checkout
    if (Test-Path -LiteralPath (Join-Path $dir 'guard.cmd')) { $later += "rd /s /q `"$dir`"" }
    if ($later.Count) { Start-Process cmd.exe -WindowStyle Hidden -ArgumentList ("/c ping -n 3 127.0.0.1 >nul & " + ($later -join ' & ')) }
    if ($shimGone) { Ok "removed" (Get-GuardShimPath) }
    if (Test-Path -LiteralPath (Join-Path $dir 'guard.cmd')) { Ok "removed" $dir }
    $data = Split-Path $script:GuardConfigPath -Parent
    Remove-Item -LiteralPath $data -Recurse -Force -EA SilentlyContinue
    Ok "removed" $data
    Say ""
    Say "  Guard is Uninstalled Successfully." 'Green'
    return $false
}

# ---- lines under the status block -----------------------------------------
function Show-NextLines($w) {
    # 'update' and 'next' under the status block; 'next' only when something needs you
    if (-not $w) { $w = Get-WatchState }
    $s = Read-WatchStatus
    $printed = $false
    if ($s -and (Test-GuardNewer $s.latest)) {
        Say "update    New version is available. Type  update  to keep guard up to date." 'Yellow'; $printed = $true
    }
    $next = $null
    if ($script:Cfg.folders.Count -eq 0) { $next = 'init / init <path>' }
    else {
        # the first folder with a problem; the current one is checked first
        $order = @($script:Cfg.current) + @(0..($script:Cfg.folders.Count - 1) | Where-Object { $_ -ne $script:Cfg.current })
        foreach ($i in $order) {
            $f = $script:Cfg.folders[$i]
            $isCur = ($i -eq $script:Cfg.current)
            $pre = ''; if (-not $isCur) { $pre = "type  use $($i+1)  then  " }
            $st = $null; if ($script:FolderStates) { $st = $script:FolderStates[$f.path] }
            if (-not $st) { $st = Get-FolderState $f }
            if (-not $st.Exists) { $next = "${pre}remove  to forget it  /  init <new path>"; break }
            if ($st.Editing) { $next = "${pre}resume  when done"; break }
            if (-not $w.Running) {
                if ($st.Missing -gt 0) { $next = ("{0}resume   (locks the {1} files and restarts the background guard)" -f $pre, $st.Missing) }
                else { $next = "${pre}resume   (restarts the background guard)" }
                break
            }
        }
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
        'cls'       { Clear-Host; Show-Table; $script:ShowAll = $true }
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
