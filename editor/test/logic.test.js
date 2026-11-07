import {test} from "node:test"
import assert from "node:assert/strict"
import {EditorState, EditorSelection} from "@codemirror/state"
import {fuzzyScore, rankNotes, urlAt, insertLineAbove, countCharacters, formatModified} from "../src/logic.js"

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

test("insertLineAbove keeps indentation and moves the cursor up", () => {
  const state = EditorState.create({
    doc: "a\n  b",
    selection: EditorSelection.cursor(4),
  })
  const next = insertLineAbove(state).state
  assert.equal(next.doc.toString(), "a\n  \n  b")
  assert.equal(next.selection.main.head, 4)
})

test("countCharacters counts graphemes and skips line breaks", () => {
  assert.equal(countCharacters("ab\ncd"), 4)
  assert.equal(countCharacters("あいう"), 3)
  assert.equal(countCharacters("\u{1F468}‍\u{1F469}‍\u{1F467}"), 1)
  assert.equal(countCharacters(""), 0)
})

test("formatModified shows the time today and the date otherwise", () => {
  const now = new Date(2026, 10, 7, 18, 0)
  assert.equal(formatModified(new Date(2026, 10, 7, 9, 5).getTime(), now), "09:05")
  assert.equal(formatModified(new Date(2026, 0, 2).getTime(), now), "Jan 2")
  assert.equal(formatModified(new Date(2025, 0, 2).getTime(), now), "Jan 2, 2025")
})
