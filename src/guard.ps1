# guard.ps1 — entry point. Self-elevates (UAC once), then runs the interactive shell.
#   -Elevated   set by guard itself on the relaunch after the UAC click
#   -NoElevate  tests only: run in this process as-is
#   -ForUser    the signed-in user, captured BEFORE the UAC click: a standard account elevates
#               as a different (admin) account, and the locks must be for the real user
param([switch]$NoElevate, [switch]$Elevated, [string]$Cwd = '', [string]$ForUser = '')

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$here\guard-shell.ps1"

# --- elevation -------------------------------------------------------------
if (-not (Test-GuardAdmin) -and -not $NoElevate) {
    # the elevated window starts in System32 and gets no env from us: pass the folder along
    $cwd = (Get-Location).ProviderPath; if ($cwd.EndsWith('\')) { $cwd += '.' }   # "C:\" would escape the quote
    $me  = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $psi = "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`" -Elevated -Cwd `"$cwd`" -ForUser `"$me`""
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList $psi }
    catch { Write-Host "guard needs administrator. the prompt was cancelled." -ForegroundColor Red }
    return
}
if ($Cwd) { try { Set-Location -LiteralPath $Cwd -ErrorAction Stop } catch { } }

# opened straight inside a terminal that was already admin: agents in it could unlock files
$script:AdminWarn = ((Test-GuardAdmin) -and -not $Elevated -and -not $NoElevate)

$script:User = $ForUser; if (-not $script:User) { $script:User = Get-GuardUser }
$hadMaster = Test-Path -LiteralPath $script:GuardConfigPath
$script:Cfg  = Load-GuardConfig
if (-not $hadMaster -and $script:MemoryFoundIn) {
    Save-GuardConfig -Config $script:Cfg -User $script:User
    $script:Rebuilt = $script:MemoryFoundIn
}

function Show-AdminWarn {
    # opened in a terminal that was already admin: say so once, in green, when guard opens
    if ($script:AdminWarn) {
        Write-Host ("admin     running as administrator  {0}  no prompt needed" -f [char]0x00B7) -ForegroundColor Green
        Write-Host ""
    }
}

function Prompt-Loop {
    Clear-Host
    Show-Table
    if ($script:Rebuilt) { Write-Host ("memory    rebuilt from {0}" -f $script:Rebuilt) -ForegroundColor Green }
    Show-Status
    Show-AdminWarn
    while ($true) {
        Write-Host -NoNewline "guard> "
        $raw = [Console]::ReadLine()
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
            if (Open-GuardIssue $url) { Write-Host "        a GitHub issue opened in your browser, filled in. check it, then press Submit." }
            else { Write-Host "        please report it here:" ; Write-Host "        https://github.com/ShashwatGold1/Folder_Safety_Guard/issues/new" -ForegroundColor Cyan }
        }
        if (-not $cont) {
            $c = $raw.Trim().ToLower()
            if ($c -eq 'exit') { Write-Host "  background guard keeps running. type  guard  to come back." }
            elseif ($c -eq 'update') { Write-Host "  type:  guard" -ForegroundColor Cyan }
            # the UAC window closes on its own: let the user read update/uninstall results first
            if ($Elevated -and $c -ne 'exit') { Read-Host "  press Enter to close" | Out-Null }
            break
        }
        Show-Status
    }
}

Prompt-Loop
