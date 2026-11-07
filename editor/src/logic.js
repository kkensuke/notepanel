// Pure helpers, kept apart from the DOM so they can run under `node --test`.
import {EditorSelection} from "@codemirror/state"

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

// The URL under `offset` in a line: a Markdown link's target, or a bare URL.
export function urlAt(line, offset) {
  for (const m of line.matchAll(/\[[^\]]*\]\(([^)\s]+)[^)]*\)/g)) {
    if (offset >= m.index && offset <= m.index + m[0].length) return m[1]
  }
  for (const m of line.matchAll(/(?:https?:\/\/|mailto:)[^\s<>()[\]]+/g)) {
    if (offset >= m.index && offset <= m.index + m[0].length) return m[0].replace(/[.,;:!?]+$/, "")
  }
  return null
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

// Characters as people count them (grapheme clusters), without line breaks.
const segmenter = new Intl.Segmenter()
export function countCharacters(text) {
  let count = 0
  for (const _ of segmenter.segment(text.replace(/\r?\n/g, ""))) count++
  return count
}

// "15:30" today, "Nov 7" this year, "Nov 7, 2025" before.
export function formatModified(ms, now = new Date()) {
  const date = new Date(ms)
  if (date.toDateString() === now.toDateString()) {
    return date.toLocaleTimeString("en-US", {hour: "2-digit", minute: "2-digit", hour12: false})
  }
  const options = {month: "short", day: "numeric"}
  if (date.getFullYear() !== now.getFullYear()) options.year = "numeric"
  return date.toLocaleDateString("en-US", options)
}
