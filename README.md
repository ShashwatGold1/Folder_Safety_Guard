# guard

Protects folders on Windows from being deleted, including
Shift+Delete and AI agents running on your PC. It uses Windows
permissions, so it keeps working long after you set it up.

## Install

PowerShell :

    irm https://raw.githubusercontent.com/ShashwatGold1/Folder_Safety_Guard/main/install.ps1 | iex

Command Prompt (cmd) :

    powershell -NoProfile -Command "irm https://raw.githubusercontent.com/ShashwatGold1/Folder_Safety_Guard/main/install.ps1 | iex"

Click Yes on the Windows prompt (UAC must be on).

## Use

Open a new terminal, type  guard , click Yes, then:

    init

The folder, the folder above it and every file inside can no
longer be deleted or renamed. New files are locked as soon as
they finish saving. Opening, editing and saving still work.

Inside guard:
- delete <name>  delete something on purpose
- edit / resume  unlock for a while / lock again
- help           every command

## Notes

- Never run AI agents in an administrator terminal. A program
  started from one can unlock files.
- guard stops deletion, not changes to what's inside a file.
- uninstall  unlocks everything and removes guard. Your files
  stay on the disk.

Tests: src/run-tests.ps1, src/verify-e2e.ps1 (admin).
