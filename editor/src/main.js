// The editor page: CodeMirror 6 for the note, and the note switcher on top of it.
// Swift calls `receive(message)`; the page answers with `post(type, data)`.
import {EditorState, Compartment, RangeSetBuilder} from "@codemirror/state"
import {
  EditorView,
  keymap,
  drawSelection,
  dropCursor,
  highlightSpecialChars,
  highlightWhitespace,
  rectangularSelection,
  Decoration,
  MatchDecorator,
  ViewPlugin,
  hoverTooltip,
} from "@codemirror/view"
import {defaultKeymap, historyKeymap, history, indentWithTab, selectLine} from "@codemirror/commands"
import {searchKeymap, highlightSelectionMatches} from "@codemirror/search"
import {markdown, markdownLanguage} from "@codemirror/lang-markdown"
import {syntaxHighlighting, HighlightStyle, indentUnit} from "@codemirror/language"
import {tags} from "@lezer/highlight"
import {
  rankNotes,
  urlAt,
  linkAt,
  listIndent,
  insertLineAbove,
  toggleMark,
  insertLink,
  toggleTask,
  countCharacters,
} from "./logic.js"

// Outside the app (in a plain browser) there is no handler, so nothing is sent.
const post = (type, data = {}) => window.webkit?.messageHandlers?.native?.postMessage({type, ...data})

const $ = id => document.getElementById(id)
const editorElement = $("editor")
const footer = $("footer")
const statusElement = $("status")
const countElement = $("count")
// Kept up to date in the footer's section below.
let footerHeight = 0
const switcher = $("switcher")
const query = $("query")
const results = $("results")

const highlight = HighlightStyle.define([
  {tag: tags.heading1, fontWeight: "bold", fontSize: "1.3em"},
  {tag: tags.heading2, fontWeight: "bold", fontSize: "1.15em"},
  {tag: [tags.heading3, tags.heading4, tags.heading5, tags.heading6], fontWeight: "bold"},
  {tag: tags.strong, fontWeight: "bold"},
  {tag: tags.emphasis, fontStyle: "italic"},
  {tag: tags.strikethrough, textDecoration: "line-through"},
  {tag: tags.monospace, color: "var(--code)"},
  {tag: tags.link, color: "var(--link)"},
  // A URL breaks at the panel's edge, so a list marker isn't left alone on its line.
  {tag: tags.url, color: "var(--link)", wordBreak: "break-all"},
  {tag: [tags.processingInstruction, tags.quote, tags.contentSeparator], color: "var(--muted)"},
  // A task's box: "[ ]" or "[x]", the only atom in Markdown. A click ticks or clears it.
  {tag: tags.atom, class: "cm-taskBox"},
])

const theme = EditorView.theme({
  "&": {height: "100%", fontSize: "var(--size)", color: "var(--fg)", backgroundColor: "transparent"},
  "&.cm-focused": {outline: "none"},
  ".cm-scroller": {fontFamily: "var(--font)", lineHeight: "1.6"},
  // Room at the end, so the last line can scroll clear of the footer.
  ".cm-content": {padding: "6px 0 calc(6px + var(--footer-height, 0px))", caretColor: "var(--fg)"},
  ".cm-line": {padding: "0 12px"},
  ".cm-cursor, .cm-dropCursor": {borderLeftColor: "var(--fg)"},
  "&.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground, .cm-selectionBackground":
    {backgroundColor: "var(--selection)"},
  ".cm-selectionMatch": {backgroundColor: "var(--match)"},
  // As in VS Code: a small dot in the middle of each space, in a faint color.
  ".cm-highlightSpace": {
    background: "radial-gradient(circle at 50% 55%, var(--whitespace) 0.07em, transparent 0.1em)",
  },
  // CodeMirror's arrow for a tab, cut out of the same color.
  ".cm-highlightTab": {
    background: "var(--whitespace)",
    mask: `url('data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" width="200" height="20"><path stroke="black" fill="none" d="M1 10H196L190 5M190 15L196 10M197 4L197 16"/></svg>') right 90% / auto 100% no-repeat`,
  },
  // The link popup: as tall as a row at any note font size, so it covers no other line.
  ".cm-tooltip.cm-tooltip-hover": {
    border: "1px solid var(--border)",
    borderRadius: "7px",
    backgroundColor: "var(--tooltip)",
    boxShadow: "0 2px 8px rgb(0 0 0 / 0.2)",
  },
  ".cm-linkButtons": {display: "flex", gap: "1px", padding: "0 2px", fontSize: "var(--size)"},
  ".cm-linkButtons .action": {padding: "2px", fontSize: "inherit"},
  ".cm-linkButtons .action svg": {width: "1em", height: "1em"},
  ".cm-taskBox": {cursor: "pointer", borderRadius: "3px"},
  ".cm-taskBox:hover": {backgroundColor: "var(--selection)"},
  ".cm-searchMatch": {backgroundColor: "var(--search)"},
  ".cm-searchMatch.cm-searchMatch-selected": {backgroundColor: "var(--search-current)"},
  ".cm-panels": {backgroundColor: "var(--panel)", color: "var(--fg)", fontSize: "calc(var(--ui-size) * 0.9)"},
  ".cm-panels.cm-panels-top": {borderBottom: "1px solid var(--border)"},
  ".cm-panels.cm-panels-bottom": {borderTop: "1px solid var(--border)", marginBottom: "var(--footer-height, 0px)"},
  ".cm-textfield, .cm-button": {
    backgroundColor: "var(--bg)",
    backgroundImage: "none",
    color: "var(--fg)",
    border: "1px solid var(--border)",
    borderRadius: "4px",
  },
})

