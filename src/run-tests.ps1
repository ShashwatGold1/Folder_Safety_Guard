# run-tests.ps1 — runs the 4 unit suites on fresh copies of testing_env.
# Elevated: turns on HKLM GUARD_TEST=1 for the run (guard ignores test overrides like
# GUARD_CONFIG in admin processes without it) and always turns it off again.
$src  = Split-Path -Parent $MyInvocation.MyCommand.Path
$tenv = Join-Path (Split-Path $src -Parent) 'testing_env'
$key  = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$admin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Reset {
    foreach ($d in 'shots','docs','sub') { $p = Join-Path $tenv $d; if (Test-Path $p) { icacls $p /reset /T /C *> $null; Remove-Item $p -Recurse -Force -EA SilentlyContinue } }
    if (Test-Path $tenv) { icacls $tenv /reset *> $null }
    New-Item -ItemType Directory (Join-Path $tenv 'shots'),(Join-Path $tenv 'docs'),(Join-Path $tenv 'sub\inner') -Force | Out-Null
    'png1' | Set-Content (Join-Path $tenv 'shots\amazon-checkout.png')
    'png2' | Set-Content (Join-Path $tenv 'shots\gumroad-settings.png')
    'png3' | Set-Content (Join-Path $tenv 'shots\godaddy-dns.png')
    'bak'  | Set-Content (Join-Path $tenv 'shots\old.bak')
    'doc1' | Set-Content (Join-Path $tenv 'docs\notes.txt')
    'doc2' | Set-Content (Join-Path $tenv 'docs\report.md')
    'sub1' | Set-Content (Join-Path $tenv 'sub\a.png')
}

if ($admin) { $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($key, $true); $k.SetValue('GUARD_TEST', '1'); $k.Close() }
try {
    foreach ($t in 'test-core.ps1','test-config.ps1','test-shell.ps1','test-watch.ps1','test-release.ps1','test-check.ps1','test-vault.ps1') {
        Reset
        Write-Host "`n######## $t ########" -ForegroundColor Magenta
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $src $t) 2>&1 | Where-Object { "$_" -match 'PASS|FAIL|passed' } | ForEach-Object { "$_" }
    }
    Reset
} finally {
    if ($admin) { $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($key, $true); $k.DeleteValue('GUARD_TEST', $false); $k.Close() }
}
