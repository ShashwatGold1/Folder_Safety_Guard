# guard — end-to-end flow (v2)

Rules used everywhere below:
- Command table shows only at start and after `cls`, followed by every protected folder, one block under the other. Every other prompt shows only the current folder's block.
- The status block sits between two separator lines. `update` and `next` lines come after the bottom one, then a blank line, then `guard>`. `next` appears only when something needs you, and says what to type.
- The background guard checks GitHub for a newer version every 6 hours. Nothing installs by itself. A yellow `update` line then sits between the separator and `next`: `update  New version is available. Type  update  to keep guard up to date.` Offline → nothing.
- Chrome (and any program) can always add new files to a protected folder. Only delete and rename of existing files is blocked. A new file is locked the moment it is finished.
- Every command that touches many files prints the count and asks once.
- `<name>` is a partial match. One match → acts. Many → numbered picker.
- Questions always look the same: facts first, then the question, then a numbered menu. `>` marks the chosen row; ↑ ↓ moves it, Enter picks; or type the number(s) and Enter. Picked rows turn green. Esc or `n` = back to `guard>` with `cancelled`.
- Dangerous actions (delete all, move all, remove all, uninstall) have no menu: you must type `YES` (any case: yes, Yes, YES).
- Tab completes, like cmd: type the first letters, press Tab; Tab again shows the next match, Shift+Tab the one before. It completes command names (`ini` → `init`), `all` / `folder` / `remove`, folder paths after `init` and in "type a folder path" (`init C:\Us` → `init C:\Users`), and file and folder names of the current folder after `delete` and `move`. ↑ ↓ bring back earlier commands, Esc clears the line.
- `all` works after any command that takes a target: `list all`, `delete all`, `move all`, `edit all`, `resume all`, `remove all`, `help all`.
- `init` with no path = the folder the terminal is in. `init <path>` = any folder. No question is asked: typing `init` is the answer. Facts line, then locking starts. Ctrl+C during locking undoes what was done so far.
- `init` protects every file, subfolders included, except files on the skip list (temp files). The skip list is built in (`~$*  *.tmp  *.temp  *.crdownload  *.part  Thumbs.db  desktop.ini`) and you can add to it with `skip`. Subfolders are locked too: they can't be renamed or moved out.
- `init` refuses a whole drive, Windows and program folders, and a folder inside or around another protected folder.
- `edit` unlocks the current folder and opens it in Explorer. No timer. It locks again at the next logon, or when you type `resume`. While unlocked it is a normal folder: you, Excel, Photoshop, and also AI agents can delete in it.
- Editing files: Word, Excel, Photoshop, Notepad++ and most programs save by deleting the old file and renaming a new one. Inside a locked folder that delete is blocked, so Save fails. Opening and reading always works. To change files: `edit`, work, `resume`.
- Cloud folders (OneDrive, Google Drive, Dropbox): allowed only when the files are really on the disk ("Always keep on this device" / "Available offline"). `init` checks and refuses otherwise. A delete made from the phone or the web is blocked on the PC; the file stays here. (v2: guard shows those files and asks keep or delete.)
- Memory: every protected folder holds a hidden, locked `_guard.json` with all settings and the list of every protected folder. `C:\ProgramData\guard\config.json` is only a fast copy. If any protected folder survives a reinstall, disk move or backup, everything can be restored from it.
- guard always runs as administrator: typing `guard` shows the UAC prompt once, then guard runs right there in the same terminal window (no new window). Everything inside runs with no more prompts. `exit` returns to the terminal; the next `guard` asks again.
- Protected files are owned by SYSTEM, not you. So you, and every program or AI agent running as you, can't delete or unlock them. Only a human clicking Yes on the UAC prompt can. The background guard runs as SYSTEM and locks new files without prompts.
- Never run an AI agent from an admin terminal: it would inherit full rights. Opened from an admin terminal, guard needs no prompt and shows once, in green: `admin     running as administrator  ·  no prompt needed`.
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

While running (step name at the end of the bar line):
```
guard  installing   [===============---------------]   50%   4/8   path

  ok    check      PowerShell 5.1 · Windows 11 · user ojhas
  ok    uac        on · admin rights granted
  ok    folder     C:\Program Files\guard
  ok    files      guard.ps1 · guard.cmd · modules
  ..    path       adding for all users
```

