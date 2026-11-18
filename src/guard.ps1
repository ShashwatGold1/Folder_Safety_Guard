# guard.ps1 — entry point. Self-elevates (UAC once), then runs the interactive shell.
#   -Elevated   set by guard itself on the relaunch after the UAC click
#   -NoElevate  tests only: run in this process as-is
#   -ForUser    the signed-in user, captured BEFORE the UAC click: a standard account elevates
#               as a different (admin) account, and the locks must be for the real user
#   -AttachTo   the elevated copy, started hidden: moves into this terminal (the caller's pid)
#   -OwnWindow  fallback when it couldn't: guard runs in a window of its own
param([switch]$NoElevate, [switch]$Elevated, [string]$Cwd = '', [string]$ForUser = '', [int]$AttachTo = 0, [switch]$OwnWindow)

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$here\guard-shell.ps1"

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
        # Ctrl+C must not kill this relay: the caller would return to its prompt with guard still running
        [void][GuardCon.K]::SetConsoleCtrlHandler([IntPtr]::Zero, $true)
        $in  = [GuardCon.K]::CreateFile('CONIN$',  [uint32]3221225472, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
        $out = [GuardCon.K]::CreateFile('CONOUT$', [uint32]3221225472, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
        foreach ($h in $in, $out) { [void][GuardCon.K]::SetHandleInformation($h, 1, 1) }   # inheritable
        [void][GuardCon.K]::SetStdHandle(-10, $in); [void][GuardCon.K]::SetStdHandle(-11, $out); [void][GuardCon.K]::SetStdHandle(-12, $out)
        return $true
    } catch { return $false }
}

# --- elevation -------------------------------------------------------------
if (-not (Test-GuardAdmin) -and -not $NoElevate) {
    # the elevated copy starts in System32 and gets no env from us: pass the folder along
    $cwd = (Get-Location).ProviderPath; if ($cwd.EndsWith('\')) { $cwd += '.' }   # "C:\" would escape the quote
    $me  = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $psi = "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`" -AttachTo $PID -Cwd `"$cwd`" -ForUser `"$me`""
    Write-Host ""
    Write-Host "Requesting Admin Access..."
    $enc = [Console]::OutputEncoding
    # hidden: it moves into this window, and this one waits until guard exits
    try { $p = Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -PassThru -ArgumentList $psi; $p.WaitForExit() }
    catch { Write-Host "guard needs administrator. the prompt was cancelled." -ForegroundColor Red; Write-Host "" }
    try { [Console]::OutputEncoding = $enc } catch { }
    return
}
if ($AttachTo) {
    $c = $Cwd; if ($c.EndsWith('\')) { $c += '.' }
    $psi = "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`" -Elevated -Cwd `"$c`" -ForUser `"$ForUser`""
    if (Join-CallerConsole $AttachTo) {
        $si = New-Object Diagnostics.ProcessStartInfo 'powershell.exe', $psi
        $si.UseShellExecute = $false        # inherits the caller's window
        $p = [Diagnostics.Process]::Start($si); $p.WaitForExit(); exit $p.ExitCode
    }
    Start-Process powershell.exe -ArgumentList "$psi -OwnWindow"
    exit
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
    # say once, in green, when guard opens how it got admin rights
    if ($Elevated) {
        Write-Host "Admin Access Granted Successfully." -ForegroundColor Green
        Write-Host ""
    }
    if ($script:AdminWarn) {
        Write-Host ("admin     running as administrator  {0}  no prompt needed" -f [char]0x00B7) -ForegroundColor Green
        Write-Host ""
    }
}

function Prompt-Loop {
    # no Clear-Host: guard runs in the user's own terminal, and what was there stays above it.
    # After the UAC click the green line goes right under "Requesting Admin Access..."
    if (-not $Elevated) { Write-Host "" }
    Show-AdminWarn
    Show-Table
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
