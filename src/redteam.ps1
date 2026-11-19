# redteam.ps1 - RUN ELEVATED. Attacks guard the way a hostile program WITHOUT admin rights would
# (an AI agent in a normal terminal, malware): every attack must fail. Each attack really runs
# in a separate limited process of this user (a scheduled task, RunLevel Limited), and the
# "elevated program" side runs as an elevated task whose environment Windows builds from the
# user's registry, exactly like any elevated program in an administrator account.
# Uses the source next to this file. guard must NOT be installed on this PC: the attacks use the
# real C:\ProgramData\guard and Program Files folders.
$ErrorActionPreference = 'Continue'
$src  = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path $src -Parent
$pass = 0; $fail = 0
function Check($n, $c) { if ($c) { Write-Host "  PASS  $n" -ForegroundColor Green; $script:pass++ } else { Write-Host "  FAIL  $n" -ForegroundColor Red; $script:fail++ } }
function Info($t) { Write-Host "  info  $t" -ForegroundColor DarkGray }
function Section($t) { Write-Host "`n== $t ==" -ForegroundColor Cyan }

$me = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($me)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Write-Host 'NOT ELEVATED' -ForegroundColor Red; return }
$user = $me.Name
$pd = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList').GetValue('ProgramData')
$data = Join-Path $pd 'guard'
if ((Test-Path 'C:\Program Files\guard\guard.ps1') -or (Test-Path -LiteralPath (Join-Path $data 'config.json'))) { Write-Host '  guard is installed here - uninstall it first (this test uses its real folders)' -ForegroundColor Red; return }

