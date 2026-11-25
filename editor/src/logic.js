// Pure helpers, kept apart from the DOM so they can run under `node --test`.
import {EditorSelection, countColumn} from "@codemirror/state"
import {syntaxTree} from "@codemirror/language"

// What a search doesn't tell apart: letter case, full-width letters, digits and signs ("ＡＰＩ" is
// "api"), and the full-width space a Japanese input method types. Each character stays one
// character, so a position in the folded text is the same position in the original.
export function fold(text) {
  return text
    .replace(/[！-～]/g, ch => String.fromCharCode(ch.charCodeAt(0) - 0xfee0))
    .replace(/　/g, " ")
    // The one letter whose lower case is two characters long.
    .replace(/İ/g, "i")
    .toLowerCase()
}

// The words of a search, folded. A note matches when it has every one of them.
export const searchTerms = query => fold(query).split(/\s+/).filter(Boolean)

const wordStart = (text, at) => at === 0 || /[\s\-_./]/.test(text[at - 1])

// Where `query` is in `target`: as a run if it has one (the first at a word start, else the
// first), else its characters one by one in order. Returns the score (higher is better) and the
// ranges matched, or null. Runs and word starts score more, and shorter targets win ties.
export function fuzzyMatch(query, target) {
  const q = fold(query)
  const t = fold(target)
  // Where the run starts; 0 with no run, to look for the characters from the start.
  let from = 0
  for (let at = t.indexOf(q); at >= 0; at = t.indexOf(q, at + 1)) {
    if (!from) from = at
    if (wordStart(t, at)) {
      from = at
      break
    }
  }
  let score = 0
  let end = -1
  const ranges = []
  for (const ch of q) {
    const at = t.indexOf(ch, from)
    if (at < 0) return null
    if (at === end) {
      score += 5
      ranges.at(-1)[1] = at + ch.length
    } else {
      score += wordStart(t, at) ? 3 : 1
      ranges.push([at, at + ch.length])
    }
    end = from = at + ch.length
  }
  return {score: score - t.length * 0.01, ranges}
}

// Ranges in order, with those that touch or overlap made one.
function mergeRanges(ranges) {
  const merged = []
  for (const [from, to] of ranges.sort((a, b) => a[0] - b[0])) {
    const last = merged.at(-1)
    if (last && from <= last[1]) last[1] = Math.max(last[1], to)
    else merged.push([from, to])
  }
  return merged
}

// Every place a term is in a note's folded text, in order, as {from, to, term}.
function textMatches(text, terms) {
  const matches = []
  terms.forEach((term, index) => {
    for (let at = text.indexOf(term); at >= 0; at = text.indexOf(term, at + term.length))
      matches.push({from: at, to: at + term.length, term: index})
  })
  return matches.sort((a, b) => a.from - b.from)
}

// Where the first line of a note's folded text ends, if that line is the note's name, markers
// apart; else 0. The name comes from such a line, so the line isn't listed under it again.
function nameLineEnd(text, title) {
  const first = /^\s*.*/.exec(text)[0]
  const line = first.trim()
  return line.slice(leadLength(line)).trim() === fold(title) ? first.length : 0
}

// The matches to list under a note's name, as their places in `matches`: those from `from` on,
// but for a match in an earlier one, which another word of the search found there too.
function listed(matches, from) {
  const places = []
  let end = from
  matches.forEach((match, at) => {
    if (match.from >= end) places.push(at)
    end = Math.max(end, match.to)
  })
  return places
}