// ---- Editor

// Full-width spaces look like nothing at all, so showing whitespace boxes them too.
const ideographicSpaces = new MatchDecorator({
  regexp: /\u3000/g,
  decoration: Decoration.mark({class: "cm-ideographicSpace"}),
})
const ideographicSpaceBoxes = ViewPlugin.define(
  view => ({
    decorations: ideographicSpaces.createDeco(view),
    update(update) {
      this.decorations = ideographicSpaces.updateDeco(update, this.decorations)
    },
  }),
  {decorations: plugin => plugin.decorations},
)

// A list item's wrapped rows start under its text, not under its marker. The 12px is the line's
// own padding.
function listIndents(view) {
  const builder = new RangeSetBuilder()
  for (const {from, to} of view.visibleRanges) {
    for (let pos = from; pos <= to; ) {
      const line = view.state.doc.lineAt(pos)
      const n = listIndent(line.text, view.state.tabSize)
      if (n) {
        const style = `padding-left: calc(12px + ${n}ch); text-indent: -${n}ch`
        builder.add(line.from, line.from, Decoration.line({attributes: {style}}))
      }
      pos = line.to + 1
    }
  }
  return builder.finish()
}
const hangingIndents = ViewPlugin.define(
  view => ({
    decorations: listIndents(view),
    update(update) {
      if (update.docChanged || update.viewportChanged) this.decorations = listIndents(update.view)
    },
  }),
  {decorations: plugin => plugin.decorations},
)

// From Settings. Each note keeps its own state, so these are applied again when a note opens.
const settings = new Compartment()
let showWhitespace = false
let indentSize = 4
const settingsExtensions = () => [
  // The spaces Tab adds; ⇧Tab takes as many away.
  indentUnit.of(" ".repeat(indentSize)),
  showWhitespace ? [highlightWhitespace(), ideographicSpaceBoxes] : [],
]

let currentId = null
// Each note's state, so its undo history and cursor survive switching notes.
const states = new Map()

// Pointing at a link shows Open and Copy buttons on the link's first characters ("https:"), in
// its own row: the pointer gets there without leaving the link, and no other line is covered.
const linkPopup = hoverTooltip(
  (view, pos) => {
    const line = view.state.doc.lineAt(pos)
    const link = linkAt(line.text, pos - line.from)
    if (!link) return null
    return {
      pos: line.from + link.from,
      end: line.from + link.to,
      strictSide: true,
      create: () => linkButtons(view, link.url, line.from + link.urlFrom),
    }
  },
  // At once; 1, since CodeMirror reads 0 as its default of 300 ms.
  {hoverTime: 1, hideOnChange: true},
)

function linkButtons(view, url, urlFrom) {
  const dom = document.createElement("div")
  dom.className = "cm-linkButtons"
  let timer = 0
  const copy = actionButton("copy", "Copy Link", () => {
    post("copy", {text: url})
    copy.innerHTML = iconSVG("check")
    clearTimeout(timer)
    timer = setTimeout(() => (copy.innerHTML = iconSVG("copy")), 1500)
  })
  dom.append(actionButton("open", "Open Link (⌘-click)", () => post("openURL", {url})), copy)
  return {
    dom,
    // CodeMirror puts the popup's top at this rectangle's bottom; this centers it on the row.
    getCoords() {
      const row = view.coordsAtPos(urlFrom, 1)
      if (!row) return null
      const top = (row.top + row.bottom - dom.parentElement.offsetHeight) / 2
      return {left: row.left, right: row.left, top, bottom: top}
    },
    destroy: () => clearTimeout(timer),
  }
}

