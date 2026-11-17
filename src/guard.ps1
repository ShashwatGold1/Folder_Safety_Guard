# guard.ps1 — entry point. Self-elevates (UAC once), then runs the interactive shell.
#   -Elevated   set by guard itself on the relaunch after the UAC click
#   -NoElevate  tests only: run in this process as-is
param([switch]$NoElevate, [switch]$Elevated, [string]$Cwd = '')

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$here\guard-shell.ps1"

# --- elevation -------------------------------------------------------------
if (-not (Test-GuardAdmin) -and -not $NoElevate) {
    # the elevated window starts in System32 and gets no env from us: pass the folder along
    $cwd = (Get-Location).ProviderPath; if ($cwd.EndsWith('\')) { $cwd += '.' }   # "C:\" would escape the quote
    $psi = "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`" -Elevated -Cwd `"$cwd`""
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList $psi }
    catch { Write-Host "guard needs administrator. the prompt was cancelled." -ForegroundColor Red }
    return
}
if ($Cwd) { try { Set-Location -LiteralPath $Cwd -ErrorAction Stop } catch { } }

# opened straight inside a terminal that was already admin: agents in it could unlock files
$script:AdminWarn = ((Test-GuardAdmin) -and -not $Elevated -and -not $NoElevate)

$script:User = Get-GuardUser
$hadMaster = Test-Path -LiteralPath $script:GuardConfigPath
$script:Cfg  = Load-GuardConfig
if (-not $hadMaster -and $script:MemoryFoundIn) {
    Save-GuardConfig -Config $script:Cfg -User $script:User
    $script:Rebuilt = $script:MemoryFoundIn
}

function Show-AdminWarn {
    if ($script:AdminWarn) {
        Write-Host "warning   this terminal already had admin rights before guard opened." -ForegroundColor Yellow
        Write-Host "          if an AI agent runs in it, it can unlock files. use a normal terminal for agents." -ForegroundColor Yellow
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
        $raw = Read-Host "guard"
        $cont = Invoke-GuardCommand $raw
        if (-not $cont) {
            $c = $raw.Trim().ToLower()
            if ($c -eq 'exit') { Write-Host "  background guard keeps running. type  guard  to come back." }
            elseif ($c -eq 'update') { Write-Host "  type:  guard" -ForegroundColor Cyan }
            # the UAC window closes on its own: let the user read update/uninstall results first
            if ($Elevated -and $c -ne 'exit') { Read-Host "  press Enter to close" | Out-Null }
            break
        }
        Show-Status
        Show-AdminWarn
    }
}

Prompt-Loop
