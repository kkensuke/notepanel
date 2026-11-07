// The editor page: CodeMirror 6 for the note, and the note switcher on top of it.
// Swift calls `receive(message)`; the page answers with `post(type, data)`.
import {EditorState} from "@codemirror/state"
import {
  EditorView,
  keymap,
  drawSelection,
  dropCursor,
  highlightSpecialChars,
  rectangularSelection,
} from "@codemirror/view"
import {defaultKeymap, historyKeymap, history, indentWithTab, selectLine} from "@codemirror/commands"
import {searchKeymap, highlightSelectionMatches} from "@codemirror/search"
import {markdown, markdownLanguage} from "@codemirror/lang-markdown"
import {syntaxHighlighting, HighlightStyle} from "@codemirror/language"
import {tags} from "@lezer/highlight"
import {rankNotes, urlAt, insertLineAbove, countCharacters, formatModified} from "./logic.js"

// Outside the app (in a plain browser) there is no handler, so nothing is sent.
const post = (type, data = {}) => window.webkit?.messageHandlers?.native?.postMessage({type, ...data})

const $ = id => document.getElementById(id)
const editorElement = $("editor")
const footer = $("footer")
const statusElement = $("status")
const countElement = $("count")
const switcher = $("switcher")
const switcherBox = switcher.firstElementChild
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
  {tag: [tags.link, tags.url], color: "var(--link)"},
  {tag: [tags.processingInstruction, tags.quote, tags.contentSeparator], color: "var(--muted)"},
])

const theme = EditorView.theme({
  "&": {height: "100%", fontSize: "var(--size)", color: "var(--fg)", backgroundColor: "transparent"},
  "&.cm-focused": {outline: "none"},
  ".cm-scroller": {fontFamily: "var(--font)", lineHeight: "1.6"},
  ".cm-content": {padding: "6px 0", caretColor: "var(--fg)"},
  ".cm-line": {padding: "0 12px"},
  ".cm-cursor, .cm-dropCursor": {borderLeftColor: "var(--fg)"},
  "&.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground, .cm-selectionBackground":
    {backgroundColor: "var(--selection)"},
  ".cm-selectionMatch": {backgroundColor: "var(--match)"},
  ".cm-searchMatch": {backgroundColor: "var(--search)"},
  ".cm-searchMatch.cm-searchMatch-selected": {backgroundColor: "var(--search-current)"},
  ".cm-panels": {backgroundColor: "var(--panel)", color: "var(--fg)", fontSize: "calc(12px * var(--ui-scale))"},
  ".cm-panels.cm-panels-top": {borderBottom: "1px solid var(--border)"},
  ".cm-panels.cm-panels-bottom": {borderTop: "1px solid var(--border)"},
  ".cm-textfield, .cm-button": {
    backgroundColor: "var(--bg)",
    backgroundImage: "none",
    color: "var(--fg)",
    border: "1px solid var(--border)",
    borderRadius: "4px",
  },
})

// ---- Editor

