# test-config.ps1 — memory read/write/restore. Redirects config to a temp dir (no admin).
$script:GuardConfigPath = Join-Path $env:TEMP ('guardtest-' + [guid]::NewGuid().ToString('N') + '\config.json')
. "$PSScriptRoot\guard-core.ps1"
. "$PSScriptRoot\guard-config.ps1"

$ErrorActionPreference = 'Continue'
$root  = Join-Path (Split-Path $PSScriptRoot -Parent) 'testing_env'
$shots = Join-Path $root 'shots'
$docs  = Join-Path $root 'docs'
$user  = Get-GuardUser
$script:pass = 0; $script:fail = 0
function Check($n,$c){ if($c){Write-Host "  PASS  $n" -ForegroundColor Green;$script:pass++}else{Write-Host "  FAIL  $n" -ForegroundColor Red;$script:fail++} }

Write-Host "== build a config with two folders ==" -ForegroundColor Cyan
$cfg = New-GuardConfig
$cfg.folders = @(
    [pscustomobject]@{ path=$shots; name=(Get-FolderName $shots); skip=@('*.bak'); added=(Get-Date).ToString('o') },
    [pscustomobject]@{ path=$docs;  name=(Get-FolderName $docs);  skip=@();        added=(Get-Date).ToString('o') }
)
$cfg.current = 1
Save-GuardConfig -Config $cfg -User $null   # no lock in this test, just files

Check "master config.json written"      (Test-Path -LiteralPath $script:GuardConfigPath)
Check "_guard.json in shots"             (Test-Path -LiteralPath (Join-Path $shots '_guard.json'))
Check "_guard.json in docs"              (Test-Path -LiteralPath (Join-Path $docs '_guard.json'))
Check "_guard.json is hidden"            ((Get-Item -LiteralPath (Join-Path $shots '_guard.json') -Force).Attributes -band [IO.FileAttributes]::Hidden)

Write-Host "`n== reload from master ==" -ForegroundColor Cyan
$back = Load-GuardConfig
Check "reload: 2 folders"                ($back.folders.Count -eq 2)
Check "reload: current = 1"              ($back.current -eq 1)
Check "reload: shots skip has *.bak"     ($back.folders[0].skip -contains '*.bak')

Write-Host "`n== master lost: rebuild from newest _guard.json ==" -ForegroundColor Cyan
Remove-Item -LiteralPath $script:GuardConfigPath -Force
$rebuilt = Load-GuardConfig
Check "rebuild found a config"           ($null -ne $rebuilt)
Check "rebuild: 2 folders"               ($rebuilt.folders.Count -eq 2)

Write-Host "`n== newest copy wins ==" -ForegroundColor Cyan
Start-Sleep -Milliseconds 20
$cfg2 = New-GuardConfig
$cfg2.folders = @([pscustomobject]@{ path=$shots; name='shots'; skip=@(); added=(Get-Date).ToString('o') })
$cfg2.note = 'newer'
Write-GuardJsonFile -Path (Join-Path $shots '_guard.json') -Config $cfg2
$win = Find-GuardMemory
Check "newest _guard.json chosen (1 folder)" ($win.folders.Count -eq 1)

# cleanup
Remove-Item -LiteralPath (Join-Path $shots '_guard.json') -Force -EA SilentlyContinue
Remove-Item -LiteralPath (Join-Path $docs  '_guard.json') -Force -EA SilentlyContinue
Remove-Item -LiteralPath (Split-Path $script:GuardConfigPath -Parent) -Recurse -Force -EA SilentlyContinue

$color='Green'; if($script:fail){$color='Red'}
Write-Host "`n$($script:pass) passed, $($script:fail) failed" -ForegroundColor $color