// The notes that have every word of the query, in their name or their text. Names match fuzzily,
// text as plain substrings. Notes whose name has every word rank first, by how well it matches;
// then those whose name has more of the words. Notes that match equally keep their order, as all
// notes do with no query (pinned first, then newest first).
// Each note comes with `titleRanges`, the parts of its name to mark; `matches`, the places in its
// text; and `lines`, the matches to list under its name, each as a line of its own, as their
// places in `matches`: all of them but those in a first line that is the name itself. A line
// with two matches is listed twice, as in VS Code, so the list goes to each of them.
// shortcut: folds every note's text on each keystroke (about 8 ms for 500 notes of 4 kB each);
// keep the folded texts if typing lags.
export function rankNotes(notes, query, limit = 200) {
  const terms = searchTerms(query)
  if (!terms.length)
    return notes.slice(0, limit).map(note => ({...note, titleRanges: [], matches: [], lines: []}))
  const ranked = []
  for (const note of notes) {
    const inTitle = terms.map(term => fuzzyMatch(term, note.title))
    const text = fold(note.text)
    const matches = textMatches(text, terms)
    const nameEnd = nameLineEnd(text, note.title)
    const inText = new Set(matches.map(match => match.term))
    if (!terms.every((_, index) => inTitle[index] || inText.has(index))) continue
    const named = inTitle.every(Boolean)
    // Letters scattered over a name are marked only where the name is what matched.
    const marked = inTitle.filter(match => match && (named || match.ranges.length === 1))
    ranked.push({
      ...note,
      score: named ? 1000 + inTitle.reduce((sum, match) => sum + match.score, 0) : marked.length,
      titleRanges: mergeRanges(marked.flatMap(match => match.ranges)),
      matches,
      lines: listed(matches, nameEnd),
    })
  }
  ranked.sort((a, b) => b.score - a.score)
  return ranked.slice(0, limit)
}

// About how wide a text is, in Latin letters: a character of Japanese and the like counts as two.
const width = text => text.length + (text.match(/[\u2E80-\uFFEF]/g)?.length ?? 0)

// The line a match is on, for a row of the switcher: its text without its markers, up to 120
// long, with the match's range in it. Only that match is marked, since a line with more is a row
// for each. A row has room for about 48 letters in a panel of the default width, so if the match
// ends further on than that, the text is cut to start at the word within 8 characters before it.
export function snippetAt(text, {from, to}) {
  const lineStart = text.lastIndexOf("\n", from - 1) + 1
  let lineEnd = text.indexOf("\n", from)
  if (lineEnd < 0) lineEnd = text.length
  // Markers are left out only before the match, which may be in them. So is the bar a table's
  // row starts with, which would stand right behind the row's rule.
  let textFrom = lineStart + Math.min(leadLength(text.slice(lineStart, lineEnd)), from - lineStart)
  textFrom += /^(\|\s*)?/.exec(text.slice(textFrom, from))[0].length
  const cut = width(text.slice(textFrom, to)) > 48
  let start = cut ? from - 8 : textFrom
  if (cut) start += text.slice(start, from).search(/\s/) + 1
  const end = Math.min(lineEnd, start + 120)
  const shift = (cut ? 1 : 0) - start
  return {
    text: (cut ? "…" : "") + text.slice(start, end),
    ranges: [[from + shift, Math.min(to, end) + shift]],
  }
}

// What a bare URL ends before: a space or a bracket; a quote or a backtick, which a URL can't
// hold; and the full-width brackets and punctuation that Japanese text puts right after a URL,
// as in "（https://example.com/a）を参照".
const urlEnd = String.raw`\s<>()[\]"` + "`（）「」『』【】、。"
// "(" and ")" are part of a URL only as a pair, as in ".../Fish_(food)", so the ")" that closes
// a Markdown link or a sentence in parentheses ends it. Each pattern stops at the next bracket
// or parenthesis, so a long line of "[" isn't read to its end once for each of them.
const markdownLink = /\[[^[\]]*\]\(((?:[^()\s]|\([^()\s]*\))+)(?:\s[^()]*)?\)/g
const bareURL = new RegExp(String.raw`(?:https?:\/\/|mailto:)(?:[^${urlEnd}]|\([^${urlEnd}]*\))+`, "g")

