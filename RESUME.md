# Resume — test status

All of guard is built and verified on this PC (2026-11-17, admin session).

| Suite | Needs admin | Result |
|---|---|---|
| `src\test-core.ps1` | no | 13 / 13 |
| `src\test-config.ps1` | no | 10 / 10 |
| `src\test-shell.ps1` | no | 16 / 16 |
| `src\test-watch.ps1` | no | 2 / 2 |
| `src\verify-agent.ps1` | yes | 11 / 11 |
| `src\verify-e2e.ps1` | yes | 137 / 137 |

Run the unit suites with `src\run-tests.ps1`. When elevated, it switches the admin-only test flag
(HKLM `GUARD_TEST=1`) on for the run and always off again.

`verify-e2e.ps1` is the full life on a real PC. It:
- installs into Program Files with the SYSTEM task;
- runs init twice;
- checks that the SYSTEM background guard locks new files and subfolders and leaves `.crdownload` alone;
- runs non-admin attacks;
- covers edit and resume (also `all`), skip, delete, move folder, help and typos;
- updates to a fake 1.1;
- runs uninstall;
- reinstalls and restores from `_guard.json`;
- runs remove all and a final uninstall, leaving the PC clean.

Run admin suites from an elevated terminal:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\ojhas\Desktop\Folder_Safety_Guard\src\verify-e2e.ps1"
```

Not testable here:
- **The logon trigger after a real restart.** The task is registered `AtLogOn` and is started by hand in tests.
- **The GitHub download path.** This only works after a push.

Notes:
- `src\*.ps1` must be saved UTF-8 **with** BOM, because PowerShell 5.1 reads `-File` scripts as ANSI otherwise.
- `install.ps1` must stay **pure ASCII with no BOM**, because through `irm | iex` a BOM breaks its `param()` block.
- Re-encode after any edit.
- `install.ps1` lives in the repo root (the install line points there); everything else is in `src/`.
