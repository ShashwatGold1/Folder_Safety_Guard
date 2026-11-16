# install.ps1 — sets guard up. Admin required. Params let tests run into a temp prefix.
param(
    [string]$Prefix = 'C:\Program Files\guard',
    [string]$Source = '',           # where the src files are; blank = download from GitHub
    [switch]$NoTask,                # skip the scheduled task (tests)
    [switch]$NoElevate,             # tests / already elevated
    [string]$ForUser = ''           # which account to protect for; blank = current
)

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$ErrorActionPreference = 'Stop'
$steps = @('check','uac','folder','files','path','task','guard')
$done = 0; $results = @{}
$ver = '1.0'

function Bar([int]$n,[int]$tot,[string]$cur) {
    $w = 30; $fill = [int]($w * $n / $tot)
    $b = ('=' * $fill) + ('-' * ($w - $fill))
    Write-Host ("guard  installing   [{0}]  {1,3}%   {2}/{3}   {4}" -f $b, [int](100*$n/$tot), $n, $tot, $cur)
}
function StepOk([string]$name,[string]$detail){ $script:results[$name]='ok'; Write-Host ("  ok    {0,-9} {1}" -f $name,$detail) -ForegroundColor Green }
function StepFail([string]$name,[string]$detail){ $script:results[$name]='FAIL'; Write-Host ("  FAIL  {0,-9} {1}" -f $name,$detail) -ForegroundColor Red }

function Is-Admin { $id=[Security.Principal.WindowsIdentity]::GetCurrent(); (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }

# elevate
if (-not (Is-Admin) -and -not $NoElevate) {
    $a = "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`""
    Start-Process powershell.exe -Verb RunAs -ArgumentList $a; return
}

Write-Host ""
# 1 check
if ($PSVersionTable.PSVersion.Major -lt 5) { StepFail 'check' 'needs PowerShell 5+'; return }
StepOk 'check' ("PowerShell {0} - {1}" -f $PSVersionTable.PSVersion, [Environment]::OSVersion.VersionString)
# 2 uac
$uac = 1; try { $uac = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System').EnableLUA } catch {}
if ($uac -ne 1) {
    StepFail 'uac' 'User Account Control is turned off'
    Write-Host ""
    Write-Host "  not installed.  do the fix below and try again." -ForegroundColor Red
    Write-Host "  problem   UAC is off. Any program could unlock protected files without a prompt."
    Write-Host "  fix       1. Win+R, type  UserAccountControlSettings"
    Write-Host "            2. move the slider to the default notch or higher, OK, restart"
    Write-Host "            3. run the install line again"
    return
}
StepOk 'uac' 'on - admin rights granted'
# 3 folder
try { if (-not (Test-Path $Prefix)) { New-Item -ItemType Directory -Path $Prefix -Force | Out-Null }; StepOk 'folder' $Prefix } catch { StepFail 'folder' $_.Exception.Message; return }
# 4 files
try {
    $runtime = 'guard.ps1','guard-shell.ps1','guard-core.ps1','guard-config.ps1','guard-watch.ps1'
    if ($Source) {
        foreach ($fn in $runtime) { Copy-Item (Join-Path $Source $fn) $Prefix -Force }
    } else {
        $base = 'https://raw.githubusercontent.com/ShashwatGold1/Folder_Safety_Guard/main/src'
        foreach ($fn in 'guard.ps1','guard-shell.ps1','guard-core.ps1','guard-config.ps1','guard-watch.ps1') {
            Invoke-WebRequest "$base/$fn" -OutFile (Join-Path $Prefix $fn) -UseBasicParsing
        }
    }
    # guard.cmd wrapper so `guard` works from any shell
    $cmd = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"$Prefix\guard.ps1`" %*"
    Set-Content (Join-Path $Prefix 'guard.cmd') $cmd -Encoding ASCII
    StepOk 'files' 'guard.ps1, guard.cmd and modules'
} catch { StepFail 'files' $_.Exception.Message; return }
# 5 path
try {
    $mp = [Environment]::GetEnvironmentVariable('Path','Machine')
    if ($mp -notlike "*$Prefix*") { [Environment]::SetEnvironmentVariable('Path', ($mp.TrimEnd(';')+';'+$Prefix), 'Machine') }
    StepOk 'path' 'added for all users'
} catch { StepFail 'path' $_.Exception.Message; return }
# 6 task
if ($NoTask) { StepOk 'task' 'skipped (test)' } else {
    try {
        $u = $ForUser; if (-not $u) { $u = [Security.Principal.WindowsIdentity]::GetCurrent().Name }
        $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Prefix\guard-watch.ps1`" -User `"$u`""
        $trg = New-ScheduledTaskTrigger -AtLogOn
        $pr  = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
        Register-ScheduledTask -TaskName 'guard' -Action $act -Trigger $trg -Principal $pr -Settings $set -Force | Out-Null
        StepOk 'task' '"guard" - runs as SYSTEM - at logon'
    } catch { StepFail 'task' $_.Exception.Message; return }
}
# 7 guard (start watcher once now)
try {
    $u = $ForUser; if (-not $u) { $u = [Security.Principal.WindowsIdentity]::GetCurrent().Name }
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$Prefix\guard-watch.ps1`" -User `"$u`""
    StepOk 'guard' 'background guard running'
} catch { StepFail 'guard' $_.Exception.Message }

Write-Host ""
Bar $steps.Count $steps.Count 'done'
Write-Host ""
Write-Host "  installed successfully." -ForegroundColor Green
Write-Host "  open a new terminal and type:  guard" -ForegroundColor Cyan
