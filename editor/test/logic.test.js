import {test} from "node:test"
import assert from "node:assert/strict"
import {EditorState, EditorSelection} from "@codemirror/state"
import {
  fuzzyScore,
  rankNotes,
  urlAt,
  linkAt,
  listIndent,
  insertLineAbove,
  toggleMark,
  insertLink,
  toggleTask,
  countCharacters,
  versionLabel,
} from "../src/logic.js"
import {markdown, markdownLanguage} from "@codemirror/lang-markdown"

// Runs an edit on `doc`, whose selection is written as "|" (a cursor) or a "|" at each end, and
// returns the result written the same way.
function edited(edit, doc) {
  const [from, to = from] = [...doc.matchAll(/\|/g)].map((m, i) => m.index - i)
  const state = EditorState.create({doc: doc.replaceAll("|", ""), selection: EditorSelection.range(from, to)})
  const next = edit(state).state
  const {from: a, to: b} = next.selection.main
  const text = next.doc.toString()
  return text.slice(0, a) + "|" + (a === b ? "" : text.slice(a, b) + "|") + text.slice(b)
}
const bold = state => toggleMark(state, "**")
const italic = state => toggleMark(state, "*")

test("fuzzyScore matches characters in order and prefers runs", () => {
  assert.equal(fuzzyScore("xyz", "meeting notes"), null)
  assert.ok(fuzzyScore("mtg", "meeting") !== null)
  assert.ok(fuzzyScore("meet", "meeting notes") > fuzzyScore("meet", "my estimate"))
  assert.ok(fuzzyScore("notes", "notes") > fuzzyScore("notes", "notes about many things"))
})

test("fuzzyScore handles text outside the BMP and non-Latin scripts", () => {
  // "あい" is two Japanese kana; "\u{1F600}" is an emoji made of two UTF-16 units.
  assert.ok(fuzzyScore("あい", "あxい") !== null)
  assert.ok(fuzzyScore("\u{1F600}a", "\u{1F600}abc") !== null)
})

test("rankNotes puts title matches first and adds snippets for body matches", () => {
  const notes = [
    {id: "Groceries", title: "Groceries", modified: 3, text: "milk\neggs"},
    {id: "Untitled", title: "Ideas", modified: 2, text: "buy a milk frother"},
    {id: "Milk tea", title: "Milk tea", modified: 1, text: ""},
  ]
  const ranked = rankNotes(notes, "milk")
  assert.deepEqual(ranked.map(n => n.id), ["Milk tea", "Groceries", "Untitled"])
  assert.equal(ranked[1].snippet, "milk")
  assert.equal(ranked[2].snippet, "buy a milk frother")
  assert.deepEqual(rankNotes(notes, " ").map(n => n.id), ["Groceries", "Untitled", "Milk tea"])
  assert.equal(rankNotes(notes, "", 2).length, 2)
})

test("urlAt finds Markdown link targets and bare URLs", () => {
  const line = "see [docs](https://example.com/a) or https://example.org/b."
  assert.equal(urlAt(line, 5), "https://example.com/a")
  assert.equal(urlAt(line, 45), "https://example.org/b")
  assert.equal(urlAt(line, 1), null)
  assert.equal(urlAt("mail mailto:me@example.com", 8), "mailto:me@example.com")
})

test("linkAt spans the whole link and says where its URL starts", () => {
  const line = "see [docs](https://example.com/a) or https://example.org/b."
  assert.deepEqual(linkAt(line, 5), {url: "https://example.com/a", from: 4, to: 33, urlFrom: 11})
  assert.deepEqual(linkAt(line, 45), {url: "https://example.org/b", from: 37, to: 59, urlFrom: 37})
  assert.equal(linkAt(line, 1), null)
})

test("listIndent measures a list item's marker, and is 0 for other lines", () => {
  assert.equal(listIndent("- item", 4), 2)
  assert.equal(listIndent("  * nested", 4), 4)
  assert.equal(listIndent("\t+ tabbed", 4), 6)
  assert.equal(listIndent("1. first", 4), 3)
  assert.equal(listIndent("10) tenth", 4), 4)
  assert.equal(listIndent("- [ ] task", 4), 6)
  assert.equal(listIndent("- [x] done", 4), 6)
  assert.equal(listIndent("Plain text - not a list", 4), 0)
  assert.equal(listIndent("*emphasis* only", 4), 0)
  assert.equal(listIndent("-no space", 4), 0)
  assert.equal(listIndent("", 4), 0)
})

