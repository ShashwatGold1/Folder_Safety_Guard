# test-shell.ps1 — drives command handlers non-interactively. No admin (current user as owner).
$script:GuardConfigPath = Join-Path $env:TEMP ('guardtest-' + [guid]::NewGuid().ToString('N') + '\config.json')
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
Invoke-GuardCommand "init $shots" | Out-Null
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
Invoke-GuardCommand "remove" | Out-Null   # removes docs (current=2)
Check "docs removed from config"     ($script:Cfg.folders.Count -eq 1)
Check "docs files now deletable"     (TryDelete (Join-Path $docs 'notes.txt'))
Check "docs _guard.json gone"        (-not (Test-Path (Join-Path $docs '_guard.json')))

Write-Host "`n== cleanup: remove all, verify unlocked ==" -ForegroundColor Cyan
Feed @()
Invoke-GuardCommand "remove all" | Out-Null
Check "no folders left"              ($script:Cfg.folders.Count -eq 0)
Check "shots fully unlocked"         (TryDelete $shots)

# restore folder structure for re-runs
Remove-Item -LiteralPath (Split-Path $script:GuardConfigPath -Parent) -Recurse -Force -EA SilentlyContinue
$color='Green'; if($script:fail){$color='Red'}
Write-Host "`n$($script:pass) passed, $($script:fail) failed" -ForegroundColor $color