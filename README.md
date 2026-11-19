# guard

Protects folders on Windows from being deleted, including
Shift+Delete and AI agents running on your PC. It uses Windows
permissions, so it keeps working long after you set it up.

## Install

PowerShell :

    irm https://raw.githubusercontent.com/ShashwatGold1/Folder_Safety_Guard/main/install.ps1 | iex

Command Prompt (cmd) :

    powershell -NoProfile -Command "irm https://raw.githubusercontent.com/ShashwatGold1/Folder_Safety_Guard/main/install.ps1 | iex"

Click Yes on the Windows prompt (UAC must be on). Everything runs
in the same window.

guard installs and updates only a signed release: a list of every
file's SHA-256, signed with a key inside the publisher's TPM chip
(PIN + admin rights to use, can't be copied out). A changed file, a
changed list or a list signed with any other key is refused, so
someone who breaks into the GitHub account, or an AI agent pushing
code, can't ship anything guard runs.

## Use

Type  guard , click Yes. guard opens in a window of its own: only
programs with admin rights can type into it, so an AI agent can't
type commands for you. Then:

    init

The folder, the folder above it and every file inside can no
longer be deleted or renamed. New files are locked as soon as
they finish saving. Opening, editing and saving still work.

In Explorer, a badge in the bottom-left corner shows the state
of every protected folder and file: green lock = protected,
orange lock = unlocked for editing, red ! = partly locked.

Inside guard:
- delete <name>  delete something on purpose
- edit / resume  unlock for a while / lock again
- help           every command
- Tab            completes commands, file names and paths

## Notes

- Never run AI agents in an administrator terminal. A program
  started from one can unlock files.
- guard stops deletion, not changes to what's inside a file.
- uninstall  unlocks everything and removes guard. Your files
  stay on the disk.

Tests: src/run-tests.ps1, src/verify-e2e.ps1 (admin), src/redteam.ps1
(admin: attacks guard from a program without admin rights; every
attack must fail).

Publishing (maintainer): in a normal terminal in the repo,
src/guard-sign.ps1 -Setup once (makes the TPM key, asks a new PIN),
then src/guard-sign.ps1 for every release (asks admin, shows what it
signs, needs YES + the PIN).
