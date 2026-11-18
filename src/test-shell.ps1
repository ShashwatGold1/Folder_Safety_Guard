# test-shell.ps1 — drives command handlers non-interactively. No admin (current user as owner).
$script:GuardConfigPath = Join-Path $env:TEMP ('guardtest-' + [guid]::NewGuid().ToString('N') + '\config.json')
$env:GUARD_NOBROWSER = '1'   # edit must not open Explorer windows during tests
. "$PSScriptRoot\guard-shell.ps1"

$ErrorActionPreference = 'Continue'
$root  = "C:\Users\ojhas\Desktop\Folder_Safety_Guard\testing_env"
$shots = Join-Path $root 'shots'
$docs  = Join-Path $root 'docs'
$script:User = Get-GuardUser
$script:Cfg  = New-GuardConfig
$script:pass = 0; $script:fail = 0
function Check($n,$c){ if($c){Write-Host "  PASS  $n" -ForegroundColor Green;$script:pass++}else{Write-Host "  FAIL  $n" -ForegroundColor Red;$script:fail++} }
function Feed([string[]]$answers){ $script:InputQueue = New-Object System.Collections.Queue; foreach($a in $answers){ $script:InputQueue.Enqueue($a) } }
function TryDelete($p){ try { Remove-Item -LiteralPath $p -Force -Recurse -EA Stop; $true } catch { $false } }

Write-Host "== init shots (no path given variant uses arg) ==" -ForegroundColor Cyan
Feed @()
Invoke-GuardCommand "init `"$shots`"" | Out-Null   # quoted, as  init "C:\My Folder"
Check "shots added to config"        ($script:Cfg.folders.Count -eq 1)
Check "current is shots"             ((Cur).path -eq $shots)
Check "shots .png locked on disk"    (-not (TryDelete (Join-Path $shots 'gumroad-settings.png')))
Check "_guard.json exists"           (Test-Path (Join-Path $shots '_guard.json'))

Write-Host "`n== skip *.bak unlocks matching ==" -ForegroundColor Cyan
Invoke-GuardCommand "skip *.bak" | Out-Null
Check "*.bak now deletable"          (TryDelete (Join-Path $shots 'old.bak'))
Check "skip saved to folder"         ((Cur).skip -contains '*.bak')

Write-Host "`n== delete one file by name (confirm yes) ==" -ForegroundColor Cyan
Feed @('1')   # confirm yes
Invoke-GuardCommand "delete godaddy" | Out-Null
Check "godaddy-dns.png gone"         (-not (Test-Path (Join-Path $shots 'godaddy-dns.png')))

Write-Host "`n== edit unlocks, resume re-locks ==" -ForegroundColor Cyan
Invoke-GuardCommand "edit" | Out-Null
Check "after edit, file deletable"   (TryDelete (Join-Path $shots 'amazon-checkout.png'))
Invoke-GuardCommand "resume" | Out-Null
# add a fresh file, resume already ran; lock it via resume again
Set-Content (Join-Path $shots 'fresh.png') 'f'
Invoke-GuardCommand "resume" | Out-Null
Check "after resume, fresh file locked" (-not (TryDelete (Join-Path $shots 'fresh.png')))

Write-Host "`n== init docs, folders, use, remove ==" -ForegroundColor Cyan
Invoke-GuardCommand "init $docs" | Out-Null
Check "two folders now"              ($script:Cfg.folders.Count -eq 2)
Invoke-GuardCommand "use 1" | Out-Null
Check "use 1 -> shots current"       ((Cur).path -eq $shots)
Feed @()
Invoke-GuardCommand "use 2" | Out-Null
$st = Show-Status 6>&1 | Out-String
Check "status after a command: only the current folder" (($st -match 'docs') -and -not ($st -match 'folder\s+shots'))
$st = Show-Status -All 6>&1 | Out-String
Check "status -All (start, cls): every folder" (($st -match 'docs') -and ($st -match 'folder\s+shots'))
Check "status shows the newest file" ($st -match 'newest  \S+')
Feed @('2')
Invoke-GuardCommand "remove" | Out-Null   # asks first: answer no
Check "remove asks first: no keeps it" ($script:Cfg.folders.Count -eq 2)
Feed @('1')
Invoke-GuardCommand "remove" | Out-Null   # removes docs (current=2)
Check "docs removed from config"     ($script:Cfg.folders.Count -eq 1)
Check "docs files now deletable"     (TryDelete (Join-Path $docs 'notes.txt'))
Check "docs _guard.json gone"        (-not (Test-Path (Join-Path $docs '_guard.json')))

