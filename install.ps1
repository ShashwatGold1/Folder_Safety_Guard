# install.ps1 - sets guard up, or updates it in place. Admin required.
# Keep this file pure ASCII with NO BOM: run through  irm | iex  a BOM arrives as a stray
# character before param(...) and the script no longer parses. Non-ASCII output is built
# from char codes ($dot, $arrow) instead.
#   irm https://raw.githubusercontent.com/ShashwatGold1/Folder_Safety_Guard/main/install.ps1 | iex
param(
    [string]$Prefix = 'C:\Program Files\guard',
    [string]$Source = '',           # local folder with the src files (tests); blank = GitHub
    [switch]$NoTask,                # skip the scheduled task (tests)
    [switch]$NoElevate,             # tests / already elevated
    [string]$ForUser = '',          # which account to protect for; blank = the signed-in user
    [switch]$Update,                # called by  guard> update
    [string]$From = '',             # old version, for the update header
    [string]$To = '',               # new version, for the update header
    [switch]$Pause,                 # keep a window of its own open at the end
    [int]$AttachTo = 0,             # the elevated copy, started hidden: moves into the caller's window
    [switch]$Granted,               # set after the UAC click: say so before the progress bar
    [int]$Caller = 0                # the waiting window's pid: told when that line is about to print
)

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$dot = [string][char]0x00B7; $arrow = [string][char]0x2192
$ErrorActionPreference = 'Stop'
$repo = 'https://raw.githubusercontent.com/ShashwatGold1/Folder_Safety_Guard/main'
$runtime = @('guard.ps1','guard-shell.ps1','guard-core.ps1','guard-config.ps1','guard-watch.ps1','guard-badges.ps1')
function Is-Admin { $id=[Security.Principal.WindowsIdentity]::GetCurrent(); (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }

# Test overrides from the environment only when they can't help an attacker: in a process
# without admin, or when an admin set GUARD_TEST=1 machine-wide (see Test-GuardTestMode).
# A limited agent can setx user env vars that this elevated installer would inherit.
function Test-InstallTestMode {
    if (-not (Is-Admin)) { return $true }
    try {
        $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment')
        try { return ([string]$k.GetValue('GUARD_TEST', '') -eq '1') } finally { $k.Close() }
    } catch { return $false }
}
$taskName = 'guard'
if (Test-InstallTestMode) {
    if ($env:GUARD_TASK) { $taskName = $env:GUARD_TASK }
    if (-not $Source -and $env:GUARD_SOURCE) { $Source = $env:GUARD_SOURCE }
}
# progress bar on top, redrawn in place after every step (plain lines when output is redirected)
$script:BarTop = -1; $script:BarWhat = 'installing'; $script:StepN = 0; $script:StepTotal = 9
$script:StepNames = @('check','uac','folder','files','path','task','guard','badges','memory'); $script:BarTail = ''
function Bar-Text([int]$n) {
    $w = 30; $fill = [int]($w * $n / $script:StepTotal)
    return ("guard  {0}   [{1}]  {2,3}%   {3}/{4}{5}" -f $script:BarWhat, (('=' * $fill) + ('-' * ($w - $fill))), [int](100*$n/$script:StepTotal), $n, $script:StepTotal, $script:BarTail)
}
function Bar-Start {
    Write-Host ""
    try {
        if (-not [Console]::IsOutputRedirected -and [Console]::WindowHeight -ge 15) {
            # make room first: in Windows Terminal the buffer is only as tall as the window, and
            # output that scrolls the window would leave the bar redrawing on the wrong line
            Write-Host -NoNewline ("`n" * 13)
            [Console]::SetCursorPosition(0, [Console]::CursorTop - 13)
            $script:BarTop = [Console]::CursorTop
        }
    } catch { $script:BarTop = -1 }
    if ($script:BarTop -ge 0) { Write-Host (Bar-Text 0) }
    Write-Host ""
}
function Bar-Set {
    if ($script:BarTop -lt 0) { return }
    try {
        $l = [Console]::CursorLeft; $t = [Console]::CursorTop
        [Console]::SetCursorPosition(0, $script:BarTop); Write-Host -NoNewline (Bar-Text $script:StepN)
        [Console]::SetCursorPosition($l, $t)
    } catch { $script:BarTop = -1 }
}
function Bar-End {
    # redirected output (tests, logs): the bar once, at the end
    if ($script:BarTop -lt 0) { Write-Host ""; Write-Host (Bar-Text $script:StepTotal) }
}
# while a step runs, its row shows moving dots ("  ..    memory     ...") instead of a bare cursor
$script:StepDots = $null
function Step-Dots {
    Stop-InstallDots $script:StepDots; $script:StepDots = $null
    if ($script:StepN -lt $script:StepNames.Count) { $script:StepDots = Start-InstallDots ("{0}  ..    {1,-9}  " -f $script:M, $script:StepNames[$script:StepN]) }
}
function StepOk([string]$name,[string]$detail){
    Stop-InstallDots $script:StepDots; $script:StepDots = $null
    Write-Host ("  ok    {0,-9}  {1}" -f $name,$detail) -ForegroundColor Green; $script:StepN++; Bar-Set
    Step-Dots
}
function StepFail([string]$name,[string]$detail){
    Stop-InstallDots $script:StepDots; $script:StepDots = $null
    Write-Host ("  FAIL  {0,-9}  {1}" -f $name,$detail) -ForegroundColor Red
}
function Done-Pause { if ($Pause) { Write-Host ""; Read-Host "  press Enter to close" | Out-Null } }
function Fail-Out([string]$problem,[string]$fix) {
    # the failed step is number StepN+1: every step after it is skipped
    for ($i = $script:StepN + 1; $i -lt $script:StepNames.Count; $i++) { Write-Host ("  --    {0,-9}  skipped" -f $script:StepNames[$i]) -ForegroundColor DarkGray }
    $script:BarTail = '   stopped'
    if ($script:BarTop -ge 0) { Bar-Set } else { Write-Host ""; Write-Host (Bar-Text $script:StepN) }
    Write-Host ""
    Write-Host "  not installed.  do the fix below and try again." -ForegroundColor Red
    Write-Host "  problem   $problem"
    Write-Host "  fix       $fix"
    Done-Pause
}

# --- run from a file, elevated -----------------------------------------------
# Through  irm | iex  there is no file, and the code would run inside the user's own terminal
# session (leaving guard's functions and settings behind in it). So: save ourselves to a temp
# file first, then run that in its own process - elevated through UAC if needed.
$self = $MyInvocation.MyCommand.Path
# irm | iex inside someone's own script reports THAT script as our path: then there's no file either
if ($self -and -not (Select-String -LiteralPath $self -SimpleMatch '# install.ps1 - sets guard up' -Quiet)) { $self = $null }
$who = $ForUser; if (-not $who) { $who = [Security.Principal.WindowsIdentity]::GetCurrent().Name }

# One space of margin on the left of every line, like inside guard (same as guard-shell.ps1).
# Only when run from the file: through  irm | iex  this would replace Write-Host in the user's
# own session. Real console only; tests and logs get plain text.
$script:InstallMargin = $false
if ($self) { try { $script:InstallMargin = -not [Console]::IsOutputRedirected } catch { } }
if ($script:InstallMargin) {
    function Write-Host {
        param([Parameter(Position = 0, ValueFromRemainingArguments = $true)][object[]]$Object,
              [switch]$NoNewline, [object]$Separator = ' ', [ConsoleColor]$ForegroundColor, [ConsoleColor]$BackgroundColor)
        $p = @{}
        foreach ($k in 'NoNewline', 'ForegroundColor', 'BackgroundColor') { if ($PSBoundParameters.ContainsKey($k)) { $p[$k] = $PSBoundParameters[$k] } }
        $text = (@($Object) | ForEach-Object { "$_" }) -join [string]$Separator
        try {
            if ([Console]::CursorLeft -eq 0) { $text = ' ' + $text }
            $text = $text -replace "`n", "`n "
        } catch { }
        Microsoft.PowerShell.Utility\Write-Host $text @p
    }
}
$script:M = ''; if ($script:InstallMargin) { $script:M = ' ' }   # for text written past Write-Host

function Join-CallerConsole([int]$CallerPid) {
    # leave our own hidden console and use the caller's window instead (same as  sudo  inline)
    try {
        Add-Type -Namespace GuardCon -Name K -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern bool FreeConsole();
[DllImport("kernel32.dll")] public static extern bool AttachConsole(int pid);
[DllImport("kernel32.dll")] public static extern bool SetConsoleCtrlHandler(System.IntPtr h, bool add);
[DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr CreateFile(string name, uint access, uint share, System.IntPtr sa, uint mode, uint flags, System.IntPtr tmpl);
[DllImport("kernel32.dll")] public static extern bool SetHandleInformation(System.IntPtr h, uint mask, uint flags);
[DllImport("kernel32.dll")] public static extern bool SetStdHandle(int which, System.IntPtr h);
'@
        [void][GuardCon.K]::FreeConsole()
        if (-not [GuardCon.K]::AttachConsole($CallerPid)) { return $false }
        # Ctrl+C must not kill this relay: the caller would return to its prompt mid-install
        [void][GuardCon.K]::SetConsoleCtrlHandler([IntPtr]::Zero, $true)
        $in  = [GuardCon.K]::CreateFile('CONIN$',  [uint32]3221225472, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
        $out = [GuardCon.K]::CreateFile('CONOUT$', [uint32]3221225472, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
        foreach ($h in $in, $out) { [void][GuardCon.K]::SetHandleInformation($h, 1, 1) }   # inheritable
        [void][GuardCon.K]::SetStdHandle(-10, $in); [void][GuardCon.K]::SetStdHandle(-11, $out); [void][GuardCon.K]::SetStdHandle(-12, $out)
        return $true
    } catch { return $false }
}

# loading dots: "text." "text.." "text..." from a background thread, cursor hidden meanwhile.
# Own names: guard-shell.ps1 (dot-sourced later) has its own Start-GuardDots. $Text includes the margin.
function Start-InstallDots([string]$Text) {
    try { if ([Console]::IsOutputRedirected) { return $null } } catch { return $null }
    try { [Console]::CursorVisible = $false } catch { }
    $sync = [hashtable]::Synchronized(@{ Stop = $false })
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript({
        param($t, $s)
        $n = 0
        while (-not $s.Stop) {
            $n = $n % 3 + 1
            [Console]::Write("`r" + $t + ('.' * $n) + (' ' * (3 - $n)) + "`r" + $t + ('.' * $n))
            for ($i = 0; $i -lt 4 -and -not $s.Stop; $i++) { Start-Sleep -Milliseconds 100 }
        }
    }).AddArgument($Text).AddArgument($sync)
    return @{ PS = $ps; Sync = $sync; Run = $ps.BeginInvoke(); Text = $Text }
}
function Stop-InstallDots($h, [switch]$Keep) {
    if (-not $h) { return }
    $h.Sync.Stop = $true
    try { [void]$h.PS.EndInvoke($h.Run) } catch { }
    $h.PS.Dispose()
    if ($Keep) { [Console]::WriteLine("`r" + $h.Text + '...') }
    else { [Console]::Write("`r" + (' ' * ($h.Text.Length + 3)) + "`r") }
    try { [Console]::CursorVisible = $true } catch { }
}
function Request-GuardAdmin([string]$Text, [string]$ArgList) {
    # the UAC prompt with moving dots until the admin copy is about to print here; $null = No
    $ready = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, "Local\guard-ready-$PID")
    $shown = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, "Local\guard-shown-$PID")
    $dots = Start-InstallDots $Text
    if (-not $dots) { Write-Host ($Text + '...') }
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript({ param($a) try { Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -PassThru -ArgumentList $a } catch { } }).AddArgument($ArgList)
    $run = $ps.BeginInvoke()
    $p = $null; $t0 = $null
    try {
        while ($true) {
            if ($null -eq $t0 -and $run.IsCompleted) {
                $p = @($ps.EndInvoke($run)) | Select-Object -First 1
                if (-not $p) { break }
                $t0 = Get-Date
            }
            if ($ready.WaitOne(100)) { break }
            if ($p -and ($p.HasExited -or ((Get-Date) - $t0).TotalSeconds -gt 20)) { break }
        }
    } finally {
        Stop-InstallDots $dots -Keep
        [void]$shown.Set()
        $ps.Dispose()
    }
    return $p
}
function Wait-GuardCallerDots([int]$CallerPid) {
    # admin copy: let the waiting window end its "Requesting Admin Access..." line first
    if (-not $CallerPid) { return }
    try {
        $shown = [Threading.EventWaitHandle]::OpenExisting("Local\guard-shown-$CallerPid")
        $ready = [Threading.EventWaitHandle]::OpenExisting("Local\guard-ready-$CallerPid")
        [void]$ready.Set(); [void]$shown.WaitOne(3000)
    } catch { }
}

if ($AttachTo) {
    $fwd = "-NoProfile -ExecutionPolicy Bypass -File `"$self`" -Granted -Caller $AttachTo -ForUser `"$who`" -Prefix `"$Prefix`""
    if ($Source) { $fwd += " -Source `"$Source`"" }
    if (Join-CallerConsole $AttachTo) {
        $si = New-Object Diagnostics.ProcessStartInfo 'powershell.exe', $fwd
        $si.UseShellExecute = $false        # inherits the caller's window
        $p = [Diagnostics.Process]::Start($si); $p.WaitForExit(); exit $p.ExitCode
    }
    Start-Process powershell.exe -ArgumentList "$fwd -Pause"
    exit
}
if (-not $self) {
    $self = Join-Path $env:TEMP 'guard-install.ps1'
    $text = $null
    if ($Source) { $text = Get-Content (Join-Path (Split-Path $Source -Parent) 'install.ps1') -Raw -Encoding UTF8 }
    else { $text = (Invoke-WebRequest "$repo/install.ps1" -UseBasicParsing).Content }
    [IO.File]::WriteAllText($self, $text.TrimStart([char]0xFEFF), (New-Object Text.UTF8Encoding($false)))
    if ((Is-Admin) -or $NoElevate) {
        $fwd = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $self, '-ForUser', $who, '-Prefix', $Prefix)
        if ($Source) { $fwd += @('-Source', $Source) }
        if ($NoElevate) { $fwd += '-NoElevate' }
        & powershell.exe @fwd
        return
    }
}
if (-not (Is-Admin) -and -not $NoElevate) {
    $a = "-NoProfile -ExecutionPolicy Bypass -File `"$self`" -AttachTo $PID -ForUser `"$who`" -Prefix `"$Prefix`""
    if ($Source) { $a += " -Source `"$Source`"" }
    Write-Host ""
    $enc = [Console]::OutputEncoding
    # hidden: it moves into this window, and this one waits until the install is done
    # (this part runs inside the user's own session through  irm | iex: no Write-Host margin
    # wrapper here, so the one-space margin is typed in)
    $p = Request-GuardAdmin ' Requesting Admin Access' $a
    if (-not $p) { Write-Host " guard  not installed: the administrator prompt was cancelled." -ForegroundColor Red; Write-Host ""; return }
    $p.WaitForExit()
    try { [Console]::OutputEncoding = $enc } catch { }
    return
}

$u = $ForUser; if (-not $u) { $u = [Security.Principal.WindowsIdentity]::GetCurrent().Name }
if ($Update) {
    $f = $From; if (-not $f) { $f = '?' }; $t2 = $To; if (-not $t2) { $t2 = 'new' }
    $script:BarWhat = "updating $f $arrow $t2"
    $script:StepNames[8] = 'folders'   # an update's last row (and its dots) checks the folders
}
# right under "Requesting Admin Access..." in the same window; Bar-Start adds the blank line after
if ($Granted) { Wait-GuardCallerDots $Caller; Write-Host "Admin Access Granted Successfully." -ForegroundColor Green }
Bar-Start
Step-Dots

# 1 check
if ($PSVersionTable.PSVersion.Major -lt 5) { StepFail 'check' 'needs PowerShell 5 or newer'; Fail-Out 'PowerShell is too old' 'install Windows Management Framework 5.1, then run the install line again'; return }
$win = 'Windows 10'; if ([Environment]::OSVersion.Version.Build -ge 22000) { $win = 'Windows 11' }
StepOk 'check' ("PowerShell {0}.{1}  $dot  {2}  $dot  user {3}" -f $PSVersionTable.PSVersion.Major, $PSVersionTable.PSVersion.Minor, $win, ($u -split '\\')[-1])

# 2 uac
$uac = 1; try { $uac = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System').EnableLUA } catch {}
if ($uac -ne 1) {
    StepFail 'uac' 'User Account Control is turned off'
    Fail-Out 'UAC is off. Any program could unlock protected files without a prompt.' ("1. Win+R, type  UserAccountControlSettings`n" + "            2. move the slider to the default notch or higher, OK, restart`n" + "            3. run the install line again")
    return
}
StepOk 'uac' "on  $dot  admin rights granted"

# 3 folder
try {
    if (Test-Path $Prefix) { StepOk 'folder' ("{0}  (already there)" -f $Prefix) }
    else { New-Item -ItemType Directory -Path $Prefix -Force | Out-Null; StepOk 'folder' $Prefix }
} catch { StepFail 'folder' $_.Exception.Message; Fail-Out "can't create $Prefix" 'check the disk is not full, then run the install line again'; return }

# 4 files (stop the old background guard first: it has these files open)
try {
    $old = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -EA SilentlyContinue | Where-Object { $_.CommandLine -like "*$Prefix\guard-watch.ps1*" }
    try { Stop-ScheduledTask -TaskName $taskName -EA Stop } catch { }
    foreach ($p in $old) { try { Stop-Process -Id $p.ProcessId -Force -EA Stop } catch { } }
    $bom = New-Object Text.UTF8Encoding($true)
    $changed = 0
    foreach ($fn in $runtime) {
        # (-Source reads the raw bytes so a BOM arrives exactly as in a download: tests hit the same path)
        if ($Source) { $text = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path $Source $fn))) }
        else { $text = (Invoke-WebRequest "$repo/src/$fn" -UseBasicParsing).Content }
        # a download keeps the file's BOM as a first character; WriteAllText adds one -> two BOMs,
        # and PowerShell then fails on the stray one. Strip it here.
        $text = $text.TrimStart([char]0xFEFF)
        $dest = Join-Path $Prefix $fn
        $before = $null; if (Test-Path $dest) { $before = Get-Content -LiteralPath $dest -Raw -Encoding UTF8 }
        if ($before -ne $text) { $changed++ }
        [IO.File]::WriteAllText($dest, $text, $bom)     # BOM: PowerShell 5.1 reads it as UTF-8
    }
    $cmd = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"$Prefix\guard.ps1`" %*`r`n"
    $cmdPath = Join-Path $Prefix 'guard.cmd'
    $cmdSame = (Test-Path $cmdPath) -and ((Get-Content $cmdPath -Raw) -eq $cmd)
    if (-not $cmdSame) { [IO.File]::WriteAllText($cmdPath, $cmd, (New-Object Text.ASCIIEncoding)) }
    if ($Update) { StepOk 'files' ("{0} of {1} files updated  $dot  guard.cmd {2}" -f $changed, $runtime.Count, $(if ($cmdSame) {'same'} else {'updated'})) }
    else { StepOk 'files' "guard.ps1  $dot  guard.cmd  $dot  modules" }
} catch { StepFail 'files' $_.Exception.Message; Fail-Out "couldn't get the guard files" 'check the internet connection, then run the install line again'; return }

# from here on, guard's own code does the work (PATH, memory, restore)
. "$Prefix\guard-shell.ps1"
$script:GuardMargin = $script:InstallMargin   # guard's Write-Host (now in charge): same margin
$ErrorActionPreference = 'Stop'
$script:User = $u

# 5 path: the raw registry value, so %SystemRoot% and other %VAR% entries stay as they are
try {
    # + C:\Windows\guard.cmd, so  guard  also works in this window and others already open
    $shim = Add-GuardShim $Prefix
    if (Add-GuardMachinePath $Prefix) { StepOk 'path' 'added for all users' } elseif ($shim) { StepOk 'path' 'added for open terminals too' } else { StepOk 'path' 'already there' }
} catch { StepFail 'path' $_.Exception.Message; Fail-Out "couldn't add guard to PATH" 'run the install line again'; return }

# 6 task
if ($NoTask) { StepOk 'task' 'skipped (test)' } else {
    try {
        $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Prefix\guard-watch.ps1`" -User `"$u`""
        $trg = New-ScheduledTaskTrigger -AtLogOn
        $pr  = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $taskName -Action $act -Trigger $trg -Principal $pr -Settings $set -Force | Out-Null
        StepOk 'task' ("`"{0}`"  $dot  runs as SYSTEM  $dot  at logon  $dot  hidden  $dot  restarts itself if it stops" -f $taskName)
    } catch { StepFail 'task' $_.Exception.Message; Fail-Out "couldn't create the background task" 'run the install line again'; return }
}

# 7 guard (start the background guard now)
try {
    if ($NoTask) {
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$Prefix\guard-watch.ps1`" -User `"$u`""
    } else { Start-ScheduledTask -TaskName $taskName }
    if ($Update) { StepOk 'guard' 'background guard restarted' } else { StepOk 'guard' 'background guard running' }
} catch { StepFail 'guard' $_.Exception.Message }

# 8 badges: green / orange / red marks in Explorer on protected folders and files. Not needed
#   for protection: a failure here is reported and the install goes on.
if (Test-InstallTestMode) { StepOk 'badges' 'skipped (test)' } else {
    try {
        $b = Install-GuardBadges -Dir $Prefix
        if (Test-Path -LiteralPath $script:GuardConfigPath) { Write-GuardBadges -Config (Read-GuardJson -Path $script:GuardConfigPath) }
        if ($b -eq 'new') { Restart-GuardExplorer; StepOk 'badges' "shown in Explorer  $dot  Explorer restarted once to load them" }
        else { StepOk 'badges' 'shown in Explorer  (already there)' }
    } catch { StepFail 'badges' ("not shown: {0}" -f $_.Exception.Message); $script:StepN++; Bar-Set; Step-Dots }
}

# 9 memory: an earlier install's folders (fresh install only)
$restoreFrom = $null
if ($Update) {
    $c = Load-GuardConfig
    $n = 0; foreach ($f in $c.folders) { if (Test-Path -LiteralPath $f.path) { $n += @(Get-GuardFiles -Folder $f.path).Count } }
    StepOk 'folders' ("{0} protected folders untouched  $dot  {1} files still locked" -f @($c.folders).Count, $n)
} elseif (Test-Path -LiteralPath $script:GuardConfigPath) {
    StepOk 'memory' 'config.json already there'
} else {
    $mem = Find-GuardMemory
    if ($mem -and @($mem.folders).Count) { $restoreFrom = $mem; StepOk 'memory' ("found in {0}  $dot  lists {1} folders" -f $script:MemoryFoundIn, @($mem.folders).Count) }
    else {
        # write an empty config now: the background guard then never has to search the disks
        Save-GuardConfig -Config (New-GuardConfig) -User $u
        StepOk 'memory' 'nothing from an earlier install'
    }
}

Bar-End
Write-Host ""
if ($Update) { Write-Host "  Guard is Updated Successfully." -ForegroundColor Green; Write-Host "  type:  " -NoNewline; Write-Host "guard" -ForegroundColor Cyan; Done-Pause; return }
Write-Host "  Guard is Installed Successfully." -ForegroundColor Green

if ($restoreFrom) {
    $script:Cfg = New-GuardConfig
    $ok = Invoke-GuardRestore -Memory $restoreFrom -Where $script:MemoryFoundIn
    # start fresh = write an empty config, so guard doesn't silently rebuild from the old memory later
    if (-not $ok) { Save-GuardConfig -Config $script:Cfg -User $u }
    Write-Host ""
}
Write-Host -NoNewline "  type:  "; Write-Host "guard" -ForegroundColor Cyan
Done-Pause
