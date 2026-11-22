// The switcher: this page in a window of its own, beside the panel. It asks Swift to show a row's
// note, and the note's page puts the cursor there and marks what the search found.
import {rankNotes, snippetAt} from "./logic.js"
import {post, $, element, marked, actionButton, drag} from "./dom.js"

const switcher = $("switcher")
const query = $("query")
const results = $("results")
const total = $("total")

let notes = []
// The list's rows, which the arrows go through: a note, or a match in a note's text, shown as
// the line it's on. `at` is the match the row opens the note at, as its place in the note's
// matches, or -1 on a note with none. `item` is the row's element.
let rows = []
let selected = 0
// The row whose note the list last showed beside itself, while the list is the same.
let shown = null
// The note that was open when the switcher opened. A search lists it first.
let origin = null
// Whether the search hot key brought the panel up, so that Escape hides the panel too.
let dismiss = false

export const isSwitcherOpen = () => !switcher.hidden
// Swift sends the pinned notes first, in the user's order. Searching sorts by match, so pinned
// notes are moved only in the full list.
const pinnedCount = () => notes.filter(note => note.pinned).length
const canMove = note => note.pinned && !query.value.trim()
const savePinOrder = () => post("orderPins", {ids: notes.filter(note => note.pinned).map(note => note.id)})
// CodeMirror reads every line break as "\n", so a place found in a note's text is the same place
// in the editor only once the text has them too.
export const lineFeeds = list => list.map(note => ({...note, text: note.text.replace(/\r\n?/g, "\n")}))

function movePinned(from, to, save = true) {
  if (from < 0 || from === to || to < 0 || to >= pinnedCount()) return
  notes.splice(to, 0, ...notes.splice(from, 1))
  selected = to
  update()
  if (save) savePinOrder()
}

// Dragging a pinned note by its key moves it among the pinned notes; the order is saved on release.
function dragPinned(event, note) {
  event.preventDefault()
  event.stopPropagation()
  if (event.button !== 0) return
  const move = ({clientY}) => {
    const items = [...results.children].slice(0, pinnedCount())
    const over = items.findIndex(item => clientY < item.getBoundingClientRect().bottom)
    // The rows show copies of the notes, so the note is found by its id.
    movePinned(notes.findIndex(({id}) => id === note.id), over < 0 ? items.length - 1 : over, false)
  }
  drag("dragging", move, savePinOrder)
}

// ⌘P brings the switcher up with the focus in the list, on the open note (`current`), so the
// arrows go from note to note at once. ⌘F brings it up with the focus in the search field, and
// with some of a line selected in the note (`picked`) finds that, as typing it and Return would.
// Each is a toggle: pressed with the focus already where it puts it, it closes the switcher, and
// otherwise takes the focus there. `key` says whether this window has the focus at all. The list
// button closes the switcher wherever the focus is (`toggle`), and the search hot key never does
// (`force`).
export function showSwitcher(
  list,
  {find = false, force = false, toggle = false, dismiss: fromHotKey = false, current = null, key = false, picked = ""},
) {
  notes = list
  const target = find ? query : results
  if (isSwitcherOpen() && !force && (toggle || (key && document.activeElement === target))) return closeSwitcher()
  if (!isSwitcherOpen() || picked) {
    origin = current
    query.value = picked
    back = 0
  }
  if (!isSwitcherOpen()) {
    dismiss = fromHotKey
    switcher.hidden = false
    selected = Math.max(0, notes.findIndex(note => note.id === current))
  }
  update()
  target.focus()
  if (find) query.select()
  // Swift brings the window up, if it isn't, and gives it the focus. The window is at most as tall
  // as the search field and ten notes' rows, each twice the text size as style.css makes them,
  // with the edge above and below.
  const row = 2 * parseFloat(getComputedStyle(document.body).fontSize)
  post("switcherShown", {shown: true, height: query.parentElement.offsetHeight + 10 * row + 2})
  if (picked) toFirstRow()
}

// From the search field to the top of the list, whose note shows.
function toFirstRow() {
  if (!rows.length) return
  results.focus()
  show(0)
}

// The note in sight stays the open one. A search not used yet is remembered here. Swift takes
// the window away, the marks in the note with it, and gives the note the focus.
export function closeSwitcher() {
  if (!isSwitcherOpen()) return
  remember()
  switcher.hidden = true
  post("switcherShown", {shown: false})
}

