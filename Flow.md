# guard — end-to-end flow (v2)

Rules used everywhere below:
- Command table shows only at start and after `cls`, followed by every protected folder, one block under the other. Every other prompt shows only the current folder's block.
- The status block sits between two separator lines. `update` and `next` lines come after the bottom one, then a blank line, then `guard>`. `next` appears only when something needs you, and says what to type.
- The background guard checks GitHub for a newer signed version every 6 hours (section 11). Nothing installs by itself. A yellow `update` line then sits between the separator and `next`: `update  New version is available. Type  update  to keep guard up to date.` Offline → nothing.
- Chrome (and any program) can always add new files to a protected folder. Only delete and rename of existing files is blocked. A new file is locked the moment it is finished.
- Every command that touches many files prints the count and asks once.
- `<name>` is a partial match. One match → acts. Many → numbered picker.
- Questions always look the same: facts first, then the question, then a numbered menu. `>` marks the chosen row; ↑ ↓ moves it, Enter picks; or type the number(s) and Enter. Picked rows turn green. Esc or `n` = back to `guard>` with `cancelled`.
- Dangerous actions (delete all, move all, remove all, uninstall) have no menu: you must type `YES` (any case: yes, Yes, YES).
- Tab completes: type the first letters, press Tab. One match → filled in. Several → filled in as far as they agree, and a list opens under the line with the first one marked (`>`, green): ↑ ↓ (or Tab / Shift+Tab) move the mark, Enter puts the marked one in the line (Enter again runs it), typing more letters narrows the list as you type, Backspace widens it, Esc closes it. Up to 8 rows show at a time; the list scrolls as the mark moves. After `help`, the list is the start table itself (headings, rows, explanations), narrowed as you type. Examples: [Tab.md](Tab.md). It completes command names (`ini` → `init`), `all` / `folder` / `remove`, folder paths after `init` and in "type a folder path" (`init C:\Us` → `init C:\Users`), and file and folder names of the current folder after `delete` and `move`. ↑ ↓ bring back earlier commands, Esc clears the line.
- Waiting shows moving dots: `.` → `..` → `...` → `.` again. On `Requesting Admin Access` (during and right after the UAC prompt, it then stays as `...`), on the install's row of the step that is running (`  ..    memory     ...`, replaced by its `ok` row when done), on `checking folders` before a status block that takes longer than a moment, and in guard on every slow step: `locking`, `unlocking`, `undoing`, `moving`, `telling the background guard`, `checking for a new version`, `downloading`, `stopping the background guard`. The dots line is wiped when the step is done, and its result row prints in its place. The blinking cursor is hidden while dots move.
- `all` works after any command that takes a target: `list all`, `delete all`, `move all`, `edit all`, `resume all`, `remove all`, `help all`.
- `init` with no path = the folder the terminal is in. `init <path>` = any folder. No question is asked: typing `init` is the answer. Facts line, then locking starts. Ctrl+C during locking undoes what was done so far.
- `init` protects every file, subfolders included, except files on the skip list (temp files). The skip list is built in (`~$*  *.tmp  *.temp  *.crdownload  *.part  Thumbs.db  desktop.ini`) and you can add to it with `skip`. Subfolders are locked too: they can't be renamed or moved out.
- `init` refuses a whole drive, Windows and program folders, and a folder inside or around another protected folder.
- `edit` unlocks the current folder and opens it in Explorer. No timer. It locks again at the next logon, or when you type `resume`. While unlocked it is a normal folder: you, Excel, Photoshop, and also AI agents can delete in it.
- Editing files: Word, Excel, Photoshop, Notepad++ and most programs save by deleting the old file and renaming a new one. Inside a locked folder that delete is blocked, so Save fails. Opening and reading always works. To change files: `edit`, work, `resume`.
- Explorer shows a badge in the bottom-left corner of every protected folder and file (like Google Drive's): green lock = protected · orange lock with the left leg open = `edit` (unlocked) · red `!` = partly locked (a file guard couldn't lock yet, e.g. open in a program, and every folder above it up to the protected one). Files on the skip list get no badge: they are never locked. Badges change by themselves after `init`, `edit`, `resume`, `remove`, `move`, `skip` and at the background guard's checks. The install restarts Explorer once to load them (open Explorer windows close); `uninstall` takes them off, and their helper file goes at the next PC restart.
- Cloud folders (OneDrive, Google Drive, Dropbox): allowed only when the files are really on the disk ("Always keep on this device" / "Available offline"). `init` checks and refuses otherwise. A delete made from the phone or the web is blocked on the PC; the file stays here. (v2: guard shows those files and asks keep or delete.)
- Memory: every protected folder holds a hidden, locked `_guard.json` with all settings and the list of every protected folder. `C:\ProgramData\guard\config.json` is only a fast copy. If any protected folder survives a reinstall, disk move or backup, everything can be restored from it.
- guard always runs as administrator: typing `guard` shows the UAC prompt once, then guard opens in a window of its own, titled `guard (administrator)`. Everything inside runs with no more prompts. `exit` closes that window; the next `guard` asks again.
- Why its own window: any program running as you can type into your normal terminal (it attaches to the console and writes key presses), so an AI agent could type `remove` + Enter into a guard running there. A window made by an admin process refuses that, and refuses fake key messages too. `src/redteam.ps1` tries all three on every run.
- Protected files are owned by SYSTEM, not you. So you, and every program or AI agent running as you, can't delete or unlock them. Only a human clicking Yes on the UAC prompt can. The background guard runs as SYSTEM and locks new files without prompts.
- Never run an AI agent from an admin terminal: it would inherit full rights. Opened from an admin terminal, guard needs no prompt and shows once, in green: `Admin Access Already Granted.`
- Everything guard prints starts one space in from the left edge, `guard>` included, and so does the install from `Requesting Admin Access...` on (left out of the screens below to keep them short).
- Plain words only. Never shown: ACL, deny, DE, DC, parent, sweep, watcher.
- Colours: `LOCKED` `running` `ok` green · `PARTIAL` `UNLOCKED` `STOPPED` `NOT locked` `FAIL` red · `update` and warnings yellow.