Done:
```
guard  installing   [==============================]  100%   8/8

  ok    check      PowerShell 5.1 · Windows 11 · user ojhas
  ok    uac        on · admin rights granted
  ok    folder     C:\Program Files\guard
  ok    files      guard.ps1 · guard.cmd · modules
  ok    path       added for all users
  ok    task       "guard" · runs as SYSTEM · at logon · hidden · restarts itself if it stops
  ok    guard      background guard running
  ok    memory     nothing from an earlier install

  installed successfully.                                                        ← green
  type:  guard                                                                   ← guard in cyan
```

`guard` works right away in the same window, PowerShell or Command Prompt: besides PATH, the install puts a one-line `guard.cmd` in `C:\Windows`, which every terminal already searches, also ones opened before the install. Only admins can write there.

Failed (install stops, later steps skipped, problem and fix always at the bottom):
```
guard  installing   [====--------------------------]   13%   1/8   stopped

  ok    check      PowerShell 5.1 · Windows 11 · user ojhas
  FAIL  uac        User Account Control is turned off
  --    folder     skipped
  --    files      skipped
  --    path       skipped
  --    task       skipped
  --    guard      skipped
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

guard runs as administrator. click Yes on the prompt.
```

UAC prompt → Yes → guard opens in the same terminal window, below what was already there (no clear screen):

```
UAC prompt is successful.                                                       ← green

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

  _Screenshots folder is successfully protected                                  ← green
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

guard runs as administrator. click Yes on the prompt.
```

UAC prompt → Yes → guard opens in the same terminal window, below what was already there (no clear screen):

```
UAC prompt is successful.                                                       ← green

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

  _Screenshots folder is successfully moved and protected                        ← green
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

  Tax folder is successfully protected                                           ← green
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

Started from a terminal that was already running as administrator (no prompt; green, once, at the top when guard opens, in place of "UAC prompt is successful."):
```
admin     running as administrator  ·  no prompt needed
```

---

## 11. update

```
guard> update

guard  updating 1.0 → 1.1   [==============================]  100%   8/8

  ok    check      PowerShell 5.1 · Windows 11 · user ojhas
  ok    uac        on · admin rights granted
  ok    folder     C:\Program Files\guard  (already there)
  ok    files      1 of 5 files updated · guard.cmd same
  ok    path       already there
  ok    task       "guard" · runs as SYSTEM · at logon · hidden · restarts itself if it stops
  ok    guard      background guard restarted
  ok    folders    2 protected folders untouched · 59 files still locked

  updated successfully.                                                          ← green
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

  Guard is successfully uninstalled.                                             ← green
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
guard  installing   [==============================]  100%   8/8

  ok    check      PowerShell 5.1 · Windows 11 · user ojhas
  ok    uac        on · admin rights granted
  ok    folder     C:\Program Files\guard
  ok    files      guard.ps1 · guard.cmd
  ok    path       added for all users
  ok    task       "guard" · runs as SYSTEM · at logon · hidden · restarts itself if it stops
  ok    guard      background guard running
  ok    memory     found in C:\Users\ojhas\Downloads\_Screenshots  ·  lists 4 folders

  installed successfully.                                                        ← green

  guard memory found. it lists 4 protected folders:
    1  C:\Users\ojhas\Downloads\_Screenshots    found      47 files
    2  C:\Users\ojhas\Documents\Tax             found      12 files
    3  D:\Keep\Invoices                          not found
    4  D:\Keep\Photos                            not found

  Restore protection for the 2 found folders?
  > 1  yes
    2  no, start fresh
  type 1 or 2 or ↑ ↓ then Enter > 1

  access    your account (ojhas) given access to both folders                   ok
  owner     folders + 59 files        now owned by SYSTEM                        ok
  locking   folders, folders above, 59 files                                     ok
  memory    _guard.json updated in both  ·  2 missing folders kept in the list  ok

  2 folders are successfully protected                                           ← green
  type:  guard                                                                   ← guard in cyan
```

- "access" step: files restored to a new Windows with their old permissions can show "access denied" even to open, because to Windows the new account is a different account even with the same name. Restore grants your current account access first, then locks. That is the only place accounts come into it.
- The 2 missing folders stay in the list and show `NOT FOUND` in red in the status block, with `next  type  use 3  then  remove  to forget it, or  init <new path>`.
- `init` on a folder that already has a `_guard.json` asks the same restore question.
- The newest `_guard.json` wins if copies disagree (e.g. one folder restored from an older backup).
