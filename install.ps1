# install.ps1 — sets guard up, or updates it in place. Admin required.
#   irm https://raw.githubusercontent.com/ShashwatGold1/Folder_Safety_Guard/main/install.ps1 | iex
param(
    [string]$Prefix = 'C:\Program Files\guard',
    [string]$Source = '',           # local folder with the src files (tests); blank = GitHub
    [switch]$NoTask,                # skip the scheduled task (tests)
    [switch]$NoElevate,             # tests / already elevated
    [string]$ForUser = '',          # which account to protect for; blank = the signed-in user
    [switch]$Update,                # called by  guard> update
    [string]$From = '',             # old version, for the update header
    [switch]$Pause                  # keep the UAC window open at the end
)

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
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
function StepOk([string]$name,[string]$detail){ Write-Host ("  ok    {0,-9}  {1}" -f $name,$detail) -ForegroundColor Green }
function StepFail([string]$name,[string]$detail){ Write-Host ("  FAIL  {0,-9}  {1}" -f $name,$detail) -ForegroundColor Red }
function Bar([string]$what,[int]$n,[int]$tot) {
    $w = 30; $fill = [int]($w * $n / $tot)
    Write-Host ("guard  {0}   [{1}]  {2,3}%   {3}/{4}" -f $what, (('=' * $fill) + ('-' * ($w - $fill))), [int](100*$n/$tot), $n, $tot)
}
function Done-Pause { if ($Pause) { Write-Host ""; Read-Host "  press Enter to close" | Out-Null } }
function Fail-Out([string]$problem,[string]$fix) {
    Write-Host ""
    Write-Host "  not installed.  do the fix below and try again." -ForegroundColor Red
    Write-Host "  problem   $problem"
    Write-Host "  fix       $fix"
    Done-Pause
}

# --- elevate ---------------------------------------------------------------
if (-not (Is-Admin) -and -not $NoElevate) {
    # run through  irm | iex  there is no file: save ourselves first, then relaunch elevated
    $self = $MyInvocation.MyCommand.Path
    if (-not $self) {
        $self = Join-Path $env:TEMP 'guard-install.ps1'
        $text = $null
        if ($Source) { $text = Get-Content (Join-Path (Split-Path $Source -Parent) 'install.ps1') -Raw -Encoding UTF8 }
        else { $text = (Invoke-WebRequest "$repo/install.ps1" -UseBasicParsing).Content }
        [IO.File]::WriteAllText($self, $text, (New-Object Text.UTF8Encoding($true)))
    }
    $who = $ForUser; if (-not $who) { $who = [Security.Principal.WindowsIdentity]::GetCurrent().Name }
    $a = "-NoProfile -ExecutionPolicy Bypass -File `"$self`" -Pause -ForUser `"$who`" -Prefix `"$Prefix`""
    if ($Source) { $a += " -Source `"$Source`"" }
    Write-Host "guard  asking for administrator (UAC)..."
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList $a }
    catch { Write-Host "guard  not installed: the administrator prompt was cancelled." -ForegroundColor Red }
    return
}

$u = $ForUser; if (-not $u) { $u = [Security.Principal.WindowsIdentity]::GetCurrent().Name }
$total = 8
Write-Host ""

# 1 check
if ($PSVersionTable.PSVersion.Major -lt 5) { StepFail 'check' 'needs PowerShell 5 or newer'; Fail-Out 'PowerShell is too old' 'install Windows Management Framework 5.1, then run the install line again'; return }
StepOk 'check' ("PowerShell {0}  ·  {1}  ·  user {2}" -f $PSVersionTable.PSVersion, [Environment]::OSVersion.VersionString, ($u -split '\\')[-1])

# 2 uac
$uac = 1; try { $uac = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System').EnableLUA } catch {}
if ($uac -ne 1) {
    StepFail 'uac' 'User Account Control is turned off'
    Fail-Out 'UAC is off. Any program could unlock protected files without a prompt.' ("1. Win+R, type  UserAccountControlSettings`n" + "            2. move the slider to the default notch or higher, OK, restart`n" + "            3. run the install line again")
    return
}
StepOk 'uac' 'on  ·  admin rights granted'

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
        if ($Source) { $text = Get-Content -LiteralPath (Join-Path $Source $fn) -Raw -Encoding UTF8 }
        else { $text = (Invoke-WebRequest "$repo/src/$fn" -UseBasicParsing).Content }
        $dest = Join-Path $Prefix $fn
        $before = $null; if (Test-Path $dest) { $before = Get-Content -LiteralPath $dest -Raw -Encoding UTF8 }
        if ($before -ne $text) { $changed++ }
        [IO.File]::WriteAllText($dest, $text, $bom)     # BOM: PowerShell 5.1 reads it as UTF-8
    }
    $cmd = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"$Prefix\guard.ps1`" %*`r`n"
    $cmdPath = Join-Path $Prefix 'guard.cmd'
    $cmdSame = (Test-Path $cmdPath) -and ((Get-Content $cmdPath -Raw) -eq $cmd)
    if (-not $cmdSame) { [IO.File]::WriteAllText($cmdPath, $cmd, (New-Object Text.ASCIIEncoding)) }
    if ($Update) { StepOk 'files' ("{0} of {1} files updated  ·  guard.cmd {2}" -f $changed, $runtime.Count, $(if ($cmdSame) {'same'} else {'updated'})) }
    else { StepOk 'files' 'guard.ps1  ·  guard.cmd  ·  modules' }
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
        StepOk 'task' ("`"{0}`"  ·  runs as SYSTEM  ·  at logon  ·  hidden  ·  restarts itself if it stops" -f $taskName)
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
    StepOk 'folders' ("{0} protected folders untouched  ·  {1} files still locked" -f @($c.folders).Count, $n)
} elseif (Test-Path -LiteralPath $script:GuardConfigPath) {
    StepOk 'memory' 'config.json already there'
} else {
    $mem = Find-GuardMemory
    if ($mem -and @($mem.folders).Count) { $restoreFrom = $mem; StepOk 'memory' ("found in {0}  ·  lists {1} folders" -f $script:MemoryFoundIn, @($mem.folders).Count) }
    else {
        # write an empty config now: the background guard then never has to search the disks
        Save-GuardConfig -Config (New-GuardConfig) -User $u
        StepOk 'memory' 'nothing from an earlier install'
    }
}

Write-Host ""
if ($Update) { Bar ("updating {0} -> {1}" -f $From, $script:GuardVersion) $total $total } else { Bar 'installing' $total $total }
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
