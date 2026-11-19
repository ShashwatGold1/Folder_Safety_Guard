# guard.ps1 — entry point. Self-elevates (UAC once), then runs the interactive shell.
#   -Elevated   set by guard itself on the relaunch after the UAC click
#   -NoElevate  tests only: run in this process as-is
#   -ForUser    the signed-in user, captured BEFORE the UAC click: a standard account elevates
#               as a different (admin) account, and the locks must be for the real user
#   -AttachTo   the hidden elevated relay (the caller's pid): opens guard in a window of its own
#   -OwnWindow  guard runs in a window of its own (always, after the UAC click)
#   -Caller     the waiting window's pid: told when the green line is about to print
param([switch]$NoElevate, [switch]$Elevated, [string]$Cwd = '', [string]$ForUser = '', [int]$AttachTo = 0, [switch]$OwnWindow, [int]$Caller = 0)

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$here\guard-shell.ps1"

# --- elevation -------------------------------------------------------------
if (-not (Test-GuardAdmin) -and -not $NoElevate) {
    # the elevated copy starts in System32 and gets no env from us: pass the folder along
    $cwd = (Get-Location).ProviderPath; if ($cwd.EndsWith('\')) { $cwd += '.' }   # "C:\" would escape the quote
    $me  = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $psi = "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`" -AttachTo $PID -Cwd `"$cwd`" -ForUser `"$me`""
    Write-Host ""
    $enc = [Console]::OutputEncoding
    # the hidden admin relay opens guard in a window of its own; this one waits until guard exits
    $p = Request-GuardAdmin 'Requesting Admin Access' $psi
    if ($p) {
        Write-Host "guard is open in its own window: only programs with admin rights can type into it." -ForegroundColor Green
        Write-Host "this terminal waits until you close guard."
        $p.WaitForExit()
    }
    else { Write-Host "guard needs administrator. the prompt was cancelled." -ForegroundColor Red; Write-Host "" }
    try { [Console]::OutputEncoding = $enc } catch { }
    return
}
if ($AttachTo) {
    $c = $Cwd; if ($c.EndsWith('\')) { $c += '.' }
    $psi = "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`" -Elevated -Caller $AttachTo -Cwd `"$c`" -ForUser `"$ForUser`" -OwnWindow"
    # Never in the caller's terminal: that console belongs to a normal process, so any program
    # running as the user can attach to it and type commands (WriteConsoleInput) that the
    # elevated guard would run - proven by redteam.ps1. A console made by an admin process
    # refuses programs without admin rights, and its window is shielded from their fake keys.
    $p = Start-Process (Get-GuardPowerShellExe) -ArgumentList $psi -PassThru
    $p.WaitForExit(); exit $p.ExitCode
}
if ($Cwd) { try { Set-Location -LiteralPath $Cwd -ErrorAction Stop } catch { } }
if ($OwnWindow) { try { $Host.UI.RawUI.WindowTitle = 'guard (administrator)' } catch { } }

# opened straight inside a terminal that was already admin: agents in it could unlock files
$script:AdminWarn = ((Test-GuardAdmin) -and -not $Elevated -and -not $NoElevate)

$script:User = $ForUser; if (-not $script:User) { $script:User = Get-GuardUser }
# the data folder: protected, and anything in it guard didn't write is removed (and said)
$script:DataRemoved = @(Initialize-GuardDataDir)
$hadMaster = Test-Path -LiteralPath $script:GuardConfigPath
$script:Cfg  = Load-GuardConfig
if (-not $hadMaster -and $script:MemoryFoundIn) {
    Save-GuardConfig -Config $script:Cfg -User $script:User
    $script:Rebuilt = $script:MemoryFoundIn
}

function Show-AdminWarn {
    # say once, in green, when guard opens how it got admin rights
    if ($Elevated) {
        Wait-GuardCallerDots $Caller
        Write-Host "Admin Access Granted Successfully." -ForegroundColor Green
        Write-Host ""
    }
    if ($script:AdminWarn) {
        Write-Host "Admin Access Already Granted." -ForegroundColor Green
        Write-Host ""
    }
}

function Prompt-Loop {
    # no Clear-Host: in an already-admin terminal guard runs inline, and what was there stays
    # above it. After the UAC click guard has a window of its own.
    if (-not $Elevated) { Write-Host "" }
    Show-AdminWarn
    Show-Table
    if ($script:DataRemoved.Count) { Write-Host ("removed   {0} from {1}: guard didn't write it" -f ($script:DataRemoved -join ', '), (Split-Path $script:GuardConfigPath -Parent)) -ForegroundColor Yellow }
    if ($script:Rebuilt) { Write-Host ("memory    rebuilt from {0}" -f $script:Rebuilt) -ForegroundColor Green }
    Show-Status -All
    while ($true) {
        $script:ShowAll = $false
        $raw = Read-GuardInput "guard> "
        if ($null -eq $raw) { $raw = 'exit' }   # input closed = exit
        try { $cont = Invoke-GuardCommand $raw }
        catch {
            # never die halfway through a command: say what broke and how to report it
            $cont = $true
            $msg = $_.Exception.Message; $at = (($_.ScriptStackTrace -split "`n")[0])
            Write-Host ("  FAIL  {0}" -f $msg) -ForegroundColor Red
            Write-Host ("        at {0}" -f $at) -ForegroundColor DarkGray
            Write-Host  "        something unexpected went wrong in the middle of that command."
            Write-Host  "        type  resume  to make sure everything is locked again."
            $url = New-GuardIssueUrl -Command $raw -Message $msg -Where $at
            Write-Host ""
            Write-Host "  Report this on GitHub?  (opens the browser with the report filled in; you only click Submit)"
            Write-Host "  the report has only the guard, Windows and PowerShell versions and the error line, never file or folder names" -ForegroundColor DarkGray
            if ((Select-Menu @('yes', 'no')) -eq 1) {
                if (Open-GuardIssue $url) { Ok "opened" "github.com/ShashwatGold1/Folder_Safety_Guard/issues/new" }
                else { Write-Host "  open this page:  https://github.com/ShashwatGold1/Folder_Safety_Guard/issues/new" -ForegroundColor Cyan }
            }
        }
        if (-not $cont) {
            $c = $raw.Trim().ToLower()
            if ($c -eq 'exit') { Write-Host "  background guard keeps running. type  guard  to come back." }
            elseif ($c -eq 'update') { Write-Host "  type:  guard" -ForegroundColor Cyan }
            # a window of its own closes on its own: let the user read update/uninstall results first
            if ($OwnWindow -and $c -ne 'exit') { Read-Host "  press Enter to close" | Out-Null }
            break
        }
        Show-Status -All:$script:ShowAll    # every folder after cls, only the current one otherwise
    }
}

Prompt-Loop
