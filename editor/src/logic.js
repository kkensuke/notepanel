// Pure helpers, kept apart from the DOM so they can run under `node --test`.
import {EditorSelection, countColumn} from "@codemirror/state"
import {syntaxTree} from "@codemirror/language"

// A case-insensitive subsequence match: every query character must appear in order.
// Returns a score (higher is better) or null. Runs and word starts score more,
// and shorter targets win ties.
export function fuzzyScore(query, target) {
  const q = query.toLowerCase()
  const t = target.toLowerCase()
  let score = 0
  let from = 0
  let previousEnd = -1
  for (const ch of q) {
    const i = t.indexOf(ch, from)
    if (i < 0) return null
    if (i === previousEnd) score += 5
    else if (i === 0 || /[\s\-_./]/.test(t[i - 1])) score += 3
    else score += 1
    previousEnd = i + ch.length
    from = previousEnd
  }
  return score - t.length * 0.01
}

// Titles match fuzzily and rank first; bodies match as a plain substring, with the matching
// line as a snippet. With no query, notes keep their order (newest first).
export function rankNotes(notes, query, limit = 200) {
  const q = query.trim()
  if (!q) return notes.slice(0, limit).map(note => ({...note, snippet: ""}))
  const lower = q.toLowerCase()
  const ranked = []
  for (const note of notes) {
    const score = fuzzyScore(q, note.title) ?? (note.title === note.id ? null : fuzzyScore(q, note.id))
    if (score !== null) {
      ranked.push({...note, score: 1000 + score, snippet: ""})
      continue
    }
    const at = note.text.toLowerCase().indexOf(lower)
    if (at >= 0) ranked.push({...note, score: 0, snippet: snippetAt(note.text, at)})
  }
  ranked.sort((a, b) => b.score - a.score || b.modified - a.modified)
  return ranked.slice(0, limit)
}

function snippetAt(text, at) {
  const lineStart = text.lastIndexOf("\n", at) + 1
  let lineEnd = text.indexOf("\n", at)
  if (lineEnd < 0) lineEnd = text.length
  const start = Math.max(lineStart, at - 40)
  return (start > lineStart ? "…" : "") + text.slice(start, lineEnd).trim().slice(0, 120)
}

// The link under `offset` in a line: a Markdown link, or a bare URL. `from` and `to` span the
// link as written, and `urlFrom` is where its URL starts.
export function linkAt(line, offset) {
  for (const m of line.matchAll(/\[[^\]]*\]\(([^)\s]+)[^)]*\)/g)) {
    const to = m.index + m[0].length
    if (offset >= m.index && offset <= to)
      return {url: m[1], from: m.index, to, urlFrom: m.index + m[0].indexOf("](") + 2}
  }
  for (const m of line.matchAll(/(?:https?:\/\/|mailto:)[^\s<>()[\]]+/g)) {
    const to = m.index + m[0].length
    if (offset >= m.index && offset <= to)
      return {url: m[0].replace(/[.,;:!?]+$/, ""), from: m.index, to, urlFrom: m.index}
  }
  return null
}

// The URL under `offset` in a line: a Markdown link's target, or a bare URL.
export function urlAt(line, offset) {
  return linkAt(line, offset)?.url ?? null
}

// The columns before a list item's text ("- ", "  1. ", "- [ ] "), or 0 if the line isn't one.
export function listIndent(line, tabSize) {
  const marker = /^\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?/.exec(line)
  return marker ? countColumn(marker[0], tabSize) : 0
}

// VS Code's Shift-Cmd-Enter: a new line above each cursor, with the same indentation.
export function insertLineAbove(state) {
  return state.update(
    state.changeByRange(range => {
      const line = state.doc.lineAt(range.head)
      const indent = /^[ \t]*/.exec(line.text)[0]
      return {
        changes: {from: line.from, insert: indent + "\n"},
        range: EditorSelection.cursor(line.from + indent.length),
      }
    }),
    {scrollIntoView: true, userEvent: "input"},
  )
}

// A selection without the spaces and line breaks at its ends (⌘L selects the line break too),
// since Markdown doesn't read `** b **` as bold.
function trimmed(state, range) {
  const text = state.sliceDoc(range.from, range.to)
  const from = range.to - text.trimStart().length
  return {from, to: Math.max(from, range.from + text.trimEnd().length)}
}