$work = Join-Path $repo ('testing_env\redteam-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $work -Force | Out-Null
$psExe = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'

function Run-As([ValidateSet('Limited', 'Highest')][string]$Level, [string]$Code, [int]$Sec = 40) {
    # runs $Code in a new PowerShell as this user, as a scheduled task; returns what it logged
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $ps1 = Join-Path $work "task-$id.ps1"; $log = Join-Path $work "task-$id.log"
    $body = "`$log = '$log'`n`$ErrorActionPreference = 'Continue'`n" + $Code + "`n'DONE' | Add-Content -LiteralPath `$log"
    [IO.File]::WriteAllText($ps1, $body, (New-Object Text.UTF8Encoding($true)))
    $act = New-ScheduledTaskAction -Execute $psExe -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ps1`""
    $pr  = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel $Level
    Register-ScheduledTask -TaskName "guard-redteam-$id" -Action $act -Principal $pr -Force | Out-Null
    Start-ScheduledTask -TaskName "guard-redteam-$id"
    for ($i = 0; $i -lt $Sec * 4; $i++) { Start-Sleep -Milliseconds 250; if ((Test-Path $log) -and ((Get-Content $log -Raw) -match 'DONE')) { break } }
    Unregister-ScheduledTask -TaskName "guard-redteam-$id" -Confirm:$false -EA SilentlyContinue
    Remove-Item $ps1 -Force -EA SilentlyContinue
    if (Test-Path $log) { $r = @(Get-Content $log); Remove-Item $log -Force -EA SilentlyContinue; return $r }
    return @('NO LOG')
}

try {
    # -----------------------------------------------------------------------------------------
    Section 'installer: the file swapped while Windows asks for admin rights'
    # Get-StagedRun exactly as install.ps1 ships it (taken out of the file, not copied by hand)
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'install.ps1'), [ref]$null, [ref]$null)
    $fn = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-StagedRun' }, $true) | Select-Object -First 1
    Check 'install.ps1 has Get-StagedRun (the elevated side checks the file first)' ($null -ne $fn)
    if ($fn) {
        . ([scriptblock]::Create($fn.Extent.Text))
        $victim = Join-Path $work 'victim-install.ps1'; $mark = Join-Path $work 'victim-ran.txt'
        $hkey = 'SOFTWARE\guard-redteam'
        # the stand-in installer writes down the arguments it got: a path with a space and an
        # apostrophe, and a switch, must all arrive as they were sent
        Set-Content -LiteralPath $victim -Value "param([string]`$Prefix, [switch]`$NoElevate)`n('original|' + `$Prefix + '|' + `$NoElevate + '|' + `$args.Count) | Set-Content -LiteralPath '$mark'" -Encoding ASCII
        $vargs = @('-Prefix', "C:\Program Files\it's guard", '-NoElevate')
        $cmd = Get-StagedRun $victim $vargs
        # 1 untouched: runs, from a copy in Program Files, which is deleted afterwards
        $p = Start-Process $psExe -ArgumentList $cmd -Wait -PassThru -WindowStyle Hidden
        Check 'untouched installer: runs, and gets every argument as sent' (($p.ExitCode -eq 0) -and ((Get-Content $mark -EA SilentlyContinue) -eq "original|C:\Program Files\it's guard|True|0"))
        Check 'the checked copy in Program Files is deleted afterwards' (-not (Get-ChildItem 'C:\Program Files\guard\staging' -Filter 'install-*.ps1' -EA SilentlyContinue))
        Remove-Item $mark -Force -EA SilentlyContinue
        # 2 the attacker (limited process) swaps the file after the command line was made
        $cmd = Get-StagedRun $victim $vargs
        $r = Run-As Limited ("try { Set-Content -LiteralPath '$victim' -Value `"'attacker' | Set-Content -LiteralPath '$mark'; New-Item 'HKLM:\$hkey' -Force | Out-Null`" -ErrorAction Stop; 'swap: done' | Add-Content `$log } catch { 'swap: failed' | Add-Content `$log }")
        Info ("attacker: " + ($r -join ' | '))
        Check 'a program without admin can change the waiting installer file (the door is real)' ($r -contains 'swap: done')
        $p = Start-Process $psExe -ArgumentList $cmd -Wait -PassThru -WindowStyle Hidden
        Check 'swapped installer: refused (exit 87)' ($p.ExitCode -eq 87)
        Check "swapped installer: the attacker's code did not run" (-not (Test-Path $mark))
        $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($hkey)
        Check "swapped installer: no admin-only change was made (HKLM\$hkey absent)" ($null -eq $k)
        if ($k) { $k.Close(); [Microsoft.Win32.Registry]::LocalMachine.DeleteSubKeyTree($hkey, $false) }
        Remove-Item 'C:\Program Files\guard' -Recurse -Force -EA SilentlyContinue   # only staging was there
    }

    # -----------------------------------------------------------------------------------------
    Section 'C:\ProgramData\guard: files planted by a program without admin rights'
    Remove-Item -LiteralPath $data -Recurse -Force -EA SilentlyContinue
    $fake = (@{ version = '1.0'; current = 0; folders = @(@{ path = 'C:\Users'; name = 'Users'; skip = @('*') }); saved = (Get-Date).ToString('o') } | ConvertTo-Json -Depth 5) -replace "'", "''"
    $r = Run-As Limited ("try { New-Item -ItemType Directory '$data' -Force | Out-Null; Set-Content -LiteralPath '$data\config.json' -Value '$fake' -ErrorAction Stop; 'plant: done' | Add-Content `$log } catch { 'plant: failed ' + `$_.Exception.Message | Add-Content `$log }")
    Info ("attacker: " + ($r -join ' | '))
    Check 'before guard: a program without admin can plant C:\ProgramData\guard\config.json (the door is real)' ($r -contains 'plant: done')
    $r = Run-As Highest (". '$src\guard-core.ps1'; . '$src\guard-config.ps1'`n" +
        "`$x = @(Initialize-GuardDataDir); 'removed: ' + (`$x -join ',') | Add-Content `$log`n" +
        "'planted used: ' + [bool]@((Load-GuardConfig).folders | Where-Object { `$_.path -eq 'C:\Users' }).Count | Add-Content `$log`n" +
        "'owner: ' + (Get-Acl '$data').GetOwner([Security.Principal.SecurityIdentifier]).Value | Add-Content `$log`n" +
        "Save-GuardConfig -Config (New-GuardConfig) -User `$null; 'saved' | Add-Content `$log")
    Info ("guard: " + ($r -join ' | '))
    Check 'guard removes the planted config.json' ($r -contains 'removed: config.json')
    Check 'guard does not use the planted config' ($r -contains 'planted used: False')
    Check 'the data folder is owned by Administrators' ($r -contains 'owner: S-1-5-32-544')
    $usersWrite = @((Get-Acl $data).Access | Where-Object { $_.IdentityReference -match 'Users|Everyone|Authenticated' -and ($_.FileSystemRights.ToString() -match 'Write|Modify|FullControl|CreateFiles|AppendData') }).Count
    Check 'no write permission for normal users is left on the data folder' ($usersWrite -eq 0)
    $r = Run-As Limited ("try { Set-Content -LiteralPath '$data\evil.txt' 'x' -ErrorAction Stop; 'create: SUCCEEDED' | Add-Content `$log } catch { 'create: blocked' | Add-Content `$log }`n" +
        "try { Set-Content -LiteralPath '$data\config.json' 'x' -ErrorAction Stop; 'overwrite: SUCCEEDED' | Add-Content `$log } catch { 'overwrite: blocked' | Add-Content `$log }`n" +
        "try { New-Item -ItemType Directory '$data\sub' -ErrorAction Stop | Out-Null; 'mkdir: SUCCEEDED' | Add-Content `$log } catch { 'mkdir: blocked' | Add-Content `$log }")
    Info ("attacker: " + ($r -join ' | '))
    Check 'after guard: a new file can not be planted' ($r -contains 'create: blocked')
    Check "after guard: guard's config.json can not be changed" ($r -contains 'overwrite: blocked')
    Check 'after guard: no folder can be made inside' ($r -contains 'mkdir: blocked')
    # a config.json owned by a normal user (planted before guard protected the folder) is ignored
    Set-Content -LiteralPath "$data\config.json" -Value ($fake -replace "''", "'")
    icacls "$data\config.json" /setowner $user *> $null
    $r = Run-As Highest (". '$src\guard-core.ps1'; . '$src\guard-config.ps1'`n'planted used: ' + [bool]@((Load-GuardConfig).folders | Where-Object { `$_.path -eq 'C:\Users' }).Count | Add-Content `$log")
    Check "a config.json owned by a normal user is ignored" ($r -contains 'planted used: False')
    Remove-Item -LiteralPath $data -Recurse -Force -EA SilentlyContinue

    # -----------------------------------------------------------------------------------------
    Section 'environment variables: fake folders for the elevated guard'
    $fakePd = Join-Path $work 'fake-programdata'
    # (only ProgramData, and only for a few seconds: programs started meanwhile see it too)
    $r = Run-As Limited ("[Environment]::SetEnvironmentVariable('ProgramData', '$fakePd', 'User'); 'set' | Add-Content `$log")
    try {
        $r = Run-As Highest ("'env ProgramData: ' + `$env:ProgramData | Add-Content `$log`n" +
            ". '$src\guard-core.ps1'; . '$src\guard-config.ps1'`n" +
            "'config: ' + `$script:GuardConfigPath | Add-Content `$log`n'windows: ' + (Get-GuardWindowsDir) | Add-Content `$log`n'icacls: ' + (Get-GuardTool 'icacls.exe') | Add-Content `$log")
        Info ("elevated: " + ($r -join ' | '))
        Check 'the attack reached the elevated program (its ProgramData is the fake one)' ($r -contains "env ProgramData: $fakePd")
        Check 'guard still uses the real config path' ($r -contains "config: $pd\guard\config.json")
        Check 'guard still uses the real Windows folder' ($r -contains ('windows: ' + (Split-Path ([Environment]::SystemDirectory) -Parent)))
        Check 'guard still runs the real icacls' ($r -contains ('icacls: ' + (Join-Path ([Environment]::SystemDirectory) 'icacls.exe')))
    } finally {
        $null = Run-As Limited ("[Environment]::SetEnvironmentVariable('ProgramData', `$null, 'User'); 'cleared' | Add-Content `$log")
    }

    # -----------------------------------------------------------------------------------------
    Section 'PowerShell modules planted in Documents'
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $modRoot = Join-Path $docs 'WindowsPowerShell\Modules'
    $hadRoot = Test-Path $modRoot
    $planted = Join-Path $modRoot 'ScheduledTasks'
    $pmark = Join-Path $work 'planted-module-ran.txt'
    $psm = "function Get-ScheduledTask { 'planted module ran' | Set-Content -LiteralPath '$pmark' }`nExport-ModuleMember -Function Get-ScheduledTask"
    $r = Run-As Limited ("New-Item -ItemType Directory '$planted' -Force | Out-Null; Set-Content -LiteralPath '$planted\ScheduledTasks.psm1' -Value @'`n$psm`n'@; 'planted' | Add-Content `$log")
    try {
        $null = Run-As Highest ("Get-ScheduledTask -TaskName 'guard-redteam-none' -ErrorAction SilentlyContinue | Out-Null")
        Check 'the attack is real: an elevated PowerShell runs the planted ScheduledTasks module' (Test-Path $pmark)
        Remove-Item $pmark -Force -EA SilentlyContinue
        $null = Run-As Highest (". '$src\guard-core.ps1'`nGet-ScheduledTask -TaskName 'guard-redteam-none' -ErrorAction SilentlyContinue | Out-Null")
        Check 'guard (elevated) does not run the planted module' (-not (Test-Path $pmark))
    } finally {
        Remove-Item $planted -Recurse -Force -EA SilentlyContinue
        if (-not $hadRoot) { Remove-Item (Join-Path $docs 'WindowsPowerShell') -Recurse -Force -EA SilentlyContinue }
    }

    # -----------------------------------------------------------------------------------------
    Section 'a planted _guard.json (memory) asks guard to restore'
    $tf = Join-Path $work 'restore-me'; New-Item -ItemType Directory $tf -Force | Out-Null; Set-Content "$tf\secret.txt" 'x'
    $mem = [pscustomobject]@{ folders = @([pscustomobject]@{ path = (Split-Path ([Environment]::SystemDirectory) -Parent); name = 'Windows'; skip = @() },
                                         [pscustomobject]@{ path = $tf; name = 'restore-me'; skip = @('*') }); saved = (Get-Date).ToString('o') }
    $script:GuardConfigPath = Join-Path $work 'cfg\config.json'
    . "$src\guard-shell.ps1"; $ErrorActionPreference = 'Continue'
    $user = $me.Name   # guard-shell sets $script:User = $null, and $user is that same variable
    $script:User = $user; $script:Cfg = New-GuardConfig
    $script:InputQueue = New-Object System.Collections.Queue; $script:InputQueue.Enqueue('1')
    $out = (Invoke-GuardRestore -Memory $mem -Where 'test' 6>&1 | Out-String)
    Check 'restore refuses the Windows folder' ($out -match 'ignored\s+C:\\Windows')
    Check 'restore takes only the real folder' ((@($script:Cfg.folders).Count -eq 1) -and ($script:Cfg.folders[0].path -eq $tf))
    Check "a planted skip list ('*') is not taken over" (@($script:Cfg.folders[0].skip).Count -eq 0)
    $locked = $false; try { Remove-Item "$tf\secret.txt" -Force -EA Stop } catch { $locked = $true }
    Check 'the file in the restored folder is locked' $locked
    Unlock-GuardTree -Folder $tf -User $user | Out-Null; Set-GuardOwnerUser -Folder $tf -User $user | Out-Null

    # -----------------------------------------------------------------------------------------
    Section 'no elevated code reads paths from environment variables or runs from Temp'
    $hits = @(Select-String -Path (Join-Path $src 'guard*.ps1'), (Join-Path $repo 'install.ps1') -Pattern '\$env:(TEMP|TMP|WINDIR|SystemRoot|ProgramData|ProgramFiles|SystemDrive)\b|GetTempPath|''powershell\.exe''|Start-Process powershell|Start-Process explorer' |
              Where-Object { $_.Line -notmatch '^\s*#' -and $_.Line -notmatch "Name='powershell\.exe'" })   # (a process-list filter, not a launch)
    # the only one allowed: the non-elevated window that runs  irm | iex  writes the installer
    # to its own Temp before asking for admin rights (the elevated side then checks it)
    $bad = @($hits | Where-Object { -not ($_.Filename -eq 'install.ps1' -and $_.Line -match "guard-install-") })
    foreach ($h in $bad) { Info ("{0}:{1}: {2}" -f $h.Filename, $h.LineNumber, $h.Line.Trim()) }
    Check 'only the allowed Temp use is left' ($bad.Count -eq 0)
} finally {
    icacls $work /reset /T /C *> $null
    Remove-Item $work -Recurse -Force -EA SilentlyContinue
    Remove-Item -LiteralPath $data -Recurse -Force -EA SilentlyContinue
    Get-ScheduledTask -TaskName 'guard-redteam-*' -EA SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -EA SilentlyContinue
}

$color = 'Green'; if ($fail) { $color = 'Red' }
Write-Host "`n$pass passed, $fail failed" -ForegroundColor $color