test("insertLineAbove keeps indentation and moves the cursor up", () => {
  const state = EditorState.create({
    doc: "a\n  b",
    selection: EditorSelection.cursor(4),
  })
  const next = insertLineAbove(state).state
  assert.equal(next.doc.toString(), "a\n  \n  b")
  assert.equal(next.selection.main.head, 4)
})

test("toggleMark wraps a selection, and a second press takes the mark away", () => {
  assert.equal(edited(bold, "a |b| c"), "a **|b|** c")
  assert.equal(edited(bold, "a **|b|** c"), "a |b| c")
  assert.equal(edited(bold, "a |**b**| c"), "a |b| c")
  assert.equal(edited(state => toggleMark(state, "~~"), "これは|取り消し|です"), "これは~~|取り消し|~~です")
  assert.equal(edited(state => toggleMark(state, "`"), "`|code|`"), "|code|")
})

test("toggleMark leaves spaces and line breaks at the selection's ends outside", () => {
  assert.equal(edited(bold, "a| b |c"), "a **|b|** c")
  assert.equal(edited(bold, "|line\n|next"), "**|line|**\nnext")
})

test("toggleMark gives a cursor an empty pair, and takes it away again", () => {
  assert.equal(edited(bold, "a|"), "a**|**")
  assert.equal(edited(bold, "a**|**"), "a|")
  assert.equal(edited(italic, "a*|*"), "a|")
})

test("toggleMark tells italic from bold", () => {
  assert.equal(edited(italic, "**|b|**"), "***|b|***")
  assert.equal(edited(italic, "***|b|***"), "**|b|**")
  assert.equal(edited(italic, "|**b**|"), "*|**b**|*")
  assert.equal(edited(bold, "*|b|*"), "***|b|***")
  assert.equal(edited(bold, "***|b|***"), "*|b|*")
})

test("toggleMark changes every selection", () => {
  const state = EditorState.create({
    doc: "a b",
    selection: EditorSelection.create([EditorSelection.range(0, 1), EditorSelection.range(2, 3)]),
    extensions: EditorState.allowMultipleSelections.of(true),
  })
  assert.equal(bold(state).state.doc.toString(), "**a** **b**")
})

test("insertLink puts the cursor where the URL or the text goes", () => {
  assert.equal(edited(insertLink, "see |docs|"), "see [docs](|)")
  assert.equal(edited(insertLink, "see |https://example.com/a|"), "see [|](https://example.com/a)")
  assert.equal(edited(insertLink, "see |"), "see [|]()")
})

test("toggleTask ticks and clears a task's box, and only a task's", () => {
  const doc = "- [ ] a\n  1. [x] b\n> - [ ] c\n\n```\n- [ ] code\n```\n[ ] text"
  const state = EditorState.create({doc, extensions: markdown({base: markdownLanguage})})
  const at = text => doc.indexOf(text)
  assert.equal(toggleTask(state, at("[ ] a")).state.doc.line(1).text, "- [x] a")
  assert.equal(toggleTask(state, at("[x] b") + 2).state.doc.line(2).text, "  1. [ ] b")
  assert.equal(toggleTask(state, at("[ ] c")).state.doc.line(3).text, "> - [x] c")
  assert.equal(toggleTask(state, at("[ ] code")), null)
  assert.equal(toggleTask(state, at("[ ] text")), null)
})

test("countCharacters counts graphemes and skips line breaks", () => {
  assert.equal(countCharacters("ab\ncd"), 4)
  assert.equal(countCharacters("あいう"), 3)
  assert.equal(countCharacters("\u{1F468}‍\u{1F469}‍\u{1F467}"), 1)
  assert.equal(countCharacters(""), 0)
})

test("versionLabel says today, yesterday, the date, or the date and year", () => {
  const now = new Date(2026, 10, 14, 20, 30)
  assert.equal(versionLabel(new Date(2026, 10, 14, 9, 5), now), "Today 9:05")
  assert.equal(versionLabel(new Date(2026, 10, 13, 23, 40), now), "Yesterday 23:40")
  assert.equal(versionLabel(new Date(2026, 10, 3, 14, 20), now), "Nov 3, 14:20")
  assert.equal(versionLabel(new Date(2025, 10, 3, 14, 20), now), "Nov 3, 2025")
  // Yesterday comes before the year: just after New Year, last night is yesterday.
  assert.equal(versionLabel(new Date(2026, 11, 31, 23, 30), new Date(2027, 0, 1, 0, 10)), "Yesterday 23:30")
})
