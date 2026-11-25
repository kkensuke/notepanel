import {test} from "node:test"
import assert from "node:assert/strict"
import {EditorState, EditorSelection} from "@codemirror/state"
import {
  fold,
  searchTerms,
  fuzzyMatch,
  rankNotes,
  snippetAt,
  urlAt,
  linkAt,
  hangIndent,
  textStart,
  codeBlockAt,
  mathAt,
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

const score = (query, target) => fuzzyMatch(query, target)?.score ?? null

test("fuzzyMatch matches characters in order and prefers runs", () => {
  assert.equal(score("xyz", "meeting notes"), null)
  assert.ok(score("mtg", "meeting") !== null)
  assert.ok(score("meet", "meeting notes") > score("me", "my estimate"))
  assert.ok(score("notes", "notes") > score("notes", "notes about many things"))
})

test("fuzzyMatch handles text outside the BMP and non-Latin scripts", () => {
  // "あい" is two Japanese kana; "\u{1F600}" is an emoji made of two UTF-16 units.
  assert.deepEqual(fuzzyMatch("あい", "あxい").ranges, [[0, 1], [2, 3]])
  assert.deepEqual(fuzzyMatch("\u{1F600}a", "\u{1F600}abc").ranges, [[0, 3]])
})

test("fuzzyMatch takes a run of the query before scattered letters, at a word start if it can", () => {
  // Letter by letter from the left, "note" would take the N of "Nagoya".
  assert.deepEqual(fuzzyMatch("note", "Nagoya trip notes").ranges, [[12, 16]])
  assert.deepEqual(fuzzyMatch("art", "Smart cart art").ranges, [[11, 14]])
  assert.deepEqual(fuzzyMatch("art", "Smart cart").ranges, [[2, 5]])
  assert.deepEqual(fuzzyMatch("mtg", "Meeting").ranges, [[0, 1], [3, 4], [6, 7]])
})

test("fold keeps every position, and searchTerms splits at full-width spaces too", () => {
  const text = "ＡＰＩ　Ｋｅｙ İstanbul ÀB"
  assert.equal(fold(text), "api key istanbul àb")
  assert.equal(fold(text).length, text.length)
  assert.deepEqual(searchTerms(" 会議　予算  API "), ["会議", "予算", "api"])
  assert.deepEqual(searchTerms(" 　 "), [])
})

test("rankNotes puts title matches first and finds the places in the text", () => {
  const notes = [
    {id: "Groceries", title: "Groceries", text: "milk\neggs"},
    {id: "Ideas", title: "Ideas", text: "buy a milk frother"},
    {id: "Milk tea", title: "Milk tea", text: ""},
  ]
  const ranked = rankNotes(notes, "milk")
  assert.deepEqual(ranked.map(n => n.id), ["Milk tea", "Groceries", "Ideas"])
  assert.deepEqual(ranked[0].titleRanges, [[0, 4]])
  assert.deepEqual(ranked[0].lines, [])
  assert.deepEqual(ranked[1].matches, [{from: 0, to: 4, term: 0}])
  assert.deepEqual(ranked[1].lines, [0])
  assert.deepEqual(snippetAt(notes[1].text, ranked[2].matches[0]), {text: "buy a milk frother", ranges: [[6, 10]]})
  assert.deepEqual(rankNotes(notes, " ").map(n => n.id), ["Groceries", "Ideas", "Milk tea"])
  assert.equal(rankNotes(notes, "", 2).length, 2)
})

test("rankNotes wants every word, in the name or the text, whatever their order", () => {
  const notes = [
    {id: "Meeting notes", title: "Meeting notes", text: "# Meeting notes\n\n- 来期の予算を決める\n- 会議は木曜"},
    {id: "Budget", title: "Budget", text: "予算の内訳\n会議で使う予算の表"},
    {id: "Trip", title: "Trip", text: "会議のあとで出発"},
  ]
  const ranked = rankNotes(notes, "会議　予算")
  assert.deepEqual(ranked.map(n => n.id), ["Meeting notes", "Budget"])
  // Every match, in the text's order, each on its line with only itself marked: a line with two
  // is there twice.
  const lines = note => note.lines.map(at => snippetAt(note.text, note.matches[at]))
  assert.deepEqual(lines(ranked[1]).map(line => line.text), ["予算の内訳", "会議で使う予算の表", "会議で使う予算の表"])
  assert.deepEqual(lines(ranked[1]).map(line => line.ranges), [[[0, 2]], [[0, 2]], [[5, 7]]])
  // One word in the name and one in the text.
  const mixed = rankNotes(notes, "meeting 木曜")[0]
  assert.deepEqual(mixed.titleRanges, [[0, 7]])
  assert.deepEqual(lines(mixed).map(line => line.text), ["会議は木曜"])
  assert.deepEqual(rankNotes(notes, "ｂｕｄｇｅｔ").map(n => n.id), ["Budget"], "full-width letters match")
  // A name with one of the words comes before a text with both.
  const logs = [
    {id: "Log", title: "Log", text: "api key rotation"},
    {id: "API design", title: "API design", text: "each client gets a key"},
  ]
  assert.deepEqual(rankNotes(logs, "api key").map(n => n.id), ["API design", "Log"])
})

test("rankNotes finds the name in the first line too, but doesn't list that line under the name", () => {
  const notes = [{id: "Meeting notes", title: "Meeting notes", text: "# Meeting notes\n\nnext meeting: Thursday"}]
  const [note] = rankNotes(notes, "meeting")
  assert.deepEqual(note.titleRanges, [[0, 7]])
  assert.deepEqual(note.matches, [{from: 2, to: 9, term: 0}, {from: 22, to: 29, term: 0}])
  assert.deepEqual(note.lines, [1])
  // A note with the word in its name only has no line to list, and has the place to open at.
  const [named] = rankNotes(notes, "notes")
  assert.deepEqual(named.matches, [{from: 10, to: 15, term: 0}])
  assert.deepEqual(named.lines, [])
  // A first line that only has the name in it is text like any other.
  const [idea] = rankNotes([{id: "Ideas", title: "Ideas", text: "Ideas for the trip"}], "ideas")
  assert.deepEqual(idea.lines, [0])
})

test("rankNotes lists a word twice on a line twice, but a match in another isn't listed again", () => {
  const notes = [{id: "n", title: "n", text: "foo bar foo\nfoobar"}]
  const [twice] = rankNotes(notes, "foo")
  assert.deepEqual(twice.lines, [0, 1, 2])
  assert.deepEqual(twice.lines.map(at => snippetAt(twice.text, twice.matches[at]).ranges), [[[0, 3]], [[8, 11]], [[0, 3]]])
  // "o" is found in "foo" too, as are the words a search repeats.
  for (const query of ["foo o", "foo foo"]) {
    const [note] = rankNotes(notes, query)
    assert.deepEqual(note.lines.map(at => note.matches[at].from), [0, 8, 12], query)
  }
})

test("snippetAt gives the line, or starts near a match that is far into it, and marks the match", () => {
  const near = "Each client of the service gets an API key"
  assert.deepEqual(snippetAt(near, {from: 35, to: 38, term: 0}), {text: near, ranges: [[35, 38]]})
  const text = "Each client of the service that we run for them gets an API key, and an API key rotates"
  const matches = rankNotes([{id: "n", title: "n", text}], "api")[0].matches
  const snippets = matches.map(match => snippetAt(text, match))
  assert.deepEqual(snippets.map(snippet => snippet.text), ["…an API key, and an API key rotates", "…and an API key rotates"])
  assert.deepEqual(snippets.map(snippet => snippet.ranges), [[[4, 7]], [[8, 11]]])
  // Japanese is twice as wide, and has no spaces to start at.
  const kana = "あ".repeat(24) + "予算"
  assert.equal(snippetAt(kana, {from: 24, to: 26, term: 0}).text, "…" + "あ".repeat(8) + "予算")
  assert.equal(snippetAt(kana.slice(4), {from: 20, to: 22, term: 0}).text, kana.slice(4))
})

test("snippetAt leaves out a line's markers, unless the match is in them", () => {
  const text = "  - [ ] 予算案を直す\n## 予算\n> - [x] done"
  const matches = rankNotes([{id: "n", title: "n", text}], "予算")[0].matches
  assert.deepEqual(snippetAt(text, matches[0]), {text: "予算案を直す", ranges: [[0, 2]]})
  assert.equal(snippetAt(text, matches[1]).text, "予算")
  assert.equal(snippetAt(text, {from: 25, to: 28, term: 0}).text, "[x] done")
  assert.equal(snippetAt("| 項目 | 予算 |", {from: 7, to: 9, term: 0}).text, "項目 | 予算 |")
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

test("linkAt takes paired parentheses into a URL, and ends it before what can't be in one", () => {
  const url = "https://en.wikipedia.org/wiki/Fish_(food)"
  assert.equal(urlAt(`[fish](${url})`, 3), url)
  assert.equal(urlAt(`see ${url} here`, 10), url)
  assert.equal(urlAt("(see https://example.com/a)", 10), "https://example.com/a")
  assert.equal(urlAt('[docs](https://example.com/a "title")', 3), "https://example.com/a")
  assert.equal(urlAt("run `curl https://example.com/a` now", 20), "https://example.com/a")
  assert.equal(urlAt('<a href="https://example.com/a">', 15), "https://example.com/a")
  assert.equal(urlAt("詳細は（https://example.com/a）を参照", 10), "https://example.com/a")
  assert.equal(urlAt("「https://example.com/a」、次へ", 5), "https://example.com/a")
  // Japanese in the URL itself is kept.
  assert.equal(urlAt("https://ja.wikipedia.org/wiki/魚 です", 5), "https://ja.wikipedia.org/wiki/魚")
})

test("linkAt reads a long line of brackets once, not once for each bracket", () => {
  const start = performance.now()
  linkAt("[".repeat(50_000), 1)
  assert.ok(performance.now() - start < 500, "took longer than half a second")
})

test("hangIndent measures list and quote markers, and is 0 for other lines and in code", () => {
  const lines = [
    ["- item", 2],
    ["  * nested", 4],
    ["\t+ tabbed", 6],
    ["1. first", 3],
    ["10) tenth", 4],
    ["- [ ] task", 6],
    ["- [x] done", 6],
    ["> quote", 2],
    ["> - [ ] quoted task", 8],
    [">> nested", 3],
    ["## Heading", 0],
    ["Plain text - not a list", 0],
    ["*emphasis* only", 0],
    ["-no space", 0],
    ["", 0],
    ["```", 0],
    ["- code", 0],
    ["> code", 0],
    ["```", 0],
  ]
  const doc = lines.map(([text]) => text).join("\n")
  const state = EditorState.create({doc, extensions: markdown({base: markdownLanguage})})
  const indents = lines.map((_, i) => hangIndent(state, state.doc.line(i + 1)))
  assert.deepEqual(indents, lines.map(([, indent]) => indent))
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

test("textStart skips indentation, list and quote markers and a heading's #s, but not in code", () => {
  const lines = [
    ["- item", 2],
    ["    1. nested", 7],
    ["- [ ] task", 6],
    ["> - [x] in a quote", 8],
    ["> > quote", 4],
    [">no space", 1],
    ["## Heading", 3],
    ["- # in a list", 4],
    ["    indented", 4],
    ["Plain - text", 0],
    ["*emphasis* -no-space #tag", 0],
    ["---", 0],
    ["- ", 2],
    ["```", 0],
    ["- code", 0],
    ["  > # code", 2],
    ["```", 0],
  ]
  const doc = lines.map(([text]) => text).join("\n")
  const state = EditorState.create({doc, extensions: markdown({base: markdownLanguage})})
  const starts = lines.map((_, i) => textStart(state, state.doc.line(i + 1)))
  assert.deepEqual(starts, lines.map(([, start]) => start))
})

test("codeBlockAt finds the ``` or ::: block a line is in, fences included, and its code", () => {
  // Each line of a note, with the code of the block it's in, or null.
  const blocks = lines => {
    const state = EditorState.create({doc: lines.join("\n"), extensions: markdown({base: markdownLanguage})})
    return lines.map((_, i) => codeBlockAt(state, state.doc.line(i + 1).from)?.code ?? null)
  }
  const fenced = ["text", "```js", "let a", "", "  b", "```", "after"]
  assert.deepEqual(blocks(fenced), [null, ...Array(5).fill("let a\n\n  b"), null])
  // In a list, the code loses the fence's indentation. Indented code has no fence.
  const listed = ["- item", "    ```sh", "    echo", "      more", "    ```", "", "    indented"]
  assert.deepEqual(blocks(listed), [null, ...Array(4).fill("echo\n  more"), null, null])
  // ::: blocks nest by their colons, hold ``` blocks, whose colons are code, and run to the end
  // if they aren't closed.
  const colons = ["::::details Title", ":::message", "inner", ":::", "```", ":::", "```", "::::", "::: tip", "open"]
  const inner = ":::message\ninner\n:::\n```\n:::\n```"
  assert.deepEqual(blocks(colons), [inner, "inner", "inner", "inner", ":::", ":::", ":::", inner, "open", "open"])
  const state = EditorState.create({doc: "a\n  ```\n  b\n  ```", extensions: markdown({base: markdownLanguage})})
  assert.equal(codeBlockAt(state, 5).fence, 4, "the fence starts after its indentation")
})

test("mathAt finds $…$, $$…$$, \\(…\\), \\[…\\] and LaTeX's displays, and no dollars that aren't math", () => {
  // The math at the "|" in a note: as written, its TeX, and whether it's a display.
  const math = doc => {
    const state = EditorState.create({doc: doc.replace("|", ""), extensions: markdown({base: markdownLanguage})})
    const found = mathAt(state, doc.indexOf("|"))
    return found && [state.sliceDoc(found.from, found.to), found.tex, found.display]
  }
  // The cursor next to either dollar is in the math.
  for (const doc of ["a |$x^2$ b", "a $x|^2$ b", "a $x^2$| b"]) assert.deepEqual(math(doc), ["$x^2$", "x^2", false])
  assert.equal(math("a| $x^2$ b"), null)
  assert.equal(math("a $x^2$ |b"), null)
  assert.deepEqual(math("$a$ and $b|$"), ["$b$", "b", false])
  assert.deepEqual(math(String.raw`$a\$|b$`), [String.raw`$a\$b$`, String.raw`a\$b`, false])
  // Prices, a space inside either dollar, a digit after the last, "\$", another line, and code.
  const dollars = ["$5 and $|10", "it costs $|5", "$ a|$", "$a| $", "$a|$1", String.raw`\$a|$`, "$a\n|b$"]
  const code = ["`$a|$`", "```\n$a|$\n```", "    $a|$", "$1|0, `$HOME`"]
  for (const doc of [...dollars, ...code]) assert.equal(math(doc), null, doc)
  assert.deepEqual(math("`$a` costs$b|$"), ["$b$", "b", false], "a dollar in code opens nothing")

  assert.deepEqual(math("$$a=|f$$"), ["$$a=f$$", "a=f", true])
  assert.deepEqual(math("text\n$$\na=|f\n$$\nmore"), ["$$\na=f\n$$", "\na=f\n", true])
  // Math that isn't closed ends at the blank line, and two dollars with nothing after aren't math.
  assert.deepEqual(math("$$\na=|f\n\nnext"), ["$$\na=f", "\na=f", true])
  assert.equal(math("$$\na=f\n\nne|xt"), null)
  assert.equal(math("$$|"), null)

  // LaTeX's own marks are math only closed: \(…\) in a line, \[…\] before the blank line.
  for (const doc of [String.raw`a |\(x^2\) b`, String.raw`a \(x|^2\) b`, String.raw`a \(x^2\)| b`])
    assert.deepEqual(math(doc), [String.raw`\(x^2\)`, "x^2", false])
  assert.deepEqual(math("\\[\na=|f\n\\]"), ["\\[\na=f\n\\]", "\na=f\n", true])
  assert.deepEqual(math(String.raw`\[a \\|] b\]`), [String.raw`\[a \\] b\]`, String.raw`a \\] b`, true], "a line break's \\\\] closes nothing")
  const open = [String.raw`\(a|`, "\\(a\n|b\\)", String.raw`\[a|`, "\\[a\n\n|b\\]", String.raw`\\(a|\\)`, String.raw`\\[a|\\]`]
  for (const doc of [...open, "`\\(a|\\)`", String.raw`\[ |\]`]) assert.equal(math(doc), null, doc)

  const align = "\\begin{align}\na &= b\n\\end{align}"
  assert.deepEqual(math(`see\n${align.replace("&", "|&")}\nit`), [align, align, true])
  assert.deepEqual(math("\\begin{gather*}\n|a"), ["\\begin{gather*}\na", "\\begin{gather*}\na", true])
  assert.equal(math("\\begin{itemize}\n|\\item a\n\\end{itemize}"), null)
  assert.deepEqual(math(`$$\n${align}|\n$$`), [`$$\n${align}\n$$`, `\n${align}\n`, true], "in $$, it's part of the math")
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
