# notepanel

A floating Markdown scratchpad for macOS. A global shortcut brings it up over any app, even one in
full screen; you write with VS Code's keys; hiding it returns you to the app you were in. Each note
is a plain `.md` file in a folder you choose, named after the note's first line.

It combines the invocation and window of [tinycast](https://github.com/abue-ammar/tinycast)'s Notes
with the editing of [Heynote](https://github.com/heyman/heynote), whose editor is CodeMirror 6.
The design and the agreed feature list are in [docs/design.md](docs/design.md) (Japanese).

## Build

Needs macOS 14 or later and Swift 5.10 or later. The Command Line Tools are enough; Xcode isn't
needed.

```sh
scripts/bundle.sh                         # builds build/notepanel.app
cp -R build/notepanel.app /Applications/  # optional
open build/notepanel.app
```

The app lives in the menu bar. Press <kbd>⌃⌘N</kbd> to show or hide it, or click the menu bar icon.
Right-click the icon for New Note, Search Notes, Settings, the backups folder and Quit. ⌘Q in the
panel or in Settings also quits.
You can hide the icon in Settings; then press ⌘, in the panel, or open notepanel again, to get to
Settings.

## Notes and safety

- A note's file name follows its first line (`# Shopping list` → `Shopping list.md`), numbered if
  the name is taken, until you rename the note yourself by clicking its name in the title bar.
- Text is saved 300 ms after you stop typing, and at once when you hide the panel, switch notes or
  quit. If a save fails, the footer says so, the text stays in the app, and quitting asks first.
- A file changed in another app is never overwritten: your text goes to a `(conflict …)` copy.
- Before a save overwrites a note, the previous contents are kept in
  `~/Library/Application Support/notepanel/Backups` (at most every 10 minutes per note, for 30 days).
- Moving a note to the Trash asks first, and the Trash keeps it.

Node is only needed to change the editor page. `web/editor.js` is built from `editor/` and kept in
the repository:

```sh
cd editor
npm ci
npm run build   # writes ../web/editor.js
```

## Test

```sh
swift run NotepanelChecks   # NotepanelCore: saving, conflicts, naming, window fitting
cd editor && npm test       # editor helpers: search ranking, links, line insertion, counts
cd editor && npm run smoke  # the editor page in headless Chrome, posing as a Mac
```

`NotepanelChecks` is a plain executable of assertions rather than an XCTest target, because XCTest
comes only with Xcode.

The smoke test needs Google Chrome; set `CHROME` to its binary if it isn't in `/Applications`.

To inspect the editor page in the running app, enable Safari's Develop menu; notepanel's page is
listed there.

## Keys

| Key | Does |
|---|---|
| ⌘N / ⌘P / ⌘O / ⌘, | New note / switch notes / open the notes folder / settings |
| ⌘+ / ⌘− / ⌘0 | Bigger / smaller / default note text (the interface text size is in Settings) |
| ⌃Tab / ⌃⇧Tab | Next / previous note, pinned notes first (change them in Settings) |
| ⌘W, Esc | Hide (Esc first closes search, extra cursors or the switcher) |
| ⌘Q | Quit (it saves first, and asks if something couldn't be saved) |
| ⌘⌫ | Delete to the line start; at the start of a line, join it with the line above |
| ⌘← / ⌘→ | Line start (after the indentation first) / line end |
| ⌥↑ / ⌥↓, ⇧⌥↑ / ⇧⌥↓ | Move lines, copy lines |
| ⇧⌘K, ⌘L | Delete line, select line |
| ⌘Enter / ⇧⌘Enter | Insert a line below / above |
| ⌘D, ⇧⌘L, ⌘⌥↑ / ⌘⌥↓, ⌥-click | Multiple cursors |
| ⇧⌥-drag | Rectangular selection |
| ⌘F, ⌘G / ⇧⌘G | Find and replace, next / previous |
| ⌘-click | Open a link |
| In the switcher: ↑↓, Enter, ⌘⌫ | Choose, open, move to the Trash (each row also has Pin and Trash buttons) |

Click the note's name in the title bar to rename it. The panel keeps the size you give it.
