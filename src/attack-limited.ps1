# attack-limited.ps1 — runs WITHOUT admin (limited token). Tries every way an agent could
# get rid of a protected file. Every attempt must fail. Writes results to a log.
param([string]$Folder, [string]$Log, [string]$Target = 'secret.png')
$ErrorActionPreference = 'Continue'
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$admin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$out = @("user: $($id.Name)", "admin: $admin", "target: $Target")
$f = Join-Path $Folder $Target
$u = $id.Name

function Attempt($name, [scriptblock]$sb) {
    try { & $sb 2>&1 | Out-Null } catch { }
    $script:out += $name
}

# 1 plain delete
try { Remove-Item -LiteralPath $f -Force -ErrorAction Stop; $out += 'delete file: SUCCEEDED (BAD)' } catch { $out += 'delete file: blocked' }
# 2 cmd del
cmd /c del /f /q "$f" 2>&1 | Out-Null
if (Test-Path $f) { $out += 'cmd del: blocked' } else { $out += 'cmd del: SUCCEEDED (BAD)' }
# 3 rename file
try { Rename-Item -LiteralPath $f -NewName 'x.png' -ErrorAction Stop; $out += 'rename file: SUCCEEDED (BAD)' } catch { $out += 'rename file: blocked' }
# 4 remove the deny with icacls
$r = icacls "$f" /remove:d "$u" 2>&1; $out += ("icacls remove deny: " + $(if ($LASTEXITCODE -eq 0) { 'SUCCEEDED (BAD)' } else { 'blocked' }))
# 5 grant self Full Control
$r = icacls "$f" /grant "${u}:F" 2>&1; $out += ("icacls grant self F: " + $(if ($LASTEXITCODE -eq 0) { 'SUCCEEDED (BAD)' } else { 'blocked' }))
# 6 take ownership
$r = takeown /f "$f" 2>&1; $out += ("takeown: " + $(if ($LASTEXITCODE -eq 0) { 'SUCCEEDED (BAD)' } else { 'blocked' }))
# 7 reset ACL
$r = icacls "$f" /reset 2>&1; $out += ("icacls reset: " + $(if ($LASTEXITCODE -eq 0) { 'SUCCEEDED (BAD)' } else { 'blocked' }))
# 8 delete whole folder
try { Remove-Item -LiteralPath $Folder -Recurse -Force -ErrorAction Stop; $out += 'delete folder: SUCCEEDED (BAD)' } catch { $out += 'delete folder: blocked' }
# 9 rename folder
try { Rename-Item -LiteralPath $Folder -NewName 'owntest-x' -ErrorAction Stop; $out += 'rename folder: SUCCEEDED (BAD)' } catch { $out += 'rename folder: blocked' }
# 10 overwrite-then-shrink (data destroy without delete) — allowed by design (Modify), recorded
# 11 normal use must still work: read the file, add a new file
try { $null = Get-Content -LiteralPath $f -ErrorAction Stop; $out += 'read file: ok' } catch { $out += 'read file: FAILED (BAD)' }
try { Set-Content -LiteralPath (Join-Path $Folder 'agent-new.png') 'n' -ErrorAction Stop; $out += 'add new file: ok' } catch { $out += 'add new file: FAILED (BAD)' }
# 12 a file the agent itself just created: can it remove its lock after guard locks it? (checked later)
$out += 'file still exists: ' + (Test-Path $f)
$out += 'DONE'
$out | Set-Content -LiteralPath $Log