Write-Host "`n== Tab completion ==" -ForegroundColor Cyan
function Tab([string]$l, [switch]$Paths) { $c = Get-GuardCompletions $l -Paths:$Paths; return @($c.Items | ForEach-Object { $c.Base + $_ }) }
Check "Tab: command name"            (((Tab 'ini') -join '|') -eq 'init')
Check "Tab: several commands cycle"  (((Tab 'e') -join '|') -eq 'edit|exit')
Check "Tab: help <command>"          ((Tab 'help li') -contains 'help list')
$hc = Get-GuardCompletions 'help '
Check "Tab: help = the start table, every row, in order" (($hc.Items.Count -eq $script:TableRows.Count) -and ($hc.Groups[0] -eq 'guard') -and ($hc.Groups[-1] -eq 'current') -and ($hc.Labels[1] -match '^use <n>\s+switch to folder n$'))
$hc = Get-GuardCompletions 'help re'
Check "Tab: help re = resume / remove rows, both sections" ((($hc.Items | Sort-Object -Unique) -join '|') -eq 'remove|resume' -and ($hc.Groups -contains 'all') -and ($hc.Groups -contains 'current'))
Check "Tab: edit all"                (((Tab 'edit a') -join '|') -eq 'edit all')
Check "Tab: init path, folders only" (((Tab "init $root\sh") -join '|') -eq "init $root\shots")
Push-Location $root
Check "Tab: init relative path"      (((Tab 'init do') -join '|') -eq 'init docs')
Pop-Location
Check "Tab: init C: -> C:\"          (((Tab 'init C:') -join '|') -eq 'init C:\')
Check "Tab: a folder path question"  (((Tab "$root\do" -Paths) -join '|') -eq "$root\docs")
Check "Tab: delete <file name>"      ((Tab 'delete gum') -contains 'delete gumroad-settings.png')
Check "Tab: move folder"             ((Tab 'move fo') -contains 'move folder')
Check "Tab: nothing to complete"     (@(Tab 'zzz').Count -eq 0)
Check "Tab: several = filled in as far as they agree" (((Get-CommonStart @('resume','remove')) -eq 're') -and ((Get-CommonStart @('edit','exit')) -eq 'e') -and ((Get-CommonStart @('Docs','docs-old')) -eq 'Docs'))

Write-Host "`n== look ==" -ForegroundColor Cyan
Check "sizes in KB / MB" (((Format-Size 1258291) -eq '1.2 MB') -and ((Format-Size 2048) -eq '2.0 KB') -and ((Format-Size 12) -eq '12 B'))
Check "help: the long table" ((Show-HelpTable 6>&1 | Out-String) -match 'no question asked')
Check "error report has no paths" (-not ((New-GuardIssueUrl -Command 'delete C:\Users\me\x.png' -Message 'Access to C:\Users\me\x.png is denied' -Where 'at Cmd-Delete') -match 'Users'))

Write-Host "`n== cleanup: remove all, verify unlocked ==" -ForegroundColor Cyan
Feed @()
$script:InputQueue = New-Object System.Collections.Queue; $script:InputQueue.Enqueue('YES')   # remove all needs YES
Invoke-GuardCommand "remove all" | Out-Null
Check "no folders left"              ($script:Cfg.folders.Count -eq 0)
Check "next line when nothing is protected" ((Show-Status 6>&1 | Out-String) -match 'next\s+init / init <path>')
Check "shots fully unlocked"         (TryDelete $shots)

# restore folder structure for re-runs
Remove-Item -LiteralPath (Split-Path $script:GuardConfigPath -Parent) -Recurse -Force -EA SilentlyContinue
$color='Green'; if($script:fail){$color='Red'}
Write-Host "`n$($script:pass) passed, $($script:fail) failed" -ForegroundColor $color