// A key's command for an edit from logic.js, which takes the state and returns the transaction.
const run = edit => view => (view.dispatch(edit(view.state)), true)
const mark = text => run(state => toggleMark(state, text))

const extensions = [
  history(),
  drawSelection(),
  dropCursor(),
  highlightSpecialChars(),
  EditorState.allowMultipleSelections.of(true),
  // VS Code's mouse: Option-click adds a cursor, Shift-Option-drag selects a rectangle.
  EditorView.clickAddsSelectionRange.of(event => event.altKey && !event.shiftKey),
  rectangularSelection({eventFilter: event => event.altKey && event.shiftKey && event.button === 0}),
  highlightSelectionMatches(),
  EditorView.lineWrapping,
  // The cursor's line stays clear of the footer.
  EditorView.scrollMargins.of(() => ({bottom: footerHeight})),
  hangingIndents,
  linkPopup,
  markdown({base: markdownLanguage}),
  syntaxHighlighting(highlight),
  theme,
  settings.of(settingsExtensions()),
  keymap.of([
    {key: "Mod-l", run: selectLine, preventDefault: true},
    {key: "Mod-Shift-Enter", run: run(insertLineAbove)},
    {key: "Mod-b", run: mark("**")},
    // Ahead of the default ⌘I, which selects the enclosing syntax node.
    {key: "Mod-i", run: mark("*")},
    {key: "Mod-Shift-x", run: mark("~~")},
    {key: "Mod-e", run: mark("`")},
    {key: "Mod-k", run: run(insertLink)},
    ...defaultKeymap,
    ...historyKeymap,
    ...searchKeymap,
    indentWithTab,
    // Last, so it only runs when nothing above wanted Escape.
    {key: "Escape", run: () => (post("escape"), true)},
  ]),
  EditorView.updateListener.of(update => {
    if (update.docChanged && currentId !== null) {
      // shortcut: sends the whole text on every change; fine for notes, revisit past ~1 MB.
      post("changed", {id: currentId, text: update.state.doc.toString()})
      scheduleCount()
    }
  }),
  EditorView.domEventHandlers({
    mousedown(event, view) {
      if (event.button !== 0) return false
      const box = event.target.closest(".cm-taskBox")
      if (box && !event.metaKey && !event.altKey && !event.shiftKey && !event.ctrlKey) {
        const change = toggleTask(view.state, view.posAtDOM(box))
        if (!change) return false
        // The cursor stays where it was.
        event.preventDefault()
        view.dispatch(change)
        return true
      }
      if (!event.metaKey || event.altKey || event.shiftKey) return false
      const pos = view.posAtCoords({x: event.clientX, y: event.clientY})
      if (pos === null) return false
      const line = view.state.doc.lineAt(pos)
      const url = urlAt(line.text, pos - line.from)
      if (!url) return false
      event.preventDefault()
      post("openURL", {url})
      return true
    },
  }),
]

const view = new EditorView({parent: editorElement, state: EditorState.create({extensions})})

function openNote(id, text, keepSwitcher) {
  if (currentId !== null) states.set(currentId, view.state)
  const saved = states.get(id)
  view.setState(saved && saved.doc.toString() === text ? saved : EditorState.create({doc: text, extensions}))
  view.dispatch({effects: settings.reconfigure(settingsExtensions())})
  currentId = id
  if (!keepSwitcher) closeSwitcher()
  updateCount()
}

const defaultFont = `"SF Mono", ui-monospace, Menlo, monospace`

