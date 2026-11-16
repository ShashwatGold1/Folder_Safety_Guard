# test-watch.ps1 — full check + live lock of a newly-created file. No admin.
$cfgDir = Join-Path $env:TEMP ('guardw-' + [guid]::NewGuid().ToString('N'))
$env:GUARD_CONFIG = Join-Path $cfgDir 'config.json'
. "$PSScriptRoot\guard-core.ps1"
. "$PSScriptRoot\guard-config.ps1"

$ErrorActionPreference='Continue'
$root="C:\Users\ojhas\Desktop\Folder_Safety_Guard\testing_env"; $shots=Join-Path $root 'shots'
$user = Get-GuardUser
$pass=0;$fail=0
function Check($n,$c){ if($c){Write-Host "  PASS  $n" -ForegroundColor Green;$script:pass++}else{Write-Host "  FAIL  $n" -ForegroundColor Red;$script:fail++} }
function TryDelete($p){ try{Remove-Item -LiteralPath $p -Force -EA Stop;$true}catch{$false} }

# build a config with shots, unlocked
$cfg = New-GuardConfig
$cfg.folders = @([pscustomobject]@{ path=$shots; name='shots'; skip=@('*.bak'); added=(Get-Date).ToString('o') })
Save-GuardConfig -Config $cfg -User $null

Write-Host "== watcher -Once full check locks everything ==" -ForegroundColor Cyan
& "$PSScriptRoot\guard-watch.ps1" -User $user -Once
Check "existing file locked by full check" (-not (TryDelete (Join-Path $shots 'amazon-checkout.png')))

Write-Host "`n== live watch locks a new file ==" -ForegroundColor Cyan
# launch the watcher as a real background process (like the scheduled task does)
# child inherits $env:GUARD_CONFIG from this process
$proc = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @(
    '-NoProfile','-ExecutionPolicy','Bypass','-File',"$PSScriptRoot\guard-watch.ps1",'-User',$user
)
Start-Sleep -Seconds 3
Set-Content (Join-Path $shots 'live-new.png') 'x'
Start-Sleep -Seconds 4
Check "newly-dropped file auto-locked" (-not (TryDelete (Join-Path $shots 'live-new.png')))
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue

# cleanup: unlock everything
Unlock-GuardTree -Folder $shots -User $user | Out-Null
Remove-Item (Join-Path $shots '_guard.json') -Force -EA SilentlyContinue
Remove-Item $cfgDir -Recurse -Force -EA SilentlyContinue
$color='Green';if($fail){$color='Red'}
Write-Host "`n$pass passed, $fail failed" -ForegroundColor $color