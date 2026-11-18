# Tab completion — demo

Type the first letters, press Tab.

- One match → filled in.
- Several → filled in as far as they agree, and a list opens under the line. The first one is marked with `>` (green).
- Each choice starts right under the word being completed, with the `>` two columns before it.

Keys while the list is open:

| key | does |
|---|---|
| ↑ ↓ or Tab / Shift+Tab | move the mark |
| Enter | put the marked one in the line (Enter again runs it) |
| letters | narrow the list as you type |
| Backspace | widen it again |
| Esc | close the list, keep what you typed |

---

## 1. Several commands

```
 guard> e                                           ← e + Tab
      > edit                                        ← marked (green)
        exit
```

↓:

```
 guard> e
        edit
      > exit                                        ← marked (green)
```

Enter:

```
 guard> exit                                        ← in the line, list closed. Enter again runs it
```

---

## 2. Filled in as far as they agree

```
 guard> re                                          ← r + Tab: both start with "re"
      > resume
        remove
```

---

## 3. One match

```
 guard> he                                          ← he + Tab
```

```
 guard> help                                        ← filled in, no list
```

---

## 4. help: the start table, and typing narrows it

After `help`, the list is the same table guard shows when it starts: its headings, every row, and the explanations. The row you pick puts its command in the line.

```
 guard> help                                        ← help + space + Tab
             -------------------- Guard ---------------------
           > folders                   show all protected folders
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
```

Type `r`: only the matching rows stay, under their headings:

```
 guard> help r
             ------------ All protected folders -------------
           > resume all                lock every folder
             remove all                stop protecting every folder
             ---------------- Current folder ----------------
             resume                    lock the folder
             remove                    stop protecting the folder
```

Type `li` instead:

```
 guard> help li
             ---------------- Current folder ----------------
           > list                      show files and folders  ← only one left
```

A list taller than the window scrolls as the mark moves. Other lists show 8 rows at a time.

Enter, Enter:

```
 guard> help list

   list
   show files in the current folder, newest first, with date and size · list all = every folder
```

---

## 5. File names in the current folder

```
 guard> delete am                                   ← delete am + Tab
             > amazon-2.png
               amazon-3.png
               amazon-checkout.png
```

Type `-c`:

```
 guard> delete amazon-c
             > amazon-checkout.png
```

---

## 6. Folder paths

```
 guard> init C:\Users\ojhas\D                       ← init C:\Users\ojhas\D + Tab
           > C:\Users\ojhas\Desktop
             C:\Users\ojhas\Documents
             C:\Users\ojhas\Downloads
```

Type `o`:

```
 guard> init C:\Users\ojhas\Do
           > C:\Users\ojhas\Documents
             C:\Users\ojhas\Downloads
```

Esc:

```
 guard> init C:\Users\ojhas\Do                      ← list closed, the line stays
```

The same works in the "type a folder path" question of `move folder`.
