# Tab completion — demo

Type the first letters, press Tab.

- One match → filled in.
- Several → filled in as far as they agree, and a list opens under the line. The first one is marked with `>` (green).

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
 guard> e                                       ← e + Tab
   > edit                                       ← marked (green)
     exit
```

↓:

```
 guard> e
     edit
   > exit                                       ← marked (green)
```

Enter:

```
 guard> exit                                    ← in the line, list closed. Enter again runs it
```

---

## 2. Filled in as far as they agree

```
 guard> re                                      ← r + Tab: both start with "re"
   > resume
     remove
```

---

## 3. One match

```
 guard> he                                      ← he + Tab
```

```
 guard> help                                    ← filled in, no list
```

---

## 4. Typing narrows the list

```
 guard> help                                    ← help + space + Tab
   > all
     list
     delete
     move
     edit
     resume
     init
     remove                                     ← 8 rows at a time, scrolls as the mark moves
```

Type `li`:

```
 guard> help li
   > list                                       ← only one left
```

Enter, Enter:

```
 guard> help list

   list
   show files in the current folder, newest first, with date and size · list all = every folder
```

---

## 5. File names in the current folder

```
 guard> delete am                               ← delete am + Tab
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
 guard> init C:\Users\ojhas\D                   ← init C:\Users\ojhas\D + Tab
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
 guard> init C:\Users\ojhas\Do                  ← list closed, the line stays
```

The same works in the "type a folder path" question of `move folder`.
