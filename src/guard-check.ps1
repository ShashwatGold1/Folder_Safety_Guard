# guard-check.ps1 - the  check  command: Windows settings guard can't protect by itself.
#   check          shows every setting: ok, or what to fix and why, in plain words
#   check fix      fixes every setting guard can change (after YES); says each result
#   check account  makes a separate admin account, so the daily account stops being an admin
# Nothing about startup / booting (startup PIN, BIOS, USB boot): left out by the owner's choice,
# and  check  says what that leaves open.
# Tests: GUARD_CHECK_ROOT (test mode only) moves every registry read and write to a test key.

$script:AdminsSid = 'S-1-5-32-544'
function Get-CheckRoot { $r = Get-GuardTestEnv 'GUARD_CHECK_ROOT'; if ($r) { return $r.TrimEnd('\') }; return 'HKLM:' }
function Get-CheckValue([string]$Sub, [string]$Name) {
    try { return (Get-ItemProperty -LiteralPath ((Get-CheckRoot) + '\' + $Sub) -ErrorAction Stop).$Name } catch { return $null }
}
function Set-CheckValue([string]$Sub, [string]$Name, [int]$Value) {
    $p = (Get-CheckRoot) + '\' + $Sub
    if (-not (Test-Path -LiteralPath $p)) { New-Item -Path $p -Force -ErrorAction Stop | Out-Null }
    New-ItemProperty -LiteralPath $p -Name $Name -Value $Value -PropertyType DWord -Force -ErrorAction Stop | Out-Null
}

# ---- reads that are not plain registry values (tests replace these functions) ----
function Get-CheckHibernate { return [IO.File]::Exists((Join-Path (Split-Path (Get-GuardWindowsDir) -Qualifier) 'hiberfil.sys')) }
function Set-CheckHibernateOff { $o = & (Get-GuardTool 'powercfg.exe') /hibernate off 2>&1; if ($LASTEXITCODE) { throw ("powercfg: " + ($o | Out-String).Trim()) } }
function Get-CheckDefender {
    try { $s = Get-MpComputerStatus -ErrorAction Stop; $p = Get-MpPreference -ErrorAction Stop
          return @{ Ok = $true; RealTime = [bool]$s.RealTimeProtectionEnabled; Tamper = [bool]$s.IsTamperProtected; Samples = [int]$p.SubmitSamplesConsent } }
    catch { return @{ Ok = $false } }
}
function Set-CheckDefenderSamples { Set-MpPreference -SubmitSamplesConsent 2 -ErrorAction Stop }   # 2 = never send files
function Get-CheckLastUpdate {
    try { return (Get-HotFix -ErrorAction Stop | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1).InstalledOn } catch { return $null }
}
function Get-CheckSid([string]$Account) {
    try { return (New-Object Security.Principal.NTAccount($Account)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { return $null }
}
function Get-CheckAdmins { return @(Get-LocalGroupMember -SID $script:AdminsSid -ErrorAction Stop | ForEach-Object { [string]$_.SID.Value }) }
function Test-CheckIsAdmin([string]$Account) { $s = Get-CheckSid $Account; return ($s -and ((Get-CheckAdmins) -contains $s)) }

# ---- the list -------------------------------------------------------------------------------
function Get-GuardChecks {
    $out = New-Object System.Collections.ArrayList
    # $Auto: guard can fix it itself (Invoke-CheckFixStep does, by $Id)
    $add = { param($Id, $Name, $Ok, $Detail, $Why, $Fix, $Auto) [void]$out.Add([pscustomobject]@{ Id = $Id; Name = $Name; Ok = [bool]$Ok; Detail = $Detail; Why = $Why; Fix = $Fix; Auto = [bool]$Auto }) }

    $u = $script:User; $isAdm = $false; try { $isAdm = Test-CheckIsAdmin $u } catch { }
    & $add 'account' 'account' (-not $isAdm) $(if ($isAdm) { "$(($u -split '\\')[-1]) is an administrator" } else { "$(($u -split '\\')[-1]) is a standard account" }) `
        'programs you run (an AI agent too) can get admin rights through known tricks, with no prompt. guard only stops programs WITHOUT admin rights.' `
        'type  check account' $null

    $sys = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $lua = Get-CheckValue $sys 'EnableLUA'; $sec = Get-CheckValue $sys 'PromptOnSecureDesktop'; $usr = Get-CheckValue $sys 'ConsentPromptBehaviorUser'
    $uacOk = ($lua -ne 0) -and ($sec -ne 0) -and ($null -eq $usr -or @(1, 3) -contains $usr)
    & $add 'uac' 'uac' $uacOk $(if ($uacOk) { 'asks on the dimmed screen, passwords asked there' } else { 'the admin prompt is weakened' }) `
        'a weak prompt can be clicked or answered by other programs.' 'check fix' $true

    $cu = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\CredUI'
    $tp = (Get-CheckValue $cu 'EnableSecureCredentialPrompting') -eq 1
    & $add 'password' 'passwords' $tp $(if ($tp) { 'Windows asks for passwords only after Ctrl+Alt+Del' } else { 'a password box can be faked' }) `
        'any program can draw a box that looks like Windows asking for your password. Ctrl+Alt+Del first means the box is really Windows.' 'check fix' $true

    $cb = 'SOFTWARE\Policies\Microsoft\Windows\System'
    $cbOk = ((Get-CheckValue $cb 'AllowClipboardHistory') -eq 0) -and ((Get-CheckValue $cb 'AllowCrossDeviceClipboard') -eq 0)
    & $add 'clipboard' 'clipboard' $cbOk $(if ($cbOk) { 'no history, no cloud' } else { 'history is kept (Win+V)' }) `
        'every password you copy stays in the history, where any program can read it. (copy and paste keep working.)' 'check fix' $true

    $hib = $false; try { $hib = Get-CheckHibernate } catch { }
    & $add 'hibernate' 'hibernate' (-not $hib) $(if ($hib) { 'on (also Fast Startup)' } else { 'off' }) `
        'hibernating writes everything open, secrets too, into a file on C:. (normal sleep and shut down keep working.)' 'check fix' $true

    $mm = 'SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
    $pf = (Get-CheckValue $mm 'ClearPageFileAtShutdown') -eq 1
    & $add 'pagefile' 'pagefile' $pf $(if ($pf) { 'wiped at every shut down' } else { 'kept after shut down' }) `
        'Windows parks memory in a file on C:; what was open can stay readable there. (shut down takes a little longer.)' 'check fix' $true

    $cc = 'SYSTEM\CurrentControlSet\Control\CrashControl'
    $cd = Get-CheckValue $cc 'CrashDumpEnabled'; $cdOk = (@(0, 3) -contains $cd)
    & $add 'crash' 'crash files' $cdOk $(if ($cdOk) { 'small only' } else { 'a crash saves the whole memory to disk' }) `
        'a full crash file holds everything that was open.' 'check fix' $true

    $d = Get-CheckDefender
    if (-not $d.Ok) { & $add 'defender' 'defender' $false "can't read Windows Security" 'another antivirus may be in charge: make sure it is on.' 'open Windows Security' $null }
    else {
        $on = $d.RealTime -and $d.Tamper
        & $add 'defender' 'defender' $on $(if ($on) { 'on, tamper protection on' } else { 'real-time or tamper protection is off' }) `
            'without them, malware runs or switches the antivirus off.' 'Windows Security > Virus & threat protection > turn both on' $null
        $sm = (@(0, 2) -contains $d.Samples)
        & $add 'samples' 'samples' $sm $(if ($sm) { 'files are never sent without asking' } else { 'suspicious files are sent to Microsoft by itself' }) `
            'a file of yours could be uploaded without a question.' 'check fix' $true
    }

    $last = Get-CheckLastUpdate
    if ($last) {
        $days = [int]((Get-Date) - $last).TotalDays
        & $add 'updates' 'updates' ($days -le 45) ("last update {0}  ({1} days ago)" -f $last.ToString('d MMM yyyy'), $days) `
            'old Windows has known holes that let programs get admin rights.' 'Settings > Windows Update > Check for updates' $null
    } else { & $add 'updates' 'updates' $false "can't tell when Windows last updated" 'old Windows has known holes.' 'Settings > Windows Update > Check for updates' $null }

    $hv = (Get-CheckValue 'SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled') -eq 1
    $lsa = @(1, 2) -contains (Get-CheckValue 'SYSTEM\CurrentControlSet\Control\Lsa' 'RunAsPPL')
    & $add 'kernel' 'core' ($hv -and $lsa) $(if ($hv -and $lsa) { 'memory integrity on, sign-in protection on' } else { 'memory integrity or sign-in protection is off' }) `
        'they stop bad drivers and password theft from memory.' 'Windows Security > Device security > Core isolation > Memory integrity on, Local Security Authority protection on, restart' $null
    return $out
}

function Invoke-CheckFixStep([string]$Id) {
    # the change behind each  check fix  line; throws when Windows refuses
    $sys = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    switch ($Id) {
        'uac'       { Set-CheckValue $sys 'PromptOnSecureDesktop' 1; Set-CheckValue $sys 'ConsentPromptBehaviorUser' 3 }
        'password'  { Set-CheckValue 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\CredUI' 'EnableSecureCredentialPrompting' 1 }
        'clipboard' { Set-CheckValue 'SOFTWARE\Policies\Microsoft\Windows\System' 'AllowClipboardHistory' 0; Set-CheckValue 'SOFTWARE\Policies\Microsoft\Windows\System' 'AllowCrossDeviceClipboard' 0 }
        'hibernate' { Set-CheckHibernateOff }
        'pagefile'  { Set-CheckValue 'SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'ClearPageFileAtShutdown' 1 }
        'crash'     { Set-CheckValue 'SYSTEM\CurrentControlSet\Control\CrashControl' 'CrashDumpEnabled' 3 }
        'samples'   { Set-CheckDefenderSamples }
        default     { throw "no fix for $Id" }
    }
}

function Show-GuardChecks($List) {
    Say ""; Say "  PC check - settings guard can't protect by itself"; Say ""
    foreach ($c in $List) {
        if ($c.Ok) { Say ("  ok    {0,-11} {1}" -f $c.Name, $c.Detail) 'Green' }
        else {
            Say ("  fix   {0,-11} {1}" -f $c.Name, $c.Detail) 'Yellow'
            Say ("        {0,-11} {1}" -f '', $c.Why) 'DarkGray'
            Say ("        {0,-11} {1}" -f '', $c.Fix) 'Cyan'
        }
    }
    Say ("  info  {0,-11} {1}" -f 'startup', 'no startup PIN (your choice). someone with this PC alone for a while could change Windows') 'DarkGray'
    Say ("        {0,-11} {1}" -f '', 'and plant spyware. keep the PC where others can''t get at it; guard vaults stay locked either way.') 'DarkGray'
    $n = @($List | Where-Object { -not $_.Ok }).Count
    Say ""
    if ($n -eq 0) { Say "  every setting is ok." 'Green' }
    else {
        $auto = @($List | Where-Object { -not $_.Ok -and $_.Auto }).Count
        $msg = "  {0} to fix." -f $n
        if ($auto) { $msg += ("  check fix  fixes {0} of them." -f $auto) }
        Say $msg 'Yellow'
    }
}

function Read-CheckSecret([string]$Prompt) {
    # tests: from the answer queue (never shown); otherwise typed, not shown
    if ($script:InputQueue -and $script:InputQueue.Count -gt 0) { Say ($Prompt + ': ********') 'DarkGray'; return [string]$script:InputQueue.Dequeue() }
    $s = Read-Host $Prompt -AsSecureString
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}
function Test-CheckPassword([string]$Name, [string]$Password) {
    Add-Type -AssemblyName System.DirectoryServices.AccountManagement
    $ctx = New-Object DirectoryServices.AccountManagement.PrincipalContext([DirectoryServices.AccountManagement.ContextType]::Machine)
    try { return $ctx.ValidateCredentials($Name, $Password) } finally { $ctx.Dispose() }
}

function Cmd-CheckFix {
    if (-not (Test-GuardAdmin) -and -not (Get-GuardTestEnv 'GUARD_CHECK_ROOT')) { Say "  needs administrator" 'Red'; return }
    $todo = @(Get-GuardChecks | Where-Object { -not $_.Ok -and $_.Auto })
    if (-not $todo.Count) { Say "  nothing guard can fix: every setting it can change is ok."; return }
    Say ""; Say "  guard will change these Windows settings for everyone on this PC:"
    foreach ($c in $todo) { Say ("    {0,-11} {1}" -f $c.Name, $c.Why) }
    Say "  each one can be turned back in Windows settings later."
    $a = Read-Line "  type YES to change them > "
    if ($a.Trim() -ne 'YES') { Say "  cancelled. nothing was changed."; return }
    $bad = 0
    foreach ($c in $todo) {
        try { Invoke-CheckFixStep $c.Id; Ok $c.Name 'changed' }
        catch { Say ("  FAIL  {0}  {1}" -f $c.Name, $_.Exception.Message) 'Red'; $bad++ }
    }
    # read everything again: only what Windows now reports counts
    $still = @(Get-GuardChecks | Where-Object { -not $_.Ok -and $_.Auto })
    foreach ($c in $still) { Say ("  FAIL  {0}  Windows still reports the old setting" -f $c.Name) 'Red' }
    Say ""
    if ($still.Count) { Say ("  {0} setting(s) could not be changed." -f $still.Count) 'Red' }
    else { Say "  Settings are Changed Successfully." 'Green'; Say "  hibernate, pagefile and crash files take effect after the next restart." 'DarkGray' }
}

function Cmd-CheckAccount {
    $u = $script:User; $short = ($u -split '\\')[-1]
    if (-not (Test-GuardAdmin) -and -not (Get-GuardTestEnv 'GUARD_CHECK_ROOT')) { Say "  needs administrator" 'Red'; return }
    if (-not (Test-CheckIsAdmin $u)) { Say "  $short is already a standard account. nothing to do." 'Green'; return }
    Say ""
    Say "  $short is an administrator. any program you run, an AI agent too, can get admin rights"
    Say "  through known tricks, with no prompt at all. then guard's locks don't stop it."
    Say ""
    Say "  the fix: a second account only for admin work."
    Say "    1  guard makes that admin account now: you choose its name and password"
    Say "    2  guard checks the password works"
    Say "    3  $short stops being an administrator (from your next sign-in)"
    Say "  you keep using $short every day. when something needs admin rights (guard too),"
    Say "  Windows asks for the admin account's password."
    Say "  write that password on paper. without it nobody can make admin changes on this PC." 'Yellow'
    Say ""
    $name = Read-Line "  name for the admin account (Enter = PC-Admin) > "
    if (-not $name) { $name = 'PC-Admin' }
    if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9 ._-]{0,19}$' -or $name -eq $short) { Say "  not a usable account name. nothing was changed." 'Red'; return }
    $exists = $null; try { $exists = Get-LocalUser -Name $name -ErrorAction Stop } catch { }
    $p1 = Read-CheckSecret '  password (at least 12 characters)'; $p2 = Read-CheckSecret '  password again'
    if ($p1 -ne $p2) { Say "  the two passwords differ. nothing was changed." 'Red'; return }
    if ($p1.Length -lt 12) { Say "  shorter than 12 characters. nothing was changed." 'Red'; return }
    try {
        if ($exists) {
            if (-not $exists.Enabled) { Say "  $name exists but is turned off. pick another name. nothing was changed." 'Red'; return }
            if (-not (Test-CheckPassword $name $p1)) { Say "  $name already exists and that is not its password. nothing was changed." 'Red'; return }
        } else {
            $sec = ConvertTo-SecureString $p1 -AsPlainText -Force
            New-LocalUser -Name $name -Password $sec -PasswordNeverExpires -Description 'admin account for guard (made by check account)' -ErrorAction Stop | Out-Null
            Ok 'account' "$name made"
        }
        $nsid = Get-CheckSid $name
        if (-not ((Get-CheckAdmins) -contains $nsid)) { Add-LocalGroupMember -SID $script:AdminsSid -Member $nsid -ErrorAction Stop }
        if (-not ((Get-CheckAdmins) -contains $nsid)) { throw "$name could not be made an administrator" }
        Ok 'admin' "$name is an administrator"
        # 2: the password really opens the account, read back from Windows, before anything is taken away
        if (-not (Test-CheckPassword $name $p1)) { throw "Windows does not accept that password for $name" }
        Ok 'password' "works for $name"
    } catch { Say ("  FAIL  {0}" -f $_.Exception.Message) 'Red'; Say "  $short is still an administrator: nothing was taken away." 'Red'; return }
    finally { $p1 = $null; $p2 = $null }
    Say ""
    Say "  last step: $short stops being an administrator. have you written the password down?"
    $a = Read-Line "  type YES to make $short a standard account > "
    if ($a.Trim() -ne 'YES') { Say "  stopped here. $short is still an administrator; $name stays. run  check account  again any time."; return }
    try { Remove-LocalGroupMember -SID $script:AdminsSid -Member (Get-CheckSid $u) -ErrorAction Stop } catch { Say ("  FAIL  {0}" -f $_.Exception.Message) 'Red'; return }
    if (Test-CheckIsAdmin $u) { Say "  FAIL  $short is still an administrator" 'Red'; return }
    Ok 'daily' "$short is a standard account"
    Say ""
    Say "  Account is Changed Successfully." 'Green'
    Say "  sign out and in again (or restart) for it to count. after that, typing  guard  asks for $name's password."
}

function Cmd-Check([string]$Arg) {
    switch ($Arg.Trim().ToLower()) {
        ''        { Show-GuardChecks (Get-GuardChecks) }
        'fix'     { Cmd-CheckFix }
        'account' { Cmd-CheckAccount }
        default   { Say "  check, check fix or check account" 'Red' }
    }
}