// Dragging the switcher's left edge changes its width. Swift moves the window's left edge, so the
// width goes by how far the pointer has moved on the screen.
$("edge").addEventListener("mousedown", event => {
  event.preventDefault()
  if (event.button !== 0) return
  const start = event.screenX
  const width = innerWidth
  drag("resizing", ({screenX}) => post("sideWidth", {width: width + start - screenX}))
})

// What was searched for before, oldest first. A search is remembered once it's used, to go to a
// row, or as the switcher closes. In the search field ↑ goes back through them and ↓ comes
// forward again, as in VS Code, as far as what was typed before going back. `back` is how many
// back the field is.
// shortcut: lasts until the app quits; send it to Swift to keep it.
const searches = []
let back = 0
let typed = ""

function remember() {
  const text = query.value.trim()
  if (!text) return
  const at = searches.indexOf(text)
  if (at >= 0) searches.splice(at, 1)
  searches.push(text)
  if (searches.length > 50) searches.shift()
  back = 0
}

function recall(step) {
  let to = back + step
  // A search the field already has is no step.
  while (to > 0 && searches[searches.length - to] === query.value.trim()) to += step
  if (to < 0 || to > searches.length) return
  if (!back) typed = query.value
  back = to
  query.value = back ? searches[searches.length - back] : typed
  if (back) query.select()
  selected = 0
  update()
}

// Shows a row's note beside the switcher: Swift opens it in the note's page, which puts the
// cursor on the row's match.
function show(index) {
  select(index)
  const row = rows[selected]
  if (!row || row === shown) return
  remember()
  shown = row
  post("select", {id: row.note.id, land: {query: query.value, place: row.note.matches[row.at] ?? null}})
}

// Ranks the notes for what's typed, and lists them: with nothing typed as rows, and while
// searching each as its name over its matches, each on its line. What draws a note adds the
// note's rows to `rows`. As the search field changes, the note's page marks the matches in the
// note in sight.
// shortcut: stops after the note that takes the list past 500 rows; the notes after it show
// once more is typed.
function update() {
  const searching = Boolean(query.value.trim())
  const found = rankNotes(notes, query.value)
  // A search lists the note it started from first, over the others.
  const mine = searching ? found.findIndex(note => note.id === origin) : -1
  if (mine > 0) found.unshift(...found.splice(mine, 1))
  const draw = searching ? group : noteRow
  rows = []
  shown = null
  const items = []
  for (const note of found) {
    if (rows.length >= 500) break
    items.push(draw(note))
  }
  total.textContent = `${found.length} ${found.length === 1 ? "note" : "notes"}`
  results.replaceChildren(...(items.length ? items : [element("li", "empty", "No notes match")]))
  select(selected)
  post("marks", {query: query.value})
}

function select(index) {
  rows[selected]?.item.setAttribute("aria-selected", "false")
  selected = Math.max(0, Math.min(index, rows.length - 1))
  const active = rows[selected]?.item
  for (const owner of [query, results]) {
    if (active) owner.setAttribute("aria-activedescendant", active.id)
    else owner.removeAttribute("aria-activedescendant")
  }
  if (!active) return
  active.setAttribute("aria-selected", "true")
  active.scrollIntoView({block: "nearest"})
}


// A press of the mouse on `node` shows the note of the row `index()` gives beside the switcher,
// and a double click closes the switcher on it, as Return does in the list.
function showsOnPress(node, index) {
  node.addEventListener("mousedown", event => {
    event.preventDefault()
    results.focus()
    show(index())
  })
  node.addEventListener("dblclick", closeSwitcher)
}

// A row to choose, added to `rows`: an option of the list.
function option(tag, className, note, at) {
  const row = {note, at, item: element(tag, className, "")}
  row.item.id = `note-${rows.length}`
  row.item.setAttribute("role", "option")
  row.item.setAttribute("aria-selected", "false")
  showsOnPress(row.item, () => rows.indexOf(row))
  rows.push(row)
  return row.item
}

