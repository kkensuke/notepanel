// The note's page: CodeMirror 6 for the note, with the marks of the switcher's search in it and
// the character count in the footer.
import {EditorState, EditorSelection, Compartment, RangeSetBuilder, StateField, StateEffect} from "@codemirror/state"
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
import {highlightSelectionMatches, selectNextOccurrence, selectSelectionMatches} from "@codemirror/search"
import {markdown, markdownLanguage} from "@codemirror/lang-markdown"
import {syntaxHighlighting, HighlightStyle, indentUnit, syntaxTree} from "@codemirror/language"
import {tags} from "@lezer/highlight"
import {
  fold,
  searchTerms,
  rankNotes,
  urlAt,
  linkAt,
  hangIndent,
  textStart,
  insertLineAbove,
  toggleMark,
  insertLink,
  toggleTask,
  countCharacters,
} from "./logic.js"
import {post, $, iconSVG, actionButton} from "./dom.js"
import {footerHeight, countElement} from "./footer.js"

const editorElement = $("editor")

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
})

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

// A list item's or quote's wrapped rows start under its text, not under its markers. The 12px is
// the line's own padding.
function markerIndents(view) {
  const builder = new RangeSetBuilder()
  for (const {from, to} of view.visibleRanges) {
    for (let pos = from; pos <= to; ) {
      const line = view.state.doc.lineAt(pos)
      const n = hangIndent(view.state, line)
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
    decorations: markerIndents(view),
    update(update) {
      // The parser tells which lines are in a ``` block, and it may finish after the change.
      if (update.docChanged || update.viewportChanged || syntaxTree(update.state) !== syntaxTree(update.startState))
        this.decorations = markerIndents(update.view)
    },
  }),
  {decorations: plugin => plugin.decorations},
)

// From Settings. Each note keeps its own state, so these are applied again when a note opens.
const settings = new Compartment()

// A search's matches in the note in sight, with the one the list last went to as the current
// one. They go when the note is written in, when a note opens, and when the switcher closes.
const setMarks = StateEffect.define()
const marks = StateField.define({
  create: () => Decoration.none,
  update(value, transaction) {
    for (const effect of transaction.effects) if (effect.is(setMarks)) return effect.value
    return transaction.docChanged ? Decoration.none : value
  },
  provide: field => EditorView.decorations.from(field),
})
const matchMark = Decoration.mark({class: "cm-searchMatch"})
const shownMatchMark = Decoration.mark({class: "cm-searchMatch cm-searchMatch-selected"})

function markSet(matches, shown) {
  const builder = new RangeSetBuilder()
  for (const match of matches) builder.add(match.from, match.to, match === shown ? shownMatchMark : matchMark)
  return builder.finish()
}
let showWhitespace = false
let indentSize = 4
const settingsExtensions = () => [
  // The spaces Tab adds; ⇧Tab takes as many away.
  indentUnit.of(" ".repeat(indentSize)),
  showWhitespace ? [highlightWhitespace(), ideographicSpaceBoxes] : [],
]

let currentId = null
// Which showing of a note this is, by Swift's count. It goes back with the text typed, so that
// Swift can tell text typed in a note it has since left from the open note's.
let opening = 0
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

// Where ⌘← takes a cursor: the start of its wrapped row, then where its line's text starts (after
// list and quote markers too, not only indentation), then the start of the line, and from there
// back to the text.
function home(view, range) {
  const line = view.state.doc.lineAt(range.head)
  const row = view.moveToLineBoundary(range, false)
  if (row.head > line.from && row.head < range.head) return row
  const text = line.from + textStart(view.state, line)
  return EditorSelection.cursor(range.head === text ? line.from : text)
}
const moveHome = extend => view => {
  const selection = EditorSelection.create(
    view.state.selection.ranges.map(range => {
      const to = home(view, range)
      return extend ? EditorSelection.range(range.anchor, to.head, undefined, undefined, to.assoc) : to
    }),
    view.state.selection.mainIndex,
  )
  if (selection.eq(view.state.selection)) return false
  view.dispatch({selection, scrollIntoView: true, userEvent: "select"})
  return true
}

