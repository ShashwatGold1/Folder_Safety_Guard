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
    [switch]$Pause                  # keep the UAC window open at the end
)

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$dot = [string][char]0x00B7; $arrow = [string][char]0x2192
$ErrorActionPreference = 'Stop'
$repo = 'https://raw.githubusercontent.com/ShashwatGold1/Folder_Safety_Guard/main'
$runtime = @('guard.ps1','guard-shell.ps1','guard-core.ps1','guard-config.ps1','guard-watch.ps1')
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
$script:BarTop = -1; $script:BarWhat = 'installing'; $script:StepN = 0; $script:StepTotal = 8
function Bar-Text([int]$n) {
    $w = 30; $fill = [int]($w * $n / $script:StepTotal)
    return ("guard  {0}   [{1}]  {2,3}%   {3}/{4}" -f $script:BarWhat, (('=' * $fill) + ('-' * ($w - $fill))), [int](100*$n/$script:StepTotal), $n, $script:StepTotal)
}
function Bar-Start {
    Write-Host ""
    try { if (-not [Console]::IsOutputRedirected) { $script:BarTop = [Console]::CursorTop } } catch { $script:BarTop = -1 }
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
function StepOk([string]$name,[string]$detail){ Write-Host ("  ok    {0,-9}  {1}" -f $name,$detail) -ForegroundColor Green; $script:StepN++; Bar-Set }
function StepFail([string]$name,[string]$detail){ Write-Host ("  FAIL  {0,-9}  {1}" -f $name,$detail) -ForegroundColor Red }
function Done-Pause { if ($Pause) { Write-Host ""; Read-Host "  press Enter to close" | Out-Null } }
function Fail-Out([string]$problem,[string]$fix) {
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
$who = $ForUser; if (-not $who) { $who = [Security.Principal.WindowsIdentity]::GetCurrent().Name }
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
    $a = "-NoProfile -ExecutionPolicy Bypass -File `"$self`" -Pause -ForUser `"$who`" -Prefix `"$Prefix`""
    if ($Source) { $a += " -Source `"$Source`"" }
    Write-Host "guard  asking for administrator (UAC)..."
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList $a }
    catch { Write-Host "guard  not installed: the administrator prompt was cancelled." -ForegroundColor Red }
    return
}

$u = $ForUser; if (-not $u) { $u = [Security.Principal.WindowsIdentity]::GetCurrent().Name }
if ($Update) {
    $f = $From; if (-not $f) { $f = '?' }; $t2 = $To; if (-not $t2) { $t2 = 'new' }
    $script:BarWhat = "updating $f $arrow $t2"
}
Bar-Start

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
$ErrorActionPreference = 'Stop'
$script:User = $u

# 5 path: the raw registry value, so %SystemRoot% and other %VAR% entries stay as they are
try {
    if (Add-GuardMachinePath $Prefix) { StepOk 'path' 'added for all users' } else { StepOk 'path' 'already there' }
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

# 8 memory: an earlier install's folders (fresh install only)
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
if ($Update) { Write-Host "  updated successfully." -ForegroundColor Green; Done-Pause; return }
Write-Host "  installed successfully." -ForegroundColor Green

if ($restoreFrom) {
    $script:Cfg = New-GuardConfig
    $ok = Invoke-GuardRestore -Memory $restoreFrom -Where $script:MemoryFoundIn
    # start fresh = write an empty config, so guard doesn't silently rebuild from the old memory later
    if (-not $ok) { Save-GuardConfig -Config $script:Cfg -User $u }
    Write-Host ""
}
Write-Host -NoNewline "  open a new terminal and type:  "; Write-Host "guard" -ForegroundColor Cyan
Done-Pause
