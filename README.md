# notepanel

English | [日本語](README.ja.md)

A floating notepad for macOS. Press `Ctrl+Cmd+N` in any app, even one in full screen, and a
note panel appears on top of it. Edits (like VS Code), press `Ctrl+Cmd+N` again (or `Cmd+W`, `Esc`), and you're back in the app you were
using.

Each note is a plain Markdown file in a folder you choose, so you can also open your notes in any
other editor, sync them or back them up as you like.

<img src="docs/img/note.png" width="480" alt="note">

## Features

- **Opens over everything.** The panel floats above other windows, full-screen apps included, on
  every Space. Showing it doesn't switch apps: the app you were in stays active, and gets the focus
  back when you hide the panel.
- **Small and light.** The app is about 2 MB.
- **Edits like VS Code.** The editor is CodeMirror 6 with VS Code's keys: multiple cursors,
  rectangular selection, moving and copying lines, and find and replace. It also highlights
  Markdown, continues lists when you press `Return`, and adds or removes bold, italic and other
  marks with `Cmd+B`, `Cmd+I` and the like.
- **Plain files.** Each note is a `.md` file named after its first line.
- **Hard to lose text.** It saves as you type, never overwrites a file another app changed, and
  keeps earlier versions of each note, which `Cmd+Y` shows.
- **Quick to switch notes.** `Cmd+P` searches the names and text of your notes, and
  `Ctrl+Tab` goes to the next one. Pinned notes come first, in the order you give them, and
  `Cmd+1` to `Cmd+9` open them.

## Install

