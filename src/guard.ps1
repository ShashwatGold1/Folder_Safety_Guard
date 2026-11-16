# guard.ps1 — entry point. Self-elevates (UAC once), then runs the interactive shell.
param([switch]$NoElevate)

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$here\guard-shell.ps1"

# --- elevation -------------------------------------------------------------
if (-not (Test-GuardAdmin) -and -not $NoElevate) {
    $psi = "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`""
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList $psi } catch { Write-Host "guard needs administrator. the prompt was cancelled." -ForegroundColor Red }
    return
}

$script:User = Get-GuardUser
$script:Cfg  = Load-GuardConfig

# warn if this terminal was already elevated before guard (agents could inherit rights)
if ($env:GUARD_SELF_ELEVATED -ne '1' -and (Test-GuardAdmin) -and $NoElevate) {
    # launched directly inside an already-admin shell
    $script:AdminWarn = $true
}

function Prompt-Loop {
    Clear-Host
    Show-Table
    Show-Status
    if ($script:AdminWarn) {
        Write-Host "warning   this terminal already had admin rights before guard opened." -ForegroundColor Yellow
        Write-Host "          if an AI agent runs in it, it can unlock files. use a normal terminal for agents." -ForegroundColor Yellow
    }
    while ($true) {
        $raw = Read-Host "guard"
        $cont = Invoke-GuardCommand $raw
        if (-not $cont) { Write-Host "  background guard keeps running. type  guard  to come back."; break }
        if ($raw.Trim().ToLower() -ne 'cls' -and $raw.Trim().ToLower() -ne 'help') { Show-Status }
    }
}

Prompt-Loop
