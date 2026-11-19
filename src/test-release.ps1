# test-release.ps1 - signed releases: only a list signed with the release key is taken, and only
# files whose hash is in it. A software test key and a fake "GitHub" folder (file://). No admin.
. "$PSScriptRoot\guard-sign.ps1" -Lib
$ErrorActionPreference = 'Continue'
$pass = 0; $fail = 0
function Check($n, $c) { if ($c) { Write-Host "  PASS  $n" -ForegroundColor Green; $script:pass++ } else { Write-Host "  FAIL  $n" -ForegroundColor Red; $script:fail++ } }
$repo = Split-Path $PSScriptRoot -Parent
$tmp = Join-Path $env:TEMP ('guard-rel-' + [guid]::NewGuid().ToString('N'))
$rsa = New-Object Security.Cryptography.RSACng 2048
$key = [Convert]::ToBase64String($rsa.ExportParameters($false).Modulus)
$sign = { param([byte[]]$d) $rsa.SignData($d, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1) }
$evil = New-Object Security.Cryptography.RSACng 2048
$evilSign = { param([byte[]]$d) $evil.SignData($d, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1) }
$files = @{}; foreach ($f in Get-GuardReleaseFiles) { $files[$f] = [IO.File]::ReadAllBytes((Join-Path $repo $f)) }
$commit = ('ab' * 20)
function Use-Release([string]$Name) { $d = Join-Path $tmp $Name; $env:GUARD_RELEASE_URL = ([Uri]$d).AbsoluteUri; return $d }
$env:GUARD_RELEASE_KEY = $key

try {
    Write-Host "== a signed release ==" -ForegroundColor Cyan
    $d = Use-Release 'good'; New-GuardReleaseFolder $d $commit $files '9.1' $sign
    $r = Get-GuardRelease
    Check 'signed list is taken' ($r.Ok -and $r.Release.version -eq '9.1' -and $r.Release.commit -eq $commit)
    Check 'remote version = the signed one' ((Get-GuardRemoteVersion) -eq '9.1')
    $out = Join-Path $tmp 'out-good'; New-Item -ItemType Directory $out -Force | Out-Null
    $err = $null; try { Save-GuardReleaseFiles $r.Release $out } catch { $err = $_.Exception.Message }
    Check 'all files downloaded and checked' (-not $err -and (Get-GuardSha256 ([IO.File]::ReadAllBytes("$out\guard-core.ps1"))) -eq (Get-GuardSha256 $files['src/guard-core.ps1']))
    Check 'every runtime file is in the release' ((@(Get-GuardReleaseFiles) | Where-Object { -not (Test-Path (Join-Path $out (Split-Path $_ -Leaf))) }).Count -eq 0)

    Write-Host "`n== hacked GitHub: a file changed after signing ==" -ForegroundColor Cyan
    [IO.File]::AppendAllText((Join-Path $d "$commit\src\guard-watch.ps1"), "`n# evil")
    $out2 = Join-Path $tmp 'out-bad'; New-Item -ItemType Directory $out2 -Force | Out-Null
    $err = $null; try { Save-GuardReleaseFiles $r.Release $out2 } catch { $err = $_.Exception.Message }
    Check 'changed file refused' ($err -match "guard-watch.ps1 from GitHub doesn't match")

    Write-Host "`n== hacked GitHub: the list itself ==" -ForegroundColor Cyan
    $d = Use-Release 'edited'; New-GuardReleaseFolder $d $commit $files '9.1' $sign
    $j = [IO.File]::ReadAllText("$d\main\release.json") -replace '"9\.1"', '"9.9"'; [IO.File]::WriteAllText("$d\main\release.json", $j)
    $r = Get-GuardRelease
    Check 'edited list refused' (-not $r.Ok -and -not $r.Offline -and $r.Why -match 'not signed')
    $d = Use-Release 'evilkey'; New-GuardReleaseFolder $d $commit $files '9.9' $evilSign
    $r = Get-GuardRelease
    Check "list signed with another key refused" (-not $r.Ok -and $r.Why -match 'not signed')
    $d = Use-Release 'nosig'; New-GuardReleaseFolder $d $commit $files '9.9' $sign; [IO.File]::WriteAllText("$d\main\release.sig", 'AAAA')
    Check 'garbage signature refused' (-not (Get-GuardRelease).Ok)
    $d = Use-Release 'badcommit'; New-GuardReleaseFolder $d 'main' $files '9.9' $sign
    Check "signed list with a branch name instead of a commit refused" ((Get-GuardRelease).Why -match 'malformed')

    Write-Host "`n== no key, offline ==" -ForegroundColor Cyan
    $d = Use-Release 'good'
    $env:GUARD_RELEASE_KEY = ''
    $r = Get-GuardRelease
    Check 'guard without a release key takes nothing' (-not $r.Ok -and $r.Why -match 'no release key')
    $env:GUARD_RELEASE_KEY = $key
    $env:GUARD_RELEASE_URL = ([Uri](Join-Path $tmp 'nothing-here')).AbsoluteUri
    $r = Get-GuardRelease
    Check 'offline: says so' (-not $r.Ok -and $r.Offline)
    Check 'offline: no version' ($null -eq (Get-GuardRemoteVersion))

    Write-Host "`n== the code ==" -ForegroundColor Cyan
    $k = Get-CodeKeys ([IO.File]::ReadAllText("$repo\src\guard-core.ps1")) ([IO.File]::ReadAllText("$repo\install.ps1"))
    Check 'install.ps1 and guard-core.ps1 have the same release key' ($k[0] -ceq $k[1])
    Check 'the test key overrides only in test mode (non-admin here)' ((Get-GuardReleaseKey) -eq $key)
} finally {
    $env:GUARD_RELEASE_URL = ''; $env:GUARD_RELEASE_KEY = ''
    Remove-Item $tmp -Recurse -Force -EA SilentlyContinue
}
Write-Host "`n$pass passed, $fail failed"
