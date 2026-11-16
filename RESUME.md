# Resume — elevated verification

Status: all non-admin parts built and passing (core 13, config 10, shell 16, watch 2).
Remaining: one admin session to verify the SYSTEM-ownership lock and the real install.

## When Claude Code is running as administrator
Run:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\ojhas\Desktop\Folder_Safety_Guard\src\verify-elevated.ps1"
```

It installs into `C:\Program Files\guard`, registers the `guard` SYSTEM task, proves SYSTEM owns the
test files and the user can't change the lock, then uninstalls and removes the test folder.

Note: source files must be saved UTF-8 with BOM (PowerShell 5.1). Re-encode after any edit.
After verification: re-run the non-admin suites, commit, push, report results.