Words the program uses:

| meaning | program says |
|---|---|
| folder that contains the protected folder | the folder above |
| hidden background process | background guard |
| re-check every file and lock the missed ones | full check |
| last single file locked | last file locked |

---

## 1. Install (once)

```
PS> irm https://raw.githubusercontent.com/ShashwatGold1/Folder_Safety_Guard/main/install.ps1 | iex
```

Public repo, nothing else needed on the PC. The install needs administrator rights. If the terminal isn't elevated, the UAC prompt appears once; click Yes. The install then runs in the same terminal window, progress bar on top: no new window, nothing to close.

While running (the running step's row has moving dots, no blinking cursor):
```
guard  installing   [===============---------------]   50%   4/8

  ok    check      PowerShell 5.1 · Windows 11 · user ojhas
  ok    uac        on · admin rights granted
  ok    folder     C:\Program Files\guard
  ok    files      guard.ps1 · guard.cmd · modules
  ..    path       ..                                                          ← . → .. → ... → .
```

Done (from a terminal that isn't elevated; the green line appears after the Yes click):
```

Requesting Admin Access...
Admin Access Granted Successfully.                                              ← green

guard  installing   [==============================]  100%   9/9

  ok    check      PowerShell 5.1 · Windows 11 · user ojhas
  ok    uac        on · admin rights granted
  ok    folder     C:\Program Files\guard
  ok    files      guard.ps1 · guard.cmd · modules
  ok    path       added for all users
  ok    task       "guard" · runs as SYSTEM · at logon · hidden · restarts itself if it stops
  ok    guard      background guard running
  ok    badges     shown in Explorer · Explorer restarted once to load them
  ok    memory     nothing from an earlier install

  Guard is Installed Successfully.                                               ← green
  type:  guard                                                                   ← guard in cyan
```

`guard` works right away in the same window, PowerShell or Command Prompt: besides PATH, the install puts a one-line `guard.cmd` in `C:\Windows`, which every terminal already searches, also ones opened before the install. Only admins can write there.

Failed (install stops, later steps skipped, problem and fix always at the bottom):
```
guard  installing   [===---------------------------]   11%   1/9   stopped

  ok    check      PowerShell 5.1 · Windows 11 · user ojhas
  FAIL  uac        User Account Control is turned off
  --    folder     skipped
  --    files      skipped
  --    path       skipped
  --    task       skipped
  --    guard      skipped
  --    badges     skipped
  --    memory     skipped

  not installed.  do the fix below and try again.                                ← red

  problem   UAC is off. With UAC off, any program (including AI agents) could unlock
            protected files without you clicking Yes. guard refuses to install like this.
  fix       1. press Win+R, type  UserAccountControlSettings
            2. move the slider to the second notch from the top (default) or higher
            3. click OK, restart the PC
            4. run the install line again
```

Another failure example:
```
  FAIL  task       Register-ScheduledTask: access denied
  --    guard      skipped
  --    badges     skipped
  --    memory     skipped

  not installed.  do the fix below and try again.                                ← red

  problem   Task Scheduler service is not running
  fix       1. press Win+R, type  services.msc
            2. find "Task Scheduler", right-click, Start
            3. run the install line again
```

No known fix:
```
  problem   unknown

  report
            guard install 1.0 · step 5 task · Windows 11 24H2 · PowerShell 5.1
            Register-ScheduledTask : The task XML contains a value which is incorrectly formatted...

  Report this on GitHub?  (opens the browser with the report filled in; you only click Submit)
  > 1  yes
    2  no
  type 1 or 2 or ↑ ↓ then Enter > 1

  opened    github.com/ShashwatGold1/Folder_Safety_Guard/issues/new              ok
```

- `yes` → the browser opens the new-issue page with title and report already filled in. The person clicks "Submit new issue". That's all guard does.
- No GitHub account → close the tab, nothing else happens. `no` → nothing happens.
- The report has only: guard version, step, Windows version, PowerShell version, the raw error line. Never file or folder names.
- Same block for any `FAIL` inside guard (init, update, restore), not only install.

Running the install line again = update in place (see section 11). Protected folders are untouched.

---

## 2. First start (nothing protected yet)

```
PS> guard

Requesting Admin Access...
```

UAC prompt → Yes → the terminal says where guard is and waits until guard closes:

```
Requesting Admin Access...
guard is open in its own window: only programs with admin rights can type into it.   ← green
this terminal waits until you close guard.
```

and guard opens in its own window, `guard (administrator)`:

```
Admin Access Granted Successfully.                                              ← green

-------------------- Guard ---------------------

folders                   show all protected folders
use <n>                   switch to folder n
init                      protect the folder the terminal is in
init <path>               protect the folder at path
update                    install the newest guard
cls                       clear screen
help <command>            explain a command
help all                  explain every command
uninstall                 remove guard
exit                      close guard

------------ All protected folders -------------

edit all                  unlock every folder
resume all                lock every folder
remove all                stop protecting every folder
skip all <pattern>        add files that are never locked, in every folder

---------------- Current folder ----------------

list                      show files and folders
delete <name>             delete files or folders
delete all                delete everything in the folder
move <name>               copy or cut files or folders
move all                  copy or cut everything in the folder
move folder               move the protected folder somewhere else
edit                      unlock the folder
resume                    lock the folder
remove                    stop protecting the folder
skip                      show files that are never locked
skip <pattern>            add files that are never locked
skip remove <pattern>     take a pattern out


--------------------------------------------------------------------------------------
folder    none yet
guard     running                    nothing to protect
--------------------------------------------------------------------------------------

next      init / init <path>

guard>
```

> When some files can't be locked right away, the report adds a `not locked yet` list before the success lines:

```
guard> init C:\Users\ojhas\Downloads\_Screenshots

  _Screenshots  ·  C:\Users\ojhas\Downloads\_Screenshots  ·  47 files  ·  51.3 MB

  owner     folder + 47 files         now owned by SYSTEM                        ok
  locking   folder                    can't be deleted or renamed                ok
  locking   folder above (Downloads)  can't delete inside using the folder key   ok
  locking   47 files                  can't be deleted                           ok
  memory    _guard.json written and locked                                       ok
  guard     told about the new folder                                            ok

    not locked yet
    2  Chrome can still save                x.crdownload, y.crdownload
    1  cloud file, not available locally    report.pdf
    1  open in another program              notes.docx

  Folder is Protected Successfully.                                              ← green
  path        C:\Users\ojhas\Downloads\_Screenshots
  locked      47 of 47 files

--------------------------------------------------------------------------------------
folder    _Screenshots               1 of 1  ·  current
path      C:\Users\ojhas\Downloads\_Screenshots
files     47                         newest  amazon-checkout.png  21:04 today
lock      LOCKED                     owner SYSTEM  ·  folder + folder above + 47 files
guard     running                    last full check 21:30  ·  last file locked 21:30
--------------------------------------------------------------------------------------

guard>
```

Reasons and what happens:
- Chrome still saving: locking now would break the save. Locked the moment Chrome finishes.
- Cloud file, not downloaded: OneDrive / Google Drive shows it, but nothing is on the disk yet. Locked once it is downloaded.
- Open in another program: Windows won't change it while open. Locked when it is closed.

All three retry at every full check. The status row shows them as `files  51  ·  4 waiting`.

---

## 3. Normal start (later, any day, two folders)

```
PS> guard

Requesting Admin Access...
```

UAC prompt → Yes → the terminal says where guard is and waits until guard closes:

```
Requesting Admin Access...
guard is open in its own window: only programs with admin rights can type into it.   ← green
this terminal waits until you close guard.
```

and guard opens in its own window, `guard (administrator)`:

```
Admin Access Granted Successfully.                                              ← green

-------------------- Guard ---------------------

folders                   show all protected folders
use <n>                   switch to folder n
init                      protect the folder the terminal is in
init <path>               protect the folder at path
update                    install the newest guard
cls                       clear screen
help <command>            explain a command
help all                  explain every command
uninstall                 remove guard
exit                      close guard

------------ All protected folders -------------

edit all                  unlock every folder
resume all                lock every folder
remove all                stop protecting every folder
skip all <pattern>        add files that are never locked, in every folder

---------------- Current folder ----------------

list                      show files and folders
delete <name>             delete files or folders
delete all                delete everything in the folder
move <name>               copy or cut files or folders
move all                  copy or cut everything in the folder
move folder               move the protected folder somewhere else
edit                      unlock the folder
resume                    lock the folder
remove                    stop protecting the folder
skip                      show files that are never locked
skip <pattern>            add files that are never locked
skip remove <pattern>     take a pattern out


--------------------------------------------------------------------------------------
folder    _Screenshots               1 of 2  ·  current
path      C:\Users\ojhas\Downloads\_Screenshots
files     47                         newest  amazon-checkout.png  21:04 today
lock      LOCKED                     owner SYSTEM  ·  folder + folder above + 47 files
guard     running                    last full check 09:12  ·  last file locked 21:04

folder    Tax                        2 of 2
path      C:\Users\ojhas\Documents\Tax
files     12                         newest  itr-2026.pdf  2026-07-30
lock      LOCKED                     owner SYSTEM  ·  folder + folder above + 12 files
guard     running                    last full check 09:12  ·  last file locked 2026-07-30
--------------------------------------------------------------------------------------

update    New version is available. Type  update  to keep guard up to date.

guard>
```

Every prompt after this shows only the current folder:

```
guard> list

  47 files, newest first
   1  amazon-checkout.png          2026-11-15 21:04   1.2 MB
   2  gumroad-settings.png         2026-11-15 19:40   0.8 MB
   3  godaddy-dns.png              2026-11-14 11:02   2.1 MB
   ...
  47  first-screenshot.png         2026-05-02 10:15   0.6 MB

--------------------------------------------------------------------------------------
folder    _Screenshots               1 of 2  ·  current
path      C:\Users\ojhas\Downloads\_Screenshots
files     47                         newest  amazon-checkout.png  21:04 today
lock      LOCKED                     owner SYSTEM  ·  folder + folder above + 47 files
guard     running                    last full check 09:12  ·  last file locked 21:04
--------------------------------------------------------------------------------------

update    New version is available. Type  update  to keep guard up to date.

guard>
```

Below, `...status...` means this block.

`list all` shows every protected folder, grouped:

```
guard> list all

  _Screenshots   C:\Users\ojhas\Downloads\_Screenshots   47 files
   1  amazon-checkout.png          2026-11-15 21:04   1.2 MB
   2  gumroad-settings.png         2026-11-15 19:40   0.8 MB
   ...

  Tax            C:\Users\ojhas\Documents\Tax            12 files
   1  itr-2026.pdf                 2026-07-30 14:12   0.3 MB
   ...
  ...status...
guard>
```

---

## 4. cls

```
guard> cls
```
Screen clears, then the "normal start" screen (table, every folder between separators, update, next) is printed again.

---

## 5. delete

### one match
```
guard> delete godaddy

  godaddy-dns.png     2026-11-14 11:02    2.1 MB   C:\Users\ojhas\Downloads\_Screenshots

  Delete this file?
  > 1  yes
    2  no
  type 1 or 2 or ↑ ↓ then Enter > 1

  unlocked  godaddy-dns.png                                                      ok
  deleted   godaddy-dns.png                                                      ok
  46 files still locked
  ...status (files 46)...
guard>
```

### many matches
```
guard> delete amazon

  Which files?
  > 1  amazon-checkout.png     2026-11-15 21:04    1.2 MB   C:\Users\ojhas\Downloads\_Screenshots
    2  amazon-cart.png         2026-11-15 20:58    0.9 MB   C:\Users\ojhas\Downloads\_Screenshots
    3  amazon-login.png        2026-11-15 20:55    0.7 MB   C:\Users\ojhas\Downloads\_Screenshots
    4  all
  type numbers (1 3) or ↑ ↓ then Enter > 1 3

  Delete 2 files?
  > 1  yes
    2  no
  type 1 or 2 or ↑ ↓ then Enter > 1

  deleted   amazon-checkout.png                                                  ok
  deleted   amazon-login.png                                                     ok
  44 files still locked
  ...status...
guard>
```

### can't be deleted (open in another program)
```
  FAIL  notes.docx  not deleted, still protected  ·  open in another program
```
The file stays locked. Close the program and try again.

A folder can be picked too: it is deleted with everything inside.

### no match
```
guard> delete flipkart

  no file matches "flipkart"  ·  type  list  to see names
  ...status...
guard>
```

### all
```
guard> delete all

  This empties the folder: 46 files, 51.3 MB.
  type YES to continue, anything else to cancel > YES

  unlocked  46 files                                                             ok
  deleted   46 files                                                             ok
  folder is empty and still protected

--------------------------------------------------------------------------------------
folder    _Screenshots               1 of 2  ·  current
path      C:\Users\ojhas\Downloads\_Screenshots
files     0
lock      LOCKED                     owner SYSTEM  ·  folder + folder above
guard     running                    last full check 09:12
--------------------------------------------------------------------------------------

guard>
```

---

## 6. move

```
guard> move gumroad

  gumroad-settings.png     2026-11-15 19:40    0.8 MB   C:\Users\ojhas\Downloads\_Screenshots

  Where to?
  type a folder path then Enter > D:\Keep\Screenshots

  D:\Keep\Screenshots does not exist. Create it?
  > 1  yes
    2  no
  type 1 or 2 or ↑ ↓ then Enter > 1

  Cut or copy?
  > 1  cut
    2  copy
  type 1 or 2 or ↑ ↓ then Enter > 1

  unlocked  gumroad-settings.png                                                 ok
  moved     D:\Keep\Screenshots\gumroad-settings.png                             ok
  45 files still locked
  ...status...
guard>
```

Many matches → the same "Which files?" picker as delete, then the questions above.
`copy` keeps the original locked; the copy is a normal file. What arrives at the new place is yours: you own it, normal permissions.
Folders can be moved or copied too, with everything inside.
The destination must be outside the protected folder: `pick a folder outside _Screenshots`.
`move all` → path, cut or copy, then `This moves 45 files. type YES to continue, anything else to cancel >`.

### move the whole protected folder

From Explorer this is blocked (moving a folder is a rename, and that is locked). Through guard:

```
guard> move folder

  _Screenshots  ·  C:\Users\ojhas\Downloads\_Screenshots  ·  47 files

  Where to?
  type a folder path then Enter > D:\Keep\_Screenshots

  unlocked  folder, folder above, 47 files                                       ok
  moved     D:\Keep\_Screenshots                                                 ok
  locking   folder, folder above (Keep), 47 files                                ok
  memory    _guard.json updated in all folders  ·  new path saved                ok

  Folder is Moved and Protected Successfully.                                    ← green
  path        D:\Keep\_Screenshots
  note        programs that save here (e.g. the Chrome extension) must be pointed to the new path
  ...status (new path)...
guard>
```

Same drive = instant. Different drive = copy then delete, takes as long as the size.

---

## 7. edit / resume

```
guard> edit

  _Screenshots  ·  C:\Users\ojhas\Downloads\_Screenshots  ·  45 files

  unlocked  folder + folder above + 45 files                                     ok
  opened    in Explorer                                                          ok
  edit, save, rename, delete freely. locks again at next logon, or type  resume

--------------------------------------------------------------------------------------
folder    _Screenshots               1 of 2  ·  current
path      C:\Users\ojhas\Downloads\_Screenshots
files     45
lock      UNLOCKED                   editing  ·  locks at next logon
guard     running                    not locking new files while editing
--------------------------------------------------------------------------------------

next      resume  when done

guard>
```

```
guard> resume

  full check   43 files found (2 deleted while editing)
  locked       folder + folder above + 43 files                                  ok
  ...status (LOCKED)...
guard>
```

`edit all` = every protected folder. `resume` / `resume all` = lock now; also works from a new `guard` if you exited the old one. Logon locks everything too, with no typing.

While a folder is in edit, it is a normal folder: you, Excel, Photoshop, and also AI agents can delete in it. The status line says so until you `resume`.

`edit <name>` unlocks only what you pick: files or subfolders whose name has `<name>` in it (a picker when there are several, like `delete`). The folder, the folder above and everything else stay locked; the background guard leaves the picked ones alone, and they get the orange badge.

```
guard> edit todo

  TODO - Copy.md               2026-10-19 11:02    1.2 KB   C:\Users\ojhas\Desktop\Test FSG

  unlocked  TODO - Copy.md                                                       ok
  only these: edit, rename, delete freely. the folder and everything else stay locked.
  they lock again at next logon, or type  resume
```

The status block shows them on their own line (`editing   1 unlocked   TODO - Copy.md  ·  locks at next logon`). `resume` locks them again; so does the next logon. A word that matches nothing unlocks nothing.

---

## 8. folders / use / init / remove

```
guard> init

  Tax  ·  C:\Users\ojhas\Documents\Tax  ·  12 files  ·  4.1 MB  ·  the folder this terminal is in

  owner     folder + 12 files         now owned by SYSTEM                        ok
  locking   folder                    can't be deleted or renamed                ok
  locking   folder above (Documents)  can't delete inside using the folder key   ok
  locking   12 files                  can't be deleted                           ok
  memory    _guard.json written and locked  ·  updated in 1 other folder         ok
  guard     told about the new folder                                            ok

  Folder is Protected Successfully.                                              ← green
  path        C:\Users\ojhas\Documents\Tax
  locked      12 of 12 files  ·  switched to this folder

--------------------------------------------------------------------------------------
folder    Tax                        2 of 2  ·  current
path      C:\Users\ojhas\Documents\Tax
files     12                         newest  itr-2026.pdf  2026-07-30
lock      LOCKED                     owner SYSTEM  ·  folder + folder above + 12 files
guard     running                    last full check now
--------------------------------------------------------------------------------------

guard>
```

```
guard> folders

   1  _Screenshots    C:\Users\ojhas\Downloads\_Screenshots    45 files   LOCKED
 * 2  Tax             C:\Users\ojhas\Documents\Tax             12 files   LOCKED
  type  use <n>  to switch
  ...status...
guard>
```

```
guard> use 1
  switched
  ...status (1 of 2)...
guard>
```

```
guard> remove

  Tax  ·  C:\Users\ojhas\Documents\Tax  ·  12 files  ·  files stay, nothing is deleted

  Stop protecting this folder?
  > 1  yes
    2  no
  type 1 or 2 or ↑ ↓ then Enter > 1

  unlocked  folder, folder above, 12 files                                       ok
  owner     folder + 12 files  back to you (ojhas)                               ok
  memory    _guard.json deleted here  ·  updated in 1 other folder               ok
  removed   from guard                                                           ok
  switched  to 1 of 1
  ...status...
guard>
```

### skip

```
guard> skip

  skip list for _Screenshots  (never locked, can always be deleted)
    built-in   ~$*  *.tmp  *.temp  *.crdownload  *.part  Thumbs.db  desktop.ini
    yours      —
  skip <pattern>  add  ·  skip all <pattern>  every folder  ·  skip remove <pattern>  take out
  ...status...
guard>
```

```
guard> skip *.bak

  added     *.bak  to _Screenshots                                                ok
  unlocked  3 files that match                                                   ok
  ...status...
guard>
```

```
guard> skip all *.bak
  added     *.bak  to all 2 folders                                               ok
```

```
guard> skip remove *.bak
  removed   *.bak  from _Screenshots  ·  3 matching files lock at the next full check   ok
```

Patterns: `*.bak` (extension), `draft*` (name start), `notes.txt` (one file). Built-in ones can't be removed. Saved in the memory file, so they survive a reinstall.

Already protected / not a folder / no permission:
```
guard> init C:\Users\ojhas\Downloads\_Screenshots
  already protected  ·  it is folder 1  ·  type  use 1
```
```
guard> init C:\nope
  not found: C:\nope
```
```
guard> init C:\Windows
  Windows and program folders can't be protected: C:\Windows
```
```
guard> init C:\
  a whole drive can't be protected. pick a folder on it
```
```
guard> init C:\Users\ojhas\Downloads\_Screenshots\2025
  already protected as part of C:\Users\ojhas\Downloads\_Screenshots
```
```
guard> init C:\Users\ojhas\Downloads
  this folder holds the protected folder C:\Users\ojhas\Downloads\_Screenshots. remove that one first, then init here
```

---

## 9. help

```
guard> help

  -------------------- Guard ---------------------

  folders                 list protected folders with their numbers · * marks the current one
  use <n>                 make folder number n the current one · numbers come from folders
  init                    protect the folder the terminal is in · no question asked · locks folder, folder above, every file
  init <path>             same, for the folder at path
  update                  install the newest guard from GitHub · protected folders untouched
  cls                     clear the screen and show the command table and every folder's status again
  help <command>          longer explanation of one command
  help all                longer explanation of every command
  uninstall               remove guard from this PC · unlocks everything, removes the background guard · files stay on the disk
  exit                    back to the terminal · protection keeps running in the background

  ------------ All protected folders -------------

  edit all                unlock every protected folder · locks again at next logon or with resume all
  resume all              lock every protected folder now
  remove all              stop protecting every folder · type YES · files stay on the disk
  skip all <pattern>      add a never-locked pattern to every protected folder

  ---------------- Current folder ----------------

  list                    show files and folders in the current folder, newest first, with date and size
  delete <name>           delete files or folders · matches by part of the name · picker if many · always asks first
  delete all              delete everything in the folder · type YES
  move <name>             copy or cut files or folders · same picking as delete · asks where to, then cut or copy
  move all                copy or cut everything in the folder · type YES
  move folder             move the protected folder itself to a new path · stays protected there
  edit                    unlock the folder and open it in Explorer · save, rename, delete work · locks again at next logon or with resume
  edit <name>             unlock only those files or subfolders · same picking as delete · the rest stays locked
  resume                  lock the folder again now · also happens by itself at every logon
  remove                  stop protecting the folder · files stay on the disk, just not protected
  skip                    show files that are never locked and can always be deleted (temp files)
  skip <pattern>          add a pattern, e.g. skip *.bak
  skip remove <pattern>   take a pattern out · built-in ones can't be removed
  ...status...
guard>
```

```
guard> help edit

  edit
  Removes the lock from the folder, the folder above and every file, and opens
  the folder in Explorer. Save from Word, Excel, Photoshop, rename, delete, all
  work. The background guard stops locking new files there. Type  resume  to
  lock again. If you forget, the next logon locks everything by itself.
  While unlocked, AI agents can delete in that folder too.
  ...status...
guard>
```

---

## 10. Problems the status block reports

Background guard stopped (3 new files not locked):
```
--------------------------------------------------------------------------------------
folder    _Screenshots               1 of 2  ·  current
path      C:\Users\ojhas\Downloads\_Screenshots
files     47                         newest  amazon-checkout.png  21:04 today  ·  3 NOT locked
lock      PARTIAL                    owner SYSTEM  ·  folder + folder above + 44 files
guard     STOPPED                    last seen 2026-11-14 23:50
--------------------------------------------------------------------------------------

next      resume   (locks the 3 files and restarts the background guard)

guard>
```

Folder gone (moved or renamed outside guard):
```
--------------------------------------------------------------------------------------
folder    _Screenshots               1 of 2  ·  current  ·  NOT FOUND
path      C:\Users\ojhas\Downloads\_Screenshots
files     —
lock      —
guard     running
--------------------------------------------------------------------------------------

next      remove  to forget it  /  init <new path>

guard>
```

Several folders with problems: `next` names the first one, e.g. `type  use 3  then  resume`.

Unknown command:
```
guard> delet amazon
  unknown command "delet"  ·  did you mean  delete ?
  ...status...
guard>
```

Chrome is saving right now:
```
  locking   47 files   (1 still being saved by Chrome, locks when it finishes)
```

Update check failed (offline): no update line, nothing else changes.

Started from a terminal that was already running as administrator (no prompt; green, once, at the top when guard opens, in place of "Admin Access Granted Successfully."):
```
Admin Access Already Granted.                                                   ← green
```

---

## 11. update

```
guard> update

guard  updating 1.0 → 1.1   [==============================]  100%   9/9

  ok    check      PowerShell 5.1 · Windows 11 · user ojhas
  ok    uac        on · admin rights granted
  ok    folder     C:\Program Files\guard  (already there)
  ok    files      1 of 7 files updated · guard.cmd same
  ok    path       already there
  ok    task       "guard" · runs as SYSTEM · at logon · hidden · restarts itself if it stops
  ok    guard      background guard restarted
  ok    badges     shown in Explorer  (already there)
  ok    folders    2 protected folders untouched · 59 files still locked

  Guard is Updated Successfully.                                                 ← green
  type:  guard                                                                   ← guard in cyan
PS>
```

Already newest:
```
guard> update
  you have the newest version (1.1)
  ...status...
guard>
```

Only signed releases. On GitHub, `release.json` lists the version, one commit and the SHA-256 of every file; `release.sig` is its signature, made with the release key in the publisher's TPM chip (needs a PIN and admin rights, can't be copied out). The public half of that key is written in guard itself (`guard-core.ps1`, `install.ps1`).
- `update` and the install line take the list only if the signature is right, download every file from **that commit** (never from main as it is), check each hash, and only then stop the background guard and write anything. An older signed version is never taken.
- Someone in the GitHub account, or an AI agent pushing code, can change main but can't make a list the key accepts:
```
guard> update
  update refused: src/guard-watch.ps1 from GitHub doesn't match the signed release list.
  nothing was changed.                                                           ← red
```
```
guard> update
  update refused: the release list is not signed with the guard release key.
  nothing was changed. if this stays, the guard files on GitHub may have been tampered with.   ← red
```
- The background guard's 6-hourly check shows the yellow `update` line only for a signed newer version.
- Publishing (maintainer only): `src/guard-sign.ps1 -Setup` once, then `src/guard-sign.ps1` per release, in a normal terminal. git runs there without admin rights (hooks and settings in `.git` can be planted by any program). The signer opens in an admin window of its own, downloads the commit from GitHub itself, checks that the key written in that commit is the TPM's key, shows version + commit, and needs `YES` and the PIN.
- Left open: the very first install trusts the install line as it is (there is no earlier guard to check it). Every update after that is checked.

---

## 12. uninstall

```
guard> uninstall

  This removes guard from this PC. Protected folders: 2, files: 59. Nothing is deleted.
  type YES to continue, anything else to cancel > YES

  unlocked  C:\Users\ojhas\Downloads\_Screenshots  (47 files)  owner back to you  ok
  unlocked  C:\Users\ojhas\Documents\Tax  (12 files)           owner back to you  ok
  kept      _guard.json in both folders (memory, so a future install can restore)   ok
  removed   task "guard"                                                         ok
  removed   path entry                                                           ok
  removed   C:\Windows\guard.cmd                                                 ok
  removed   C:\Program Files\guard                                               ok
  removed   C:\ProgramData\guard                                                 ok
  removed   Explorer badges                                                      ok

  Guard is Uninstalled Successfully.                                             ← green
PS>
```

The `_guard.json` files stay on purpose. They are the memory: install guard again and it finds them (section 16). To get rid of them too, `remove` each folder before `uninstall`.

---

## 13. exit

```
guard> exit
  background guard keeps running. type  guard  to come back.
PS>
```

Ctrl+C anywhere = same as exit, nothing left half-done (an edit locks again at next logon).

---

## 14. Reboot / logon (no typing)

- Logon → task starts the background guard hidden → full check: every protected folder, every file, lock what's missing → keep watching.
- Background guard stops → task restarts it (every minute, as often as needed).
- Logon missed (PC asleep) → task runs as soon as possible.
- Nothing shows on screen. Open `guard` to see `last full check`.

---

## 15. How the lock works (plain words)

Windows has two ways to delete something inside a folder:
1. the item's own "delete" permission (every file and folder has one)
2. the folder's key: "I may delete anything inside me"

guard removes:
- the key from the folder above (Downloads). Everything else in Downloads keeps its own permission and deletes normally.
- the own permission and the key from the protected folder (`_Screenshots`).
- the own permission from every file inside, as soon as Chrome finishes saving it.

Both the key and the own permission must be gone for an item to be safe. That is why the folder above gets one rule too.

Deleting Downloads itself can't happen either: Windows must empty a folder before deleting it, and `_Screenshots` refuses to be emptied out.

**Why SYSTEM owns the files.** Windows always lets the owner of a file change its permissions, no matter what rules are on it. If you stayed the owner, you (or any program running as you, including AI agents) could remove the lock with one command. So guard makes SYSTEM the owner. Now the lock can only be changed with administrator rights, and getting those means the UAC prompt, which only a human can click.

**Why guard runs as administrator.** Every program you start gets a limited version of your account, even though you are an admin. That limited version can't touch SYSTEM-owned files. `guard` asks for the full version once, when it opens (the UAC click). Inside, your commands work. Any program that didn't go through that click, agents included, is still limited and still blocked.

**The one way around it.** A program started from a terminal that was already elevated inherits the full version. Never run AI agents in an admin terminal. guard warns when it sees this.

---

## 16. Memory and restore

### What is saved
One small text file: the list of every protected folder (full paths), settings (version, current folder), and the time it was last written. Nothing about accounts.

### Where
| Place | Copies | Protected? | Job |
|---|---|---|---|
| `C:\ProgramData\guard\config.json` | 1 | No, normal file on C: | fast copy guard reads all the time |
| `_guard.json` inside each protected folder | one per folder | Yes: hidden, locked, SYSTEM-owned | the real memory, travels with the folder |

4 protected folders → 4 `_guard.json` + 1 `config.json` = 5 identical copies. Every change (init, remove, move folder, settings) rewrites all of them at once.

### How it recovers
- **Windows reinstalled, same disk** → `config.json` is gone, folders are not. Install line → installer finds a `_guard.json` → restore (below).
- **New PC, folders copied from a backup** → `_guard.json` travels inside each folder → same.
- **Only `config.json` lost** (C: corrupt, folders fine) → guard rebuilds it at start from the newest `_guard.json`, no question, one line: `memory  rebuilt from _Screenshots`.
- **Some folders lost** → every surviving copy has the full list, so nothing is forgotten. Lost ones show `not found`; you `remove` them or `init <new path>`. If they come back later at the same path (restored from backup), the next full check locks them with no typing.
- **Copies disagree** (one folder from an older backup) → newest write time wins.
- **All folders lost** → memory is gone with them. Guard only keeps the list, never the files; a backup is the only answer for the files.

### Restore screen (4 folders in the list, 2 survived)

On a fresh install (no `config.json`), the installer looks for `_guard.json` on every drive and in the usual places (Desktop, Documents, Downloads, Pictures, drive roots). Found one → reads the list → checks each folder:

```
guard  installing   [==============================]  100%   9/9

  ok    check      PowerShell 5.1 · Windows 11 · user ojhas
  ok    uac        on · admin rights granted
  ok    folder     C:\Program Files\guard
  ok    files      guard.ps1 · guard.cmd
  ok    path       added for all users
  ok    task       "guard" · runs as SYSTEM · at logon · hidden · restarts itself if it stops
  ok    guard      background guard running
  ok    badges     shown in Explorer · Explorer restarted once to load them
  ok    memory     found in C:\Users\ojhas\Downloads\_Screenshots  ·  lists 4 folders

  Guard is Installed Successfully.                                               ← green

  guard memory found. it lists 4 protected folders:
    1  C:\Users\ojhas\Downloads\_Screenshots    found      47 files
    2  C:\Users\ojhas\Documents\Tax             found      12 files
    3  D:\Keep\Invoices                          not found
    4  D:\Keep\Photos                            not found

  restoring protection  ·  a folder you no longer want: type  remove  in guard

  access    your account (ojhas) given access to both folders                   ok
  owner     folders + 59 files        now owned by SYSTEM                        ok
  locking   folders, folders above, 59 files                                     ok
  memory    _guard.json updated in both  ·  2 missing folders kept in the list  ok

  2 Folders are Protected Successfully.                                          ← green
  type:  guard                                                                   ← guard in cyan
```

- No question in the installer: it runs in your normal terminal, where any program running as you can type, and an injected "no, start fresh" would drop the protection. Restoring is the safe way; `remove` (in guard's own window) drops a folder you no longer want.
- "access" step: files restored to a new Windows with their old permissions can show "access denied" even to open, because to Windows the new account is a different account even with the same name. Restore grants your current account access first, then locks. That is the only place accounts come into it.
- The 2 missing folders stay in the list and show `NOT FOUND` in red in the status block, with `next  type  use 3  then  remove  to forget it, or  init <new path>`.
- `init` on a folder that already has a `_guard.json` asks the same restore question.
- The newest `_guard.json` wins if copies disagree (e.g. one folder restored from an older backup).

---

## 17. check (PC settings guard can't protect by itself)

```
guard> check

  PC check - settings guard can't protect by itself

  fix   account     ojhas is an administrator                                    ← yellow
                    programs you run (an AI agent too) can get admin rights through known tricks, with no prompt. ...   ← grey
                    type  check account                                          ← cyan
  ok    uac         asks on the dimmed screen, passwords asked there             ← green
  fix   passwords   a password box can be faked
  fix   clipboard   history is kept (Win+V)
  fix   hibernate   on (also Fast Startup)
  fix   pagefile    kept after shut down
  ok    crash files small only
  ok    defender    on, tamper protection on
  fix   samples     suspicious files are sent to Microsoft by itself
  ok    updates     last update 14 Nov 2026  (5 days ago)
  ok    core        memory integrity on, sign-in protection on
  info  startup     no startup PIN (your choice). someone with this PC alone for a while could change Windows
                    and plant spyware. keep the PC where others can't get at it; guard vaults stay locked either way.

  6 to fix.  check fix  fixes 5 of them.
```

- `check fix` lists what it will change and why, needs `YES`, changes each one, then reads every setting again: only what Windows now reports counts. Any setting that didn't change is a red `FAIL`, and then there is no green line. All of them can be turned back in Windows settings.
- What `check fix` changes: clipboard history and cloud clipboard off, passwords only after Ctrl+Alt+Del, hibernation off (Fast Startup goes with it), the pagefile wiped at shut down, small crash files only, the admin prompt on the dimmed screen, and Defender never sends files without asking.
- What it only shows, with the steps: Windows updates older than 45 days, Defender off, memory integrity or sign-in protection off.
- `check account`, the most important one: makes a second account for admin work (you choose name and password, at least 12 characters, written on paper), checks with Windows that the password works, and only after `YES` makes your daily account a standard one. Any problem: nothing is taken away. From the next sign-in, `guard` (and anything else that needs admin) asks for that account's password.
- Nothing about startup or booting (startup PIN, BIOS, USB boot): left out by choice (startup protection is never fully reliable either). What that leaves open: someone with the PC alone for a while could change Windows on C: and plant spyware that waits for you. Files in the vault stay unreadable without your PIN.

---

## 18. Security Vault (nobody reads a file without the PIN)

One command turns it on for every protected folder. Everything else happens by itself.

```
guard> security vault on

  Security Vault: every file in your protected folders gets sealed. only your PIN opens one.

  choose the guard PIN. unlocking a file asks for it.            <- first time only
  new PIN: ********
  new PIN again: ********

  recovery code. write it on paper now and keep it away from this PC:          <- yellow
      40517-88213-09634-71250-36678-21945                                       <- cyan
  type the recovery code from your paper: ********
  sealing...

  Security Vault is On.                                                         <- green
  to use a file: right-click it, then  Unlock with guard.
```

Later times: only `PIN: ********`, then `Security Vault is On.` Nothing ever says where the files went.

In Explorer every protected folder looks the same: the same folders, the same file names and dates. Each file is now an empty placeholder with a blue shield badge, which can't be written into, renamed or deleted.

To use a file: right-click it, **Unlock with guard**, Windows asks Yes, then guard's own window:

```
  unlock  bank.txt
  PIN  (forgot it, or a new PC: type  recovery): ********
  Unlocked. it locks again by itself 15 minutes after you opened it, once no program uses it.
```

The placeholder is replaced by the real file (orange badge), which opens in its normal program. Right-clicking a folder unlocks every file in it.

```
guard> security vault off
  PIN: ********
  Security Vault is Off.                                                        <- green
```

- What happens under the hood, never shown:
  - every file is encrypted (AES-256, checked with HMAC-SHA256) with a key of its own, and checked to decrypt back to the exact same bytes before the real file goes. If any file fails, nothing changes: `FAIL`, and every file stays where it was.
  - the sealed copies sit in a hidden folder owned by a hidden, switched-off account (`guard-vault`) that nobody signs in with. Only that account, SYSTEM and administrators are in its permissions: you, Explorer and every program running as you (AI agents too) get "access denied" even to list it. An administrator who takes the files gets scrambled bytes.
  - the key that opens them is locked by a key in this PC's TPM chip that only works with the PIN. The chip counts wrong PINs (32, then one more try every 2 hours). A second copy is locked with the recovery code.
- While a file is unlocked, the background guard seals every change within 5 seconds. It locks the file again (last change sealed, real file wiped, placeholder back) 15 minutes after it was opened once no program has it open, and anything still unlocked at the next sign-in.
- A new file saved or copied into a protected folder is sealed by itself within seconds. Temp files (`~$*`, `*.tmp`, downloads in progress) and skip patterns are left alone.
- While it is on, `delete`, `move`, `edit`, `resume`, `remove` and `skip` say to turn it off first (they would act on placeholders). `uninstall` refuses: without guard the files would stay sealed for good.
- `security vault` says whether it is on and how many files are unlocked. `security vault pin` changes the PIN. At the PIN question, `recovery` uses the recovery code instead: a new PC, Windows reinstalled, the chip cleared, or the PIN forgotten.
- `security vault off` (PIN) brings every file back as a normal file, still protected from deleting as before. A file that can't come back stays sealed and is named in red.
- Refused or left alone, never followed: a folder holding a link to somewhere else, a file that is a hard link to another file (it could be a Windows file), a file swapped for a link while unlocked.
- Stays possible, honestly:
  - while a file is unlocked, programs you run can read that file. Don't unlock files with an AI agent running.
  - an attacker with administrator rights already on the PC when you type the PIN could catch it (`check account` closes most of this). Type the PIN only right after Windows' own dimmed Yes prompt.
  - file names and folder layout stay visible (that is what the placeholders are for), never the contents.
  - without the PIN and without the recovery code, the files are gone for good.