// ⌘B and the like: wraps each selection in `mark` ("**", "*", "~~" or "`"), or takes the mark
// away where it's already just outside the selection or at its ends. A cursor gets an empty pair
// to type in, or loses the empty pair it's in.
// shortcut: a selection over several lines gets one pair, which Markdown ignores across a blank
// line or list items; wrap each line if that comes up.
export function toggleMark(state, mark) {
  const size = mark.length
  const leading = new RegExp(`^\\${mark[0]}*`)
  const trailing = new RegExp(`\\${mark[0]}*$`)
  // One * is italic and two are bold, so *** is both and ** isn't italic.
  const has = run => (mark === "*" ? run % 2 === 1 : run >= size)
  return state.update(
    state.changeByRange(range => {
      const {from, to} = trimmed(state, range)
      const before = trailing.exec(state.sliceDoc(Math.max(0, from - 3), from))[0].length
      const after = leading.exec(state.sliceDoc(to, Math.min(state.doc.length, to + 3)))[0].length
      if (has(Math.min(before, after)))
        return {
          changes: [{from: from - size, to: from}, {from: to, to: to + size}],
          range: EditorSelection.range(from - size, to - size),
        }
      const text = state.sliceDoc(from, to)
      const start = leading.exec(text)[0].length
      const end = trailing.exec(text)[0].length
      if (start + end < text.length && has(Math.min(start, end)))
        return {
          changes: [{from, to: from + size}, {from: to - size, to}],
          range: EditorSelection.range(from, to - 2 * size),
        }
      return {
        changes: [{from, insert: mark}, {from: to, insert: mark}],
        range: EditorSelection.range(from + size, to + size),
      }
    }),
    {scrollIntoView: true, userEvent: "input"},
  )
}

// ⌘K: makes each selection a link's text, with the cursor where the URL goes. A selected URL
// becomes the link's target instead, and a cursor an empty link; then the cursor goes where the
// text goes.
export function insertLink(state) {
  return state.update(
    state.changeByRange(range => {
      const {from, to} = trimmed(state, range)
      const text = state.sliceDoc(from, to)
      const isURL = /^(?:https?:\/\/|mailto:)\S+$/.test(text)
      return {
        changes: {from, to, insert: isURL ? `[](${text})` : `[${text}]()`},
        range: EditorSelection.cursor(from + (isURL || !text ? 1 : text.length + 3)),
      }
    }),
    {scrollIntoView: true, userEvent: "input"},
  )
}

// Ticks the task box ("[ ]" or "[x]") at `pos`, or clears it; null if there is no box there. The
// Markdown parser finds the boxes, so "- [ ]" in a code block isn't one.
export function toggleTask(state, pos) {
  const box = syntaxTree(state).resolveInner(pos, 1)
  if (box.name !== "TaskMarker") return null
  const ticked = state.sliceDoc(box.from + 1, box.from + 2) !== " "
  return state.update({
    changes: {from: box.from + 1, to: box.from + 2, insert: ticked ? " " : "x"},
    userEvent: "input",
  })
}

// Characters as people count them (grapheme clusters), without line breaks.
const segmenter = new Intl.Segmenter()
export function countCharacters(text) {
  let count = 0
  for (const _ of segmenter.segment(text.replace(/\r?\n/g, ""))) count++
  return count
}

// When a version was kept, as the history lists it: "Today 9:05", "Yesterday 23:40",
// "Nov 3, 14:20", and "Nov 3, 2025" in another year.
export function versionLabel(date, now = new Date()) {
  const time = `${date.getHours()}:${String(date.getMinutes()).padStart(2, "0")}`
  const midnight = d => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()
  // Rounded, since a day with a change of clocks is 23 or 25 hours long.
  const days = Math.round((midnight(now) - midnight(date)) / 86_400_000)
  if (days === 0) return `Today ${time}`
  if (days === 1) return `Yesterday ${time}`
  const day = {month: "short", day: "numeric"}
  if (date.getFullYear() !== now.getFullYear()) return date.toLocaleDateString("en-US", {...day, year: "numeric"})
  return `${date.toLocaleDateString("en-US", day)}, ${time}`
}
