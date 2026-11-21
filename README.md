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

Once the publisher has set up the release key, guard installs and
updates only a signed release (until then: as before, unsigned): a list of every
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

For secrets (passwords, documents nobody may read):

    security vault on

Asks for your PIN once (the first time you choose it and get a
recovery code for paper). Then every protected folder is sealed:
each file is encrypted and kept where only guard can reach it, and
an empty placeholder with the same name stays in its place, with a
blue shield badge. Nobody (you, Explorer, AI agents, other
programs, even an administrator) can read a sealed file without the
PIN. New files you save there are sealed by themselves.

To use a file: right-click it, Unlock with guard, Yes, PIN. Only
that file comes back. Every change is sealed within 5 seconds, and
it locks again by itself 15 minutes after you opened it (once no
program uses it) and at every sign-in.

    security vault off   PIN, then every file is a normal one again

While a file is unlocked, programs you run can read that one file.
Don't unlock files with an AI agent running.

Inside guard:
- delete <name>  delete something on purpose
- edit / resume  unlock for a while / lock again
- security vault on / off   seal / unseal every protected folder
- check          this PC's safety settings (check fix, check account)
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

## Signing releases (only the publisher)

Only the owner of this GitHub repo runs this. People who install
guard never do: install and update check the signature by
themselves.

Why it can't be automated: the PIN is the one step only a human can
do. If a program could sign, a hijacked AI agent could sign bad code
too. Everything else (making the key, hashing every file, checking,
committing, pushing) is automatic.

Right now no release key is set up, so install and update take the
newest code from GitHub unsigned. After the setup below, they accept
only releases you signed.

Open a normal PowerShell (not as administrator) and go to the repo:

    cd C:\Users\ojhas\Desktop\Folder_Safety_Guard

Once, ever (makes the key in this PC's TPM chip):

    .\src\guard-sign.ps1 -Setup

Click Yes, then choose a PIN and type it twice. It must be at least
12 characters, for example  555555555555  (don't use this one for
real). Write it on paper: it can't be reset or recovered, and a new
key means every guard must be reinstalled.

Every time you want people to get a new version:

    .\src\guard-sign.ps1

Click Yes. It shows the version and what changed; type YES, then
your PIN. It signs and pushes by itself. Until you sign, everyone
stays on the last signed version, even if new code is pushed.

Command Prompt (cmd) runs the same thing through PowerShell (also
works where scripts are blocked):

    cd C:\Users\ojhas\Desktop\Folder_Safety_Guard
    powershell -NoProfile -ExecutionPolicy Bypass -File .\src\guard-sign.ps1 -Setup
    powershell -NoProfile -ExecutionPolicy Bypass -File .\src\guard-sign.ps1