// With nothing typed, a row is a note as it ever was: its handle, its name and its buttons, which
// show all the time, so rows keep one height as the pointer moves.
function noteRow(note) {
  const item = option("li", "", note, -1)
  item.classList.toggle("movable", canMove(note))
  // ⌘1 to ⌘9 open the first nine pinned notes, which Swift lists first. The key is also what a
  // pinned note is dragged by, which leaves the row's width to the name; ⌥↑ and ⌥↓ do the same
  // from the keyboard.
  // shortcut: a pinned note past the ninth has no key, so only ⌥↑ and ⌥↓ move it.
  const number = note.pinned ? notes.findIndex(({id}) => id === note.id) + 1 : 0
  const key = element("span", "key", number >= 1 && number <= 9 ? `⌘${number}` : "")
  if (canMove(note)) {
    key.title = "Drag to reorder (⌥↑ ⌥↓)"
    key.addEventListener("mousedown", event => dragPinned(event, note))
  }
  const actions = element("span", "actions", "")
  actions.append(
    key,
    actionButton("pin", note.pinned ? "Unpin" : "Pin", () => post("pin", {id: note.id}), Boolean(note.pinned)),
    actionButton("trash", "Move to Trash (⌘⌫)", () => post("trash", {id: note.id})),
  )
  item.append(element("span", "title", note.title), actions)
  return item
}

// While searching, a note is its name over its matches, each as the line it's on; a line with two
// matches is there twice. The lines are the rows to choose. The name isn't one: the arrows pass
// it, and a press on it shows the first line. A note with no line to list is a row itself, and
// opens at the match in its first line, which its name is, if that's where the word was found.
function group(note) {
  const item = element("li", "group", "")
  item.setAttribute("role", "presentation")
  const first = rows.length
  const name = note.lines.length
    ? element("div", "name", "")
    : option("div", "name", note, note.matches.length ? 0 : -1)
  name.append(marked("span", "title", note.title, note.titleRanges))
  item.append(name)
  for (const at of note.lines) {
    const snippet = snippetAt(note.text, note.matches[at])
    const line = option("div", "line", note, at)
    line.append(marked("span", "snippet", snippet.text, snippet.ranges))
    item.append(line)
  }
  if (note.lines.length) showsOnPress(name, () => first)
  return item
}

query.addEventListener("input", () => {
  selected = 0
  back = 0
  update()
})

// Keys in the search field and in the list, which don't pass the focus to each other with the
// arrows. In the field ↑ and ↓ go through the searches made before, and Return takes the focus
// to the top of the list. In the list ↑ and ↓ go through the rows, each row's note showing
// beside the list, and Return closes the switcher on the chosen row's note. Tab goes from one
// to the other.
function onKey(event) {
  // Keys that confirm or cancel an input method's composition belong to it.
  if (event.isComposing || event.keyCode === 229) return
  const inList = event.currentTarget === results
  const row = rows[selected]
  const command = event.metaKey && !event.ctrlKey && !event.altKey
  let handled = true
  if (event.altKey && !event.metaKey && !event.ctrlKey && /^Arrow(Up|Down)$/.test(event.key)) {
    if (row && canMove(row.note)) movePinned(selected, selected + (event.key === "ArrowUp" ? -1 : 1))
  } else if (event.key === "ArrowDown") {
    if (inList) show(selected + 1)
    else recall(-1)
  } else if (event.key === "ArrowUp") {
    if (inList) show(selected - 1)
    else recall(1)
  } else if (event.key === "Tab") {
    if (inList) query.focus()
    else results.focus()
  } else if (event.key === "Enter") {
    if (!inList) toFirstRow()
    else {
      // The chosen row's note stays open as the switcher closes.
      show(selected)
      closeSwitcher()
    }
  } else if (event.key === "Escape") {
    if (dismiss) post("escape")
    closeSwitcher()
  } else if (command && event.key === "Backspace") {
    if (row) post("trash", {id: row.note.id})
  } else if (command && event.key.toLowerCase() === "a" && !inList) {
    query.select()
  } else {
    handled = false
  }
  if (handled) event.preventDefault()
}

query.addEventListener("keydown", onKey)
results.addEventListener("keydown", onKey)

// A note opened some other way than from the list, by ⌃Tab or in place of one moved to the Trash,
// is chosen in the list, and what's typed is marked in it.
export function chooseNote(id) {
  const at = rows.findIndex(row => row.note.id === id)
  if (at >= 0) {
    select(at)
    shown = rows[at]
  }
  post("marks", {query: query.value})
}

// The switcher's rows are chosen by name, so a row with the old name would open nothing.
export function renameInList(from, to) {
  if (origin === from) origin = to
  for (const note of notes) if (note.id === from) note.id = note.title = to
  if (isSwitcherOpen()) update()
}

export function setNotes(list) {
  if (isSwitcherOpen()) {
    notes = lineFeeds(list)
    update()
  }
}

// Back where it was: the list or the search field.
export function focusSwitcher() {
  const target = document.activeElement === results ? results : query
  target.focus()
}