function applyOptions({fontFamily, fontSize, uiFontSize, showWhitespace: show, indentSize: indent}) {
  const family = String(fontFamily ?? "").replace(/["\\;{}]/g, "").trim()
  const root = document.documentElement.style
  root.setProperty("--font", family ? `"${family}", ${defaultFont}` : defaultFont)
  root.setProperty("--size", `${Number(fontSize) || 14}px`)
  root.setProperty("--ui-size", `${Number(uiFontSize) || 15}px`)
  showWhitespace = show === true
  indentSize = indent === 2 ? 2 : 4
  view.dispatch({effects: settings.reconfigure(settingsExtensions())})
  view.requestMeasure()
}

// ---- Footer

// The footer lies over the note's last lines. Its height and the boxes of its texts, with room for
// the note to fade out, go to style.css, which hides the note only behind those texts.
const room = 12
const footerObserver = new ResizeObserver(() => {
  footerHeight = footer.offsetHeight
  const {style} = editorElement
  style.setProperty("--footer-height", `${footerHeight}px`)
  const status = statusElement.offsetWidth && statusElement.offsetLeft + statusElement.offsetWidth + room
  style.setProperty("--status-width", `${status}px`)
  style.setProperty("--count-width", `${footer.clientWidth - countElement.offsetLeft + room}px`)
})
for (const element of [footer, statusElement, countElement]) footerObserver.observe(element)

let countTimer = 0
function scheduleCount() {
  clearTimeout(countTimer)
  countTimer = setTimeout(updateCount, 150)
}

function updateCount() {
  const count = countCharacters(view.state.doc.toString())
  countElement.textContent = `${count.toLocaleString("en-US")} ${count === 1 ? "character" : "characters"}`
}

// ---- Switcher

let notes = []
let shown = []
let selected = 0
// A note chosen for a match in its text, and the text to select once it opens.
let jump = null

const isSwitcherOpen = () => !switcher.hidden
// Swift sends the pinned notes first, in the user's order. Searching sorts by match, so pinned
// notes are moved only in the full list.
const pinnedCount = () => notes.filter(note => note.pinned).length
const canMove = note => note.pinned && !query.value.trim()
const savePinOrder = () => post("orderPins", {ids: notes.filter(note => note.pinned).map(note => note.id)})

function movePinned(from, to, save = true) {
  if (from < 0 || from === to || to < 0 || to >= pinnedCount()) return
  notes.splice(to, 0, ...notes.splice(from, 1))
  selected = to
  render()
  if (save) savePinOrder()
}

// Dragging a pinned note's handle moves it among the pinned notes; the order is saved on release.
function dragPinned(event, note) {
  event.preventDefault()
  event.stopPropagation()
  if (event.button !== 0) return
  document.body.classList.add("dragging")
  const move = ({clientY}) => {
    const rows = [...results.children].slice(0, pinnedCount())
    const over = rows.findIndex(row => clientY < row.getBoundingClientRect().bottom)
    // The rows show copies of the notes, so the note is found by its id.
    movePinned(notes.findIndex(({id}) => id === note.id), over < 0 ? rows.length - 1 : over, false)
  }
  const drop = () => {
    removeEventListener("mousemove", move)
    removeEventListener("mouseup", drop)
    document.body.classList.remove("dragging")
    savePinOrder()
  }
  addEventListener("mousemove", move)
  addEventListener("mouseup", drop)
}

function openSwitcher(list) {
  notes = list
  selected = 0
  query.value = ""
  switcher.hidden = false
  render()
  query.focus()
}

function closeSwitcher() {
  if (!isSwitcherOpen()) return
  switcher.hidden = true
  view.focus()
}

function choose(note) {
  jump = note.snippet ? {id: note.id, text: query.value.trim()} : null
  post("select", {id: note.id})
}

function selectMatch(text) {
  const at = view.state.doc.toString().toLowerCase().indexOf(text.toLowerCase())
  if (at < 0) return
  view.dispatch({
    selection: {anchor: at, head: at + text.length},
    effects: EditorView.scrollIntoView(at, {y: "center"}),
  })
}

function render() {
  shown = rankNotes(notes, query.value)
  selected = Math.max(0, Math.min(selected, shown.length - 1))
  results.replaceChildren(...shown.map(row))
  const active = results.children[selected]
  if (active) query.setAttribute("aria-activedescendant", active.id)
  else query.removeAttribute("aria-activedescendant")
  active?.scrollIntoView({block: "nearest"})
}

function element(tag, className, text) {
  const node = document.createElement(tag)
  node.className = className
  node.textContent = text
  return node
}

// Line icons drawn with the text color; a pinned note's pin is filled.
const icons = {
  grip: '<path d="M5 7h14M5 12h14M5 17h14"/>',
  pin: '<path d="M9 3.5h6M10 3.5v5.2l-3.2 3.1c-.4.4-.1 1.2.5 1.2h9.4c.6 0 .9-.8.5-1.2L14 8.7V3.5Z"/><path d="M12 13v8"/>',
  copy: '<rect x="8.5" y="8.5" width="11" height="11" rx="2"/><path d="M15.5 8.5v-2a2 2 0 0 0-2-2h-7a2 2 0 0 0-2 2v7a2 2 0 0 0 2 2h2"/>',
  open: '<path d="M14 4.5h5.5V10M19.5 4.5 11 13M17.5 13.5v4a2 2 0 0 1-2 2h-9a2 2 0 0 1-2-2v-9a2 2 0 0 1 2-2h4"/>',
  check: '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
  trash: '<path d="M4.5 6.5h15M9.5 6.5V5.3c0-1 .8-1.8 1.8-1.8h1.4c1 0 1.8.8 1.8 1.8v1.2M6.5 6.5l.9 12.2a2 2 0 0 0 2 1.8h5.2a2 2 0 0 0 2-1.8l.9-12.2M10.2 10v6.5M13.8 10v6.5"/>',
}

const iconSVG = name => `<svg viewBox="0 0 24 24" aria-hidden="true">${icons[name]}</svg>`

function actionButton(name, label, onClick, pressed) {
  const button = document.createElement("button")
  button.className = `action ${name}`
  button.title = label
  button.setAttribute("aria-label", label)
  if (pressed !== undefined) button.setAttribute("aria-pressed", String(pressed))
  button.innerHTML = iconSVG(name)
  // Pressing a button must not take focus from the search field or open the row.
  button.addEventListener("mousedown", event => {
    event.preventDefault()
    event.stopPropagation()
  })
  button.addEventListener("click", event => {
    event.stopPropagation()
    onClick()
  })
  return button
}

// Every row shows its buttons all the time, so rows keep one height as the pointer moves.
function row(note, index) {
  const item = document.createElement("li")
  item.id = `note-${index}`
  item.setAttribute("role", "option")
  item.setAttribute("aria-selected", String(index === selected))
  item.classList.toggle("movable", canMove(note))
  // Mouse only: ⌥↑ and ⌥↓ do the same from the keyboard.
  const grip = element("span", "grip", "")
  grip.title = "Drag to reorder (⌥↑ ⌥↓)"
  grip.setAttribute("aria-hidden", "true")
  grip.innerHTML = `<svg viewBox="0 0 24 24">${icons.grip}</svg>`
  grip.addEventListener("mousedown", event => dragPinned(event, note))
  const actions = element("span", "actions", "")
  // ⌘1 to ⌘9 open the first nine pinned notes, which Swift lists first.
  const number = note.pinned ? notes.findIndex(({id}) => id === note.id) + 1 : 0
  actions.append(
    element("span", "key", number >= 1 && number <= 9 ? `⌘${number}` : ""),
    actionButton("pin", note.pinned ? "Unpin" : "Pin", () => post("pin", {id: note.id}), Boolean(note.pinned)),
    actionButton("trash", "Move to Trash (⌘⌫)", () => post("trash", {id: note.id})),
  )
  item.append(grip, element("span", "title", note.title), actions)
  if (note.snippet) item.append(element("div", "snippet", note.snippet))
  item.addEventListener("mousedown", event => {
    event.preventDefault()
    choose(note)
  })
  return item
}

query.addEventListener("input", () => {
  selected = 0
  render()
})

query.addEventListener("keydown", event => {
  // Keys that confirm or cancel an input method's composition belong to it.
  if (event.isComposing || event.keyCode === 229) return
  const note = shown[selected]
  const command = event.metaKey && !event.ctrlKey && !event.altKey
  let handled = true
  if (event.altKey && !event.metaKey && !event.ctrlKey && /^Arrow(Up|Down)$/.test(event.key)) {
    if (note && canMove(note)) movePinned(selected, selected + (event.key === "ArrowUp" ? -1 : 1))
  } else if (event.key === "ArrowDown") {
    selected = Math.min(selected + 1, shown.length - 1)
    render()
  } else if (event.key === "ArrowUp") {
    selected = Math.max(selected - 1, 0)
    render()
  } else if (event.key === "Enter") {
    if (note) choose(note)
  } else if (event.key === "Escape") {
    closeSwitcher()
  } else if (command && event.key === "Backspace") {
    if (note) post("trash", {id: note.id})
  } else if (command && event.key.toLowerCase() === "a") {
    query.select()
  } else {
    handled = false
  }
  if (handled) event.preventDefault()
})

// ---- Messages from Swift

window.receive = ({type, data}) => {
  switch (type) {
    case "open":
      openNote(data.id, data.text, data.keep)
      if (jump?.id === data.id) selectMatch(jump.text)
      jump = null
      break
    case "renamed": {
      const state = states.get(data.from)
      if (state) {
        states.delete(data.from)
        states.set(data.to, state)
      }
      if (currentId === data.from) currentId = data.to
      break
    }
    case "trashed":
      states.delete(data)
      if (currentId === data) currentId = null
      break
    case "switcher":
      if (data.force || !isSwitcherOpen()) openSwitcher(data.notes)
      else closeSwitcher()
      break
    case "notes":
      if (isSwitcherOpen()) {
        notes = data
        render()
      }
      break
    case "focus":
      if (isSwitcherOpen()) query.focus()
      else view.focus()
      break
    case "options":
      applyOptions(data)
      break
    case "status":
      statusElement.textContent = data
      break
  }
}

applyOptions({})
updateCount()
post("ready")