You need macOS 14 Sonoma or later. Install notepanel with [Homebrew](https://brew.sh):

```sh
brew install kkensuke/tap/notepanel
open /Applications/notepanel.app
```

The app is signed ad hoc, not notarized by Apple, so macOS would refuse to open it; Homebrew
removes its quarantine flag after installing it.

notepanel lives in the menu bar, as a note icon, and has no Dock icon. The shortcut needs no
Accessibility permission. To start notepanel when you log in, turn on **Open at login** in Settings.

To update, run `brew upgrade notepanel`. It quits notepanel first, so open it again afterwards.

### Building it yourself

You need Swift 5.10 or later. The Command Line Tools are enough (`xcode-select --install`); you
don't need Xcode.

```sh
git clone https://github.com/kkensuke/notepanel.git
cd notepanel
scripts/bundle.sh                         # builds build/notepanel.app
cp -R build/notepanel.app /Applications/
open /Applications/notepanel.app
```

To update, run `git pull` and `scripts/bundle.sh` again, quit notepanel (`Cmd+Q` in the
panel), copy the new app to `/Applications`, and open it.

## Using it

- **Show and hide.** Press `Ctrl+Cmd+N`, or click the menu bar icon. `Esc` or
  `Cmd+W` hides the panel.
- **Notes.** `Cmd+N` starts a new note. `Cmd+P` opens the switcher: type to search,
  then press `Return` to open the note. A note found by its text opens with the match selected.
  Each row has a pin button and a trash button.
- **Earlier versions.** `Cmd+Y` lists the note's earlier versions, newest first, with the chosen
  one's text below. `Return` or a row's button copies a whole version; to copy part of one, select
  it and press `Cmd+C`. Nothing there changes the note: to go back to a version, copy it, press
  `Esc`, and paste it over the note.
- **Pinned notes.** Pinned notes come first in the switcher and when you go through notes with
  `Ctrl+Tab`. To change their order, drag the handle at the left of a row, or press `Option+Up`
  and `Option+Down`, while the search field is empty. `Cmd+1` to `Cmd+9` open the first to ninth
  pinned note; the switcher shows each one's key next to its pin.
- **Names.** A note is named after its first line: `# Shopping list` is saved as
  `Shopping list.md`. If another note has that name, a number is added. To choose a name yourself,
  click the name in the title bar; from then on the name stays as you set it.
- **Links.** Cmd-click a link to open it. Pointing at a link shows two buttons on its first
  characters: one opens it, the other copies the URL.
- **Tasks.** Click the box of a task (`- [ ]` or `- [x]`) to tick or clear it. The box stays as
  text; `Cmd+Z` undoes the click.
- **Dropping files.** Drop a text file, such as a Markdown file, on the note to insert its text
  where you drop it. The file itself isn't opened or changed. Several files go in on separate
  lines, and files that aren't text are skipped. `Cmd+Z` undoes it.
- **Menu.** Right-click the menu bar icon (or Control-click it) for New Note, Search Notes,
  Settings, Keyboard Shortcuts, the history folder and Quit. Each item shows its key in the panel.
- **Keys.** `Shift+Cmd+/` in the panel lists all the keys. The list is also in Settings →
  Shortcuts and in the menu bar icon's menu.
- **Size.** The panel keeps the size you give it. `Cmd+Plus` and `Cmd+Minus` change the
  note's text size, and `Cmd+0` resets it.
- **Default place.** `Ctrl+Cmd+M` moves the panel to its default place and size on the display
  with the pointer, which also brings it back if it ended up off the screen. Pressed again before
  you move the panel, it goes back to where it was. Each display has its own default. The standard
  one is the panel's first size, centered; to choose your own, put the panel where you want it on
  that display and click **Use Current** in Settings.

## Settings

Open Settings with `Cmd+,` in the panel, or from the menu bar icon's menu.

- **General:** the data folder, which holds your notes and their history, how long to keep
  history, the panel's default place and size on the display it's on (for
  `Ctrl+Cmd+M`; **Reset** goes back to the standard one), the
  note font (one of the monospaced fonts on your Mac), the size of the interface text, the opacity
  of the panel's background, whether to show spaces, tabs and full-width spaces, how many spaces
  the Tab key indents by (2 or 4), whether the menu bar icon shows, and Open at login. The background opacity slider starts in the middle, at the default
  translucent background, which a short mark under the slider shows: move it left to see more of
  what's behind the panel, or right for a solid background. The text stays as it is.
- **Shortcuts:** the shortcuts that work from any app (show or hide notes, new note, search notes)
  and the ones that work in the panel (next and previous note, default place). Click a shortcut and
  press the keys. `Esc` cancels, and the × button removes the shortcut. So that a shortcut doesn't
  take keys you type with, one from any app needs Control or Option, or Shift and Command, and one
  in the panel needs Command or Control. Keys that another shortcut or the panel already uses
  aren't taken, and the field says why.

If you hide the menu bar icon, you can still reach Settings: press `Cmd+,` in the panel, or
open notepanel again from Finder or Spotlight.

## Your notes and their safety

- **Where they are.** Notes are kept in the `Notes` folder of notepanel's data folder, which is
  `~/Library/Application Support/notepanel` unless you choose another one in Settings, such as a
  folder that syncs. notepanel lists the `.md` files at the top of `Notes`, not in subfolders.
  Choosing another data folder doesn't move your notes: move them into its `Notes` folder.
- **Saving.** Text is saved 0.3 seconds after you stop typing, and at once when you hide the
  panel, switch notes or quit. The icon left of the note's name shows a dashed circle while the text
  isn't saved yet and a checked circle once it is. If a save fails, the icon turns into a red warning, the bottom
  of the panel says why, the text stays in notepanel, and quitting asks before it drops anything.
- **Changes from other apps.** notepanel reads a note again when you show the panel or open the
  note. If the file changed on disk while you had unsaved text, your text goes to a separate copy
  named `… (conflict date time).md`, and the file on disk is left alone.
- **History.** Before a save replaces a note, the earlier text is kept as a version in the data
  folder's `History`, in a folder named after the note, at most once every 10 minutes per note.
  All versions from the last hour stay, then the newest in each hour for a day, in each day for a
  week, and in each week after that: forever, or for a year if you choose so in Settings. A note's
  history follows it when notepanel renames it, and stays when the note goes to the Trash. If a
  new note later takes the name of one that's gone, the old history is renamed
  `… (old date time)`. Versions are plain text files named with the date and time.
- **Deleting.** Moving a note to the Trash asks first, and you can restore it from the Trash in
  Finder.
- **Other files.** notepanel won't open a file that isn't UTF-8 text, and leaves it unchanged.

## Keys

notepanel shows this list too: press `Shift+Cmd+/` in the panel.

In the panel, Settings and the list of keys:

| Key | Does |
|---|---|
| ⌘, / ⇧⌘/ | Open or close Settings / the list of keys |
| ⌘Q | Quit (it saves first, and asks if something couldn't be saved) |

In the panel:

| Key | Does |
|---|---|
| ⌘N / ⌘P / ⌘O | New note / switch notes / open the notes folder with this note selected |
| ⌘Y | Earlier versions of this note |
| ⌃Tab / ⌃⇧Tab | Next / previous note, pinned notes first (change them in Settings) |
| ⌘1 … ⌘9 | Open the first … ninth pinned note |
| ⌘+ / ⌘− / ⌘0 | Bigger / smaller / default note text |
| ⌃⌘M | Panel to its default place and size on the pointer's display; again, back to where it was (change it in Settings) |
| ⌘W, Esc | Hide (Esc first closes search, extra cursors, the switcher or earlier versions) |
| In the switcher: ↑↓, Return, ⌘⌫ | Choose, open, move to the Trash |
| In the switcher: ⌥↑ / ⌥↓ | Move a pinned note up / down (with the search field empty) |
| In earlier versions: ↑↓, Return, ⌘A, ⌘C | Choose, copy all of it, select all of it, copy the selection |

Editing:

| Key | Does |
|---|---|
| ⌘⌫ | Delete to the line start; at the start of a line, join it with the line above |
| ⌘← / ⌘→ | Line start (after the indentation first) / line end |
| ⌥↑ / ⌥↓, ⇧⌥↑ / ⇧⌥↓ | Move lines, copy lines |
| ⇧⌘K, ⌘L | Delete line, select line |
| ⌘Return / ⇧⌘Return | Insert a line below / above |
| ⌘D, ⇧⌘L, ⌥⌘↑ / ⌥⌘↓, ⌥-click | Multiple cursors |
| ⇧⌥-drag | Rectangular selection |
| ⌘F, ⌘G / ⇧⌘G | Find and replace, next / previous |
| ⌘B / ⌘I / ⇧⌘X / ⌘E | Bold / italic / strikethrough / code: puts `**`, `*`, `~~` or `` ` `` around the selection, or takes them away |
| ⌘K | Make the selection a link's text (a selected URL becomes its target) |
| ⌘-click | Open a link |
| Click `[ ]` / `[x]` | Tick / clear a task |

## Troubleshooting

- **`Ctrl+Cmd+N`, `Ctrl+Cmd+M` or another shortcut does nothing.** Another app may already use
  that shortcut. Choose another one in Settings → Shortcuts.
- **I need an earlier version of a note.** Press `Cmd+Y` in the note. For a note that's gone, or
  one renamed in Finder, right-click the menu bar icon and choose Open History Folder: each
  note's versions are in a folder named after it.
- **Uninstalling.** Turn off Open at login, then run `brew uninstall notepanel`, which also quits
  notepanel. If you built the app yourself, quit notepanel and delete `/Applications/notepanel.app`.
  Its settings are removed with `defaults delete io.github.kkensuke.notepanel`. Unless you chose
  another data folder, `~/Library/Application Support/notepanel` holds your notes and their
  history: keep it, or move your notes out before deleting it.
  `brew uninstall --zap notepanel` removes the settings and the history there, but not the notes.

## Development

| Path | What it is |
|---|---|
| `Sources/Notepanel` | The app (AppKit): the panel, the menu bar icon, Settings |
| `Sources/NotepanelCore` | Reading and saving notes, with no UI |
| `editor/` | The editor page (CodeMirror 6), built into `web/editor.js` |
| `web/` | The page the panel shows in a web view |
| `docs/design.md` | The design and the feature list (in Japanese) |
| `docs/history.md` | The design of note history (in Japanese) |
| `docs/releasing.md` | How to publish a release |

Node is needed only to change the editor page. `web/editor.js` and `web/THIRD_PARTY_LICENSES.txt`,
the licenses of the packages bundled into it, are kept in the repository:

```sh
cd editor
npm ci
npm run build   # writes ../web/editor.js and ../web/THIRD_PARTY_LICENSES.txt
```

Tests:

```sh
swift run NotepanelChecks   # NotepanelCore: saving, conflicts, naming, history
cd editor && npm test       # editor helpers: search ranking, links, line insertion, formatting, tasks, counts
cd editor && npm run smoke  # the editor page in headless Chrome, posing as a Mac
```

`NotepanelChecks` is a plain executable of assertions rather than an XCTest target, because XCTest
comes only with Xcode. The smoke test needs Google Chrome; set `CHROME` to its binary if it isn't
in `/Applications`. To inspect the editor page in the running app, enable Safari's Develop menu;
notepanel's page is listed there.

## Credits

The editor is [CodeMirror 6](https://codemirror.net).

## License

[MIT](LICENSE)