// The link under `offset` in a line: a Markdown link, or a bare URL. `from` and `to` span the
// link as written, and `urlFrom` is where its URL starts.
export function linkAt(line, offset) {
  for (const m of line.matchAll(markdownLink)) {
    const to = m.index + m[0].length
    if (offset >= m.index && offset <= to)
      return {url: m[1], from: m.index, to, urlFrom: m.index + m[0].indexOf("](") + 2}
  }
  for (const m of line.matchAll(bareURL)) {
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

// A line's indentation and its list and quote markers, in any mix: "  - ", "1. ", "- [ ] ", "> ",
// "> - ".
const markers = /^(?:\s*(?:>|(?:[-*+]|\d+[.)])(?=\s|$)(?:\s+\[[ xX]\](?=\s|$))?))*\s*/

// Whether a line is in a ``` block, where "- ", "> " and "# " are code.
function inCode(state, line) {
  for (let node = syntaxTree(state).resolveInner(line.from, 1); node; node = node.parent)
    if (node.name === "FencedCode") return true
  return false
}

// How long a line's indentation, list and quote markers and a heading's #s are.
function leadLength(text) {
  const prefix = markers.exec(text)[0]
  const hashes = /^#{1,6}(?=\s|$)\s*/.exec(text.slice(prefix.length))
  return prefix.length + (hashes?.[0].length ?? 0)
}

// Where a line's text starts: after its indentation, list and quote markers and a heading's #s.
// In a ``` block, after its indentation.
export function textStart(state, line) {
  return inCode(state, line) ? /^\s*/.exec(line.text)[0].length : leadLength(line.text)
}

// The ``` or ::: block the line at `pos` is in, the innermost, fences included: `fence`, where its
// opening fence starts, and `code`, its lines between the fences, without the opening fence's
// indentation. A block that isn't closed runs to the end. null elsewhere, and in a block of
// indented lines, which has no fence.
// shortcut: a block in a quote keeps its lines' "> "; take the quote's markers off if that comes up.
export function codeBlockAt(state, pos) {
  const {doc} = state
  const line = doc.lineAt(pos)
  const block = fencedCode(state, line) ?? colonBlock(state, line.number)
  if (!block) return null
  const indent = new RegExp(`^[ \\t]{0,${block.fence - doc.line(block.open).from}}`)
  const lines = []
  for (let n = block.open + 1; n <= block.last; n++) lines.push(doc.line(n).text.replace(indent, ""))
  return {fence: block.fence, code: lines.join("\n")}
}

// The ``` (or ~~~) block a line is in, by the Markdown parser: where its fence starts, and the
// numbers of its opening fence's line and of its last line of code.
function fencedCode(state, line) {
  for (let node = syntaxTree(state).resolveInner(line.from + textStart(state, line), 1); node; node = node.parent) {
    if (node.name !== "FencedCode") continue
    const end = state.doc.lineAt(node.to).number
    const closed = node.getChildren("CodeMark").length > 1
    return {fence: node.from, open: state.doc.lineAt(node.from).number, last: closed ? end - 1 : end}
  }
  return null
}

// The ::: block the line numbered `number` is in, the innermost, as fencedCode gives it. A line of
// colons alone closes the innermost open block if it has as many colons; any other line of three
// or more opens a block, so "::::" around ":::" nests, as markdown-it and Pandoc read them.
// Colons in a ``` block are code.
// shortcut: reads every line each time the cursor moves outside a ``` block (about 2 ms for
// 10,000 lines); keep the blocks in a StateField if that lags.
function colonBlock(state, number) {
  const {doc} = state
  const open = []
  for (let n = 1; n <= doc.lines; n++) {
    const line = doc.line(n)
    const fence = /^(\s*)(:{3,})(.*)$/.exec(line.text)
    if (!fence || inCode(state, line)) continue
    const top = open.at(-1)
    if (top && !fence[3].trim() && fence[2].length >= top.colons) {
      open.pop()
      // Blocks close innermost first, so the first to close around the line is the one it's in.
      if (top.open <= number && n >= number) return {...top, last: n - 1}
    } else {
      open.push({fence: line.from + fence[1].length, open: n, colons: fence[2].length})
    }
  }
  const unclosed = open.findLast(block => block.open <= number)
  return unclosed ? {...unclosed, last: doc.lines} : null
}

// Math as Pandoc reads it, and LaTeX's display environments, which need no "$$" around them. The
// first two patterns run to the end of the text if the math isn't closed.
const mathPattern = new RegExp(
  [
    // The environments KaTeX reads outside math, \begin and \end included.
    String.raw`\\begin\{((?:equation|align|alignat|gather)\*?)\}[^]*?(?:\\end\{\1\}|$)`,
    String.raw`\$\$((?:\\[^]|[^\\])*?)(?:\$\$|$)`,
    // LaTeX's own "\[…\]", only closed, since "\[" is also how Markdown writes a plain bracket.
    // "\" takes the character after it along, so the "\\]" of a line break doesn't close it.
    String.raw`\\\[((?:\\[^]|[^\\])*?)\\\]`,
    // In a line, with no space after the first "$" or before the last and no digit after it, so
    // the dollars of "$5 and $10" aren't math.
    String.raw`\$(?!\s)((?:\\.|[^\\$\n])+?)(?<!\s)\$(?!\d)`,
    // LaTeX's own "\(…\)", in a line.
    String.raw`\\\(((?:\\.|[^\\\n])*?)\\\)`,
    // A character after "\", so the dollar of "\$" opens and closes nothing.
    String.raw`\\.`,
  ].join("|"),
  "g",
)

// Whether the character at `pos` is code: in a ``` block or an indented one, or between backticks.
function isCode(state, pos) {
  for (let node = syntaxTree(state).resolveInner(pos, 1); node; node = node.parent)
    if (/^(?:FencedCode|CodeBlock|InlineCode)$/.test(node.name)) return true
  return false
}

// The math `pos` is in or next to: "$…$" or "\(…\)" in a line, "$$…$$" or "\[…\]" over any lines,
// or a LaTeX display environment such as \begin{align}. `from` and `to` span it as written, `tex`
// is what's between its marks (an environment's \begin and \end are part of it), and `display` is
// false for the two in a line. Math ends at a blank line, closed or not, so forgetting "$$"
// doesn't make the rest of a note math. null elsewhere, and for math that starts or ends in code,
// as the dollar of `$HOME` after a price does.
// shortcut: reads the lines around `pos` up to a blank one each time the cursor moves; keep the
// math in a StateField if that lags in a long note with no blank lines.
// shortcut: math in a quote keeps its lines' "> "; take the quote's markers off if that comes up.
export function mathAt(state, pos) {
  const {doc} = state
  let first = doc.lineAt(pos)
  let last = first
  if (!first.text.trim()) return null
  while (first.number > 1 && doc.line(first.number - 1).text.trim()) first = doc.line(first.number - 1)
  while (last.number < doc.lines && doc.line(last.number + 1).text.trim()) last = doc.line(last.number + 1)
  const text = doc.sliceString(first.from, last.to)
  const at = pos - first.from
  mathPattern.lastIndex = 0
  for (let m; (m = mathPattern.exec(text)) && m.index <= at; ) {
    const [whole, environment, dollars, brackets, dollar, parentheses] = m
    const inline = dollar ?? parentheses
    const tex = environment ? whole : (dollars ?? brackets ?? inline)
    // "\" and a character.
    if (tex === undefined) continue
    const from = first.from + m.index
    if (isCode(state, from) || isCode(state, from + whole.length - 1)) {
      // What's after this character may open math.
      mathPattern.lastIndex = m.index + 1
    } else if (at <= m.index + whole.length && tex.trim()) {
      return {from, to: from + whole.length, tex, display: inline === undefined}
    }
  }
  return null
}

// The columns a line's wrapped rows hang by: the width of its list and quote markers, with the
// indentation and spaces around them. 0 for other lines and in a ``` block.
export function hangIndent(state, line) {
  const prefix = markers.exec(line.text)[0]
  return /\S/.test(prefix) && !inCode(state, line) ? countColumn(prefix, state.tabSize) : 0
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