// ⌘⌫: deletes back to where ⌘← goes, so an item's text goes before its marker. At the start of a
// line it deletes the line break, so holding it crosses empty lines.
function deleteHome(view) {
  const {state} = view
  let userEvent = "delete.selection"
  const spec = state.changeByRange(range => {
    if (!range.empty)
      return {range: EditorSelection.cursor(range.from), changes: {from: range.from, to: range.to}}
    userEvent = "delete.backward"
    let from = home(view, range).head
    // In the markers ⌘← goes forward, to the text; this deletes to the line's start instead.
    if (from > range.head) from = state.doc.lineAt(range.head).from
    if (from === range.head) from = Math.max(0, from - 1)
    return {range: EditorSelection.cursor(from), changes: {from, to: range.head}}
  })
  if (spec.changes.empty) return false
  view.dispatch(state.update(spec, {scrollIntoView: true, userEvent}))
  return true
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
  marks,
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
    // Ahead of the defaults, which skip only indentation.
    {mac: "Cmd-ArrowLeft", run: moveHome(false), shift: moveHome(true), preventDefault: true},
    {key: "Home", run: moveHome(false), shift: moveHome(true), preventDefault: true},
    {mac: "Cmd-Backspace", run: deleteHome},
    ...defaultKeymap,
    ...historyKeymap,
    // Finding is the switcher's, which ⌘F opens; these two are the rest of the search keys.
    {key: "Mod-d", run: selectNextOccurrence, preventDefault: true},
    {key: "Mod-Shift-l", run: selectSelectionMatches},
    indentWithTab,
    // Last, so it only runs when nothing above wanted Escape. Swift closes the switcher first,
    // if it's up beside the note, and else hides the panel.
    {key: "Escape", run: () => (post("escape"), true)},
  ]),
  EditorView.updateListener.of(update => {
    if (update.docChanged && currentId !== null) {
      // shortcut: sends the whole text on every change; fine for notes, revisit past ~1 MB.
      post("changed", {opening, text: update.state.doc.toString()})
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

export const view = new EditorView({parent: editorElement, state: EditorState.create({extensions})})

// `showing` is Swift's count of the notes it has shown, which goes back with the text typed.
export function openNote(id, text, showing) {
  opening = showing
  if (currentId !== null) states.set(currentId, view.state)
  const saved = states.get(id)
  view.setState(saved && saved.doc.toString() === text ? saved : EditorState.create({doc: text, extensions}))
  view.dispatch({effects: [settings.reconfigure(settingsExtensions()), setMarks.of(Decoration.none)]})
  currentId = id
}

// A note's state goes with it to its new name.
export function renameNote(from, to) {
  const state = states.get(from)
  if (state) {
    states.delete(from)
    states.set(to, state)
  }
  if (currentId === from) currentId = to
}

export function forgetNote(id) {
  states.delete(id)
  if (currentId === id) currentId = null
}

// The selection a search last put in the note, which isn't the user's own.
let landed = null

// Once a note the switcher asked for is open, the cursor goes on the match its row is for, in the
// middle of the note, and the search's matches are marked.
export function land({query, place}) {
  const term = place ? searchTerms(query)[place.term] : ""
  let {from = -1, to = -1} = place ?? {}
  // A match's place is from the text the list had. If the file has changed since, the first
  // match will do.
  if (to > from && fold(view.state.sliceDoc(from, to)) !== term) {
    from = fold(view.state.doc.toString()).indexOf(term)
    to = from + term.length
  }
  const selection = from < 0 || to > view.state.doc.length ? undefined : {anchor: from, head: to}
  view.dispatch({selection, effects: selection ? EditorView.scrollIntoView(from, {y: "center"}) : []})
  if (selection) landed = view.state.selection
  markMatches(query, selection && {from, to})
}

// Marks what the switcher's search finds in the note, so the switcher is the find for one note
// too. `current` is the match the list went to, marked as the current one. The note's own text
// is searched, so the marks are right even if the file has changed since the list was made.
export function markMatches(query, current) {
  const [note] = rankNotes([{id: currentId, title: currentId ?? "", text: view.state.doc.toString()}], query)
  const matches = note?.matches ?? []
  const shown = matches.find(match => match.from === current?.from && match.to === current?.to)
  view.dispatch({effects: setMarks.of(markSet(matches, shown))})
}

// What ⌘F searches for, which Swift asks for: some of a line selected in the note, as if typed
// and Return pressed. What the search itself left selected isn't asked for.
window.findText = () => {
  const {from, to} = view.state.selection.main
  const text = view.hasFocus && view.state.selection !== landed ? view.state.sliceDoc(from, to) : ""
  return text.trim() && !text.includes("\n") ? text : ""
}

const defaultFont = `"SF Mono", ui-monospace, Menlo, monospace`

export function applyOptions({fontFamily, fontSize, uiFontSize, showWhitespace: show, indentSize: indent}) {
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

// ---- Character count

let countTimer = 0
function scheduleCount() {
  clearTimeout(countTimer)
  countTimer = setTimeout(updateCount, 150)
}

export function updateCount() {
  const count = countCharacters(view.state.doc.toString())
  countElement.textContent = `${count.toLocaleString("en-US")} ${count === 1 ? "character" : "characters"}`
}