let currentId = null
// Each note's state, so its undo history and cursor survive switching notes.
const states = new Map()

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
  markdown({base: markdownLanguage}),
  syntaxHighlighting(highlight),
  theme,
  keymap.of([
    {key: "Mod-l", run: selectLine, preventDefault: true},
    {key: "Mod-Shift-Enter", run: view => (view.dispatch(insertLineAbove(view.state)), true)},
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
    if (update.docChanged || update.geometryChanged) reportHeight()
  }),
  EditorView.domEventHandlers({
    mousedown(event, view) {
      if (!event.metaKey || event.altKey || event.shiftKey || event.button !== 0) return false
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
  currentId = id
  if (!keepSwitcher) closeSwitcher()
  updateCount()
  reportHeight()
}

const defaultFont = `"SF Mono", ui-monospace, Menlo, monospace`

function applyOptions({fontFamily, fontSize, uiScale}) {
  const family = String(fontFamily ?? "").replace(/["\\;{}]/g, "").trim()
  const root = document.documentElement.style
  root.setProperty("--font", family ? `"${family}", ${defaultFont}` : defaultFont)
  root.setProperty("--size", `${Number(fontSize) || 14}px`)
  root.setProperty("--ui-scale", String(Number(uiScale) || 1.5))
  view.requestMeasure()
  reportHeight()
}

// ---- Footer

let countTimer = 0
function scheduleCount() {
  clearTimeout(countTimer)
  countTimer = setTimeout(updateCount, 150)
}

function updateCount() {
  const count = countCharacters(view.state.doc.toString())
  countElement.textContent = `${count.toLocaleString("en-US")} ${count === 1 ? "character" : "characters"}`
}

// ---- Window height

let lastHeight = 0
let heightQueued = false

// The height the page wants: the note, any search panel and the footer, or the switcher.
function reportHeight() {
  if (heightQueued) return
  heightQueued = true
  requestAnimationFrame(() => {
    heightQueued = false
    let panels = 0
    for (const panel of view.dom.querySelectorAll(".cm-panels")) panels += panel.offsetHeight
    let height = view.contentHeight + panels + footer.offsetHeight
    if (isSwitcherOpen()) height = Math.max(height, switcherBox.offsetHeight)
    height = Math.ceil(height)
    if (height !== lastHeight) {
      lastHeight = height
      post("height", {height})
    }
  })
}

// ---- Switcher

let notes = []
let shown = []
let selected = 0
let renaming = null

const isSwitcherOpen = () => !switcher.hidden

function openSwitcher(list) {
  notes = list
  selected = 0
  renaming = null
  query.value = ""
  switcher.hidden = false
  render()
  query.focus()
}

function closeSwitcher() {
  if (!isSwitcherOpen()) return
  switcher.hidden = true
  renaming = null
  view.focus()
  reportHeight()
}

function render() {
  shown = rankNotes(notes, query.value)
  selected = Math.max(0, Math.min(selected, shown.length - 1))
  results.replaceChildren(...shown.map(row))
  const active = results.children[selected]
  if (active) query.setAttribute("aria-activedescendant", active.id)
  else query.removeAttribute("aria-activedescendant")
  active?.scrollIntoView({block: "nearest"})
  reportHeight()
}

function element(tag, className, text) {
  const node = document.createElement(tag)
  node.className = className
  node.textContent = text
  return node
}

// Feather-style icons, drawn with the text color.
const icons = {
  rename: '<path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4Z"/>',
  trash: '<path d="M3 6h18"/><path d="M8 6V4h8v2"/><path d="M19 6l-1 14H6L5 6"/><path d="M10 11v6M14 11v6"/>',
}

function actionButton(name, label, onClick) {
  const button = document.createElement("button")
  button.className = `action ${name}`
  button.title = label
  button.setAttribute("aria-label", label)
  button.innerHTML = `<svg viewBox="0 0 24 24" aria-hidden="true">${icons[name]}</svg>`
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

function startRename(id) {
  renaming = id
  render()
}

function row(note, index) {
  const item = document.createElement("li")
  item.id = `note-${index}`
  item.setAttribute("role", "option")
  item.setAttribute("aria-selected", String(index === selected))
  if (note.id === renaming) {
    item.append(renameField(note))
    return item
  }
  const actions = element("span", "actions", "")
  actions.append(
    actionButton("rename", "Rename (⌘R)", () => startRename(note.id)),
    actionButton("trash", "Move to Trash (⌘⌫)", () => post("trash", {id: note.id})),
  )
  item.append(element("span", "title", note.title), element("span", "meta", formatModified(note.modified)), actions)
  if (note.snippet) item.append(element("div", "snippet", note.snippet))
  item.addEventListener("mousedown", event => {
    event.preventDefault()
    post("select", {id: note.id})
  })
  return item
}

function renameField(note) {
  const input = document.createElement("input")
  input.className = "rename"
  input.value = note.id
  input.spellcheck = false
  input.setAttribute("aria-label", "New name")
  input.addEventListener("keydown", event => {
    if (event.isComposing) return
    if (event.key === "Enter") {
      event.preventDefault()
      renaming = null
      post("rename", {from: note.id, to: input.value})
      query.focus()
    } else if (event.key === "Escape") {
      event.preventDefault()
      renaming = null
      render()
      query.focus()
    }
  })
  input.addEventListener("blur", () => {
    if (renaming !== note.id) return
    renaming = null
    render()
  })
  requestAnimationFrame(() => {
    input.focus()
    input.select()
  })
  return input
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
  if (event.key === "ArrowDown") {
    selected = Math.min(selected + 1, shown.length - 1)
    render()
  } else if (event.key === "ArrowUp") {
    selected = Math.max(selected - 1, 0)
    render()
  } else if (event.key === "Enter") {
    if (note) post("select", {id: note.id})
  } else if (event.key === "Escape") {
    closeSwitcher()
  } else if (command && event.key === "Backspace") {
    if (note) post("trash", {id: note.id})
  } else if (command && event.key.toLowerCase() === "r") {
    if (note) startRename(note.id)
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
      reportHeight()
      break
  }
}

applyOptions({})
updateCount()
post("ready")
