// Drives web/index.html in headless Chrome, posing as a Mac so CodeMirror uses its Cmd bindings.
// Run with `npm run smoke`; set CHROME to the browser binary if it is not at the default path.
import puppeteer from "puppeteer-core"
import assert from "node:assert/strict"

const pageURL = new URL("../../web/index.html", import.meta.url).href
const chrome = process.env.CHROME ?? (process.platform === "darwin"
  ? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  : "/usr/bin/google-chrome")
const browser = await puppeteer.launch({executablePath: chrome, args: ["--no-sandbox"]})
const page = await browser.newPage()
await page.setViewport({width: 480, height: 400})
await page.evaluateOnNewDocument(() => {
  Object.defineProperty(navigator, "platform", {get: () => "MacIntel"})
  window.sent = []
  window.webkit = {messageHandlers: {native: {postMessage: m => window.sent.push(m)}}}
})
const errors = []
page.on("pageerror", e => errors.push(e.message))
await page.goto(pageURL)
await page.waitForFunction(() => window.sent.some(m => m.type === "ready"))

const sent = () => page.evaluate(() => window.sent)
const last = async type => (await sent()).filter(m => m.type === type).at(-1)
const clear = () => page.evaluate(() => (window.sent = []))
const receive = (type, data) => page.evaluate((type, data) => window.receive({type, data}), type, data)
const doc = () => page.evaluate(() => document.querySelector(".cm-content").innerText)
const changedText = async () => (await last("changed"))?.text
const press = async (key, mods = []) => {
  for (const m of mods) await page.keyboard.down(m)
  await page.keyboard.press(key)
  for (const m of mods.reverse()) await page.keyboard.up(m)
}
const pause = ms => new Promise(r => setTimeout(r, ms))

// Open a note and put the cursor at the start of the last line.
await receive("open", {id: "Untitled", text: "one\n\n\nfour", opening: 1})
await page.click(".cm-content")
await press("ArrowDown", ["Meta"])
await press("ArrowLeft", ["Meta"])
await clear()

// Cmd-Backspace at a line start deletes the line break, so holding it crosses empty lines.
await press("Backspace", ["Meta"])
await press("Backspace", ["Meta"])
await press("Backspace", ["Meta"])
assert.equal(await changedText(), "onefour")
assert.equal((await last("changed")).opening, 1, "text goes back with the count the note came with")

// Edits within 500 ms form one undo step (CodeMirror's history grouping).
await press("z", ["Meta"])
assert.equal(await changedText(), "one\n\n\nfour")
await press("z", ["Meta", "Shift"])
assert.equal(await changedText(), "onefour")
await press("z", ["Meta"])
// Separate steps undo one at a time with repeated Cmd-Z.
await page.keyboard.type("a")
await pause(600)
await page.keyboard.type("b")
await pause(600)
await press("z", ["Meta"])
await press("z", ["Meta"])
assert.equal(await changedText(), "one\n\n\nfour")

// Cmd-Left goes to an item's text, then to the line start; Enter continues a list.
await receive("open", {id: "List", text: "- item"})
await page.click(".cm-content")
await press("ArrowLeft", ["Meta"])
await page.keyboard.type("x")
assert.equal(await changedText(), "- xitem")
await press("z", ["Meta"])
await press("ArrowLeft", ["Meta"])
await page.keyboard.type("x")
assert.equal(await changedText(), "x- item")
await press("z", ["Meta"])
await press("ArrowRight", ["Meta"])
await press("Enter")
await page.keyboard.type("next")
assert.equal(await changedText(), "- item\n- next")
await press("Enter")
await press("Enter")
assert.equal(await changedText(), "- item\n- next\n", "an empty item ends the list")

// Cmd-Left skips quote markers and a heading's #s too, but not "- " in a code block.
const typedAtHome = async (text, line) => {
  await receive("open", {id: "Home", text})
  await page.click(".cm-content")
  await press("ArrowUp", ["Meta"])
  for (let i = 1; i < line; i++) await press("ArrowDown")
  await press("ArrowRight", ["Meta"])
  await press("ArrowLeft", ["Meta"])
  await page.keyboard.type("x")
  return (await changedText()).split("\n")[line - 1]
}
assert.equal(await typedAtHome("> > - quote", 1), "> > - xquote")
assert.equal(await typedAtHome("## Heading", 1), "## xHeading")
assert.equal(await typedAtHome("```\n- code\n```", 2), "x- code")

// In a wrapped item, Cmd-Left goes to the row's start first; Shift-Cmd-Left selects the text.
await receive("open", {id: "Home", text: `- [ ] ${"word ".repeat(30)}end`})
await page.click(".cm-content")
await press("ArrowDown", ["Meta"])
await press("ArrowLeft", ["Meta"])
await page.keyboard.type("x")
assert.match(await changedText(), /^- \[ \] word .* x(word|end)/, "the row's start")
await press("z", ["Meta"])
await press("ArrowDown", ["Meta"])
await press("ArrowLeft", ["Meta", "Shift"])
await press("ArrowLeft", ["Meta", "Shift"])
await page.keyboard.type("x")
assert.equal(await changedText(), "- [ ] x")

// Cmd-Backspace deletes back to where Cmd-Left goes: the item's text, then its marker, then the
// line break.
await receive("open", {id: "Home", text: "a\n- [ ] task"})
await page.click(".cm-content")
await press("ArrowDown", ["Meta"])
await press("Backspace", ["Meta"])
assert.equal(await changedText(), "a\n- [ ] ")
await press("Backspace", ["Meta"])
assert.equal(await changedText(), "a\n")
await press("Backspace", ["Meta"])
assert.equal(await changedText(), "a")

// Shift-Cmd-Enter inserts a line above; Cmd-L selects the line; Alt-Up moves it.
await receive("open", {id: "Lines", text: "a\n  b"})
await page.click(".cm-content")
await press("ArrowDown", ["Meta"])
await press("Enter", ["Meta", "Shift"])
await page.keyboard.type("c")
assert.equal(await changedText(), "a\n  c\n  b")
await press("l", ["Meta"])
await page.keyboard.type("z")
assert.equal(await changedText(), "a\nz  b")
await press("z", ["Meta"])
await press("ArrowUp", ["Alt"])
assert.equal(await changedText(), "  c\na\n  b")

// Cmd-B, Cmd-I (ahead of CodeMirror's own Cmd-I), Shift-Cmd-X and Cmd-E wrap the selection,
// and press again unwraps it; Cmd-K makes it a link's text.
await receive("open", {id: "Marks", text: "word"})
await page.click(".cm-content")
await press("a", ["Meta"])
await press("b", ["Meta"])
assert.equal(await changedText(), "**word**")
await press("i", ["Meta"])
assert.equal(await changedText(), "***word***")
await press("b", ["Meta"])
await press("i", ["Meta"])
assert.equal(await changedText(), "word")
await press("x", ["Meta", "Shift"])
await press("e", ["Meta"])
assert.equal(await changedText(), "~~`word`~~")
await press("z", ["Meta"])
await press("z", ["Meta"])
await press("k", ["Meta"])
await page.keyboard.type("u")
assert.equal(await changedText(), "[word](u)")

// A click on a task's box ticks it and leaves the cursor alone; another click clears it.
await receive("open", {id: "Tasks", text: "- [ ] milk\n- [x] eggs"})
await page.click(".cm-content")
await press("ArrowDown", ["Meta"])
const boxes = await page.$$(".cm-taskBox")
assert.equal(boxes.length, 2)
await boxes[0].click()
assert.equal(await changedText(), "- [x] milk\n- [x] eggs")
await page.keyboard.type("!")
assert.equal(await changedText(), "- [x] milk\n- [x] eggs!", "the cursor stayed at the end")
await (await page.$$(".cm-taskBox"))[1].click()
assert.equal(await changedText(), "- [x] milk\n- [ ] eggs!")

// Switching back to a note keeps its undo history.
await receive("open", {id: "Untitled", text: "one\n\n\nfour", opening: 7})
await page.click(".cm-content")
await press("z", ["Meta", "Shift"])
assert.equal((await last("changed")).opening, 7)
assert.equal(await changedText(), "one\n\n\nafour", "redo history survived switching notes")

// Escape with nothing to close asks Swift to hide the panel.
await clear()
await press("Escape")
assert.ok(await last("escape"))

// Cmd-click on a link asks Swift to open it.
await receive("open", {id: "Links", text: "see [docs](https://example.com/a) now"})
await pause(50)
const box = await page.evaluate(() => {
  const range = document.createRange()
  const walker = document.createTreeWalker(document.querySelector(".cm-line"), NodeFilter.SHOW_TEXT)
  let node
  while ((node = walker.nextNode())) if (node.textContent.includes("docs")) break
  range.setStart(node, node.textContent.indexOf("docs") + 1)
  range.setEnd(node, node.textContent.indexOf("docs") + 2)
  const r = range.getBoundingClientRect()
  return {x: r.x + r.width / 2, y: r.y + r.height / 2}
})
await page.keyboard.down("Meta")
await page.mouse.click(box.x, box.y)
await page.keyboard.up("Meta")
assert.equal((await last("openURL"))?.url, "https://example.com/a")

// Pointing at a link shows Open and Copy on its URL's first characters, in the link's own row.
await clear()
await page.mouse.move(box.x, box.y)
await page.waitForSelector(".cm-linkButtons")
await pause(50)
const urlStart = await page.evaluate(() => {
  const node = [...document.querySelector(".cm-line").querySelectorAll("span")]
    .map(s => s.firstChild).find(n => n?.textContent.startsWith("https"))
  const range = document.createRange()
  range.setStart(node, 0)
  range.setEnd(node, 1)
  const r = range.getBoundingClientRect()
  return {x: r.x, y: r.y + r.height / 2}
})
const popup = await page.$eval(".cm-tooltip-hover", e => e.getBoundingClientRect().toJSON())
assert.ok(Math.abs(popup.x - urlStart.x) < 2, "the popup starts where the URL starts")
assert.ok(Math.abs(popup.y + popup.height / 2 - urlStart.y) < 3, "the popup sits on the link's row")
const copyIcon = await page.$eval(".cm-linkButtons .copy", e => e.innerHTML)
await page.click(".cm-linkButtons .copy")
assert.equal((await last("copy"))?.text, "https://example.com/a")
assert.notEqual(await page.$eval(".cm-linkButtons .copy", e => e.innerHTML), copyIcon, "Copy turns into a check")
await page.click(".cm-linkButtons .open")
assert.equal((await last("openURL"))?.url, "https://example.com/a")
await page.mouse.move(box.x, box.y + 200)
await pause(50)
assert.equal(await page.$(".cm-linkButtons"), null, "the popup goes when the pointer leaves the link")

// The switcher: fuzzy title search, keyboard selection and trash.
const notes = [
  {id: "Groceries", title: "Groceries", text: "milk", pinned: true},
  {id: "Meeting notes", title: "Meeting notes", text: "agenda", pinned: false},
  {id: "Ideas", title: "Ideas", text: "a milk frother", pinned: false},
]
await receive("switcher", {notes, force: false})
assert.equal(await page.evaluate(() => document.activeElement.id), "query")
await page.keyboard.type("mtg")
assert.deepEqual(await page.$$eval("#results li .title", els => els.map(e => e.textContent)), ["Meeting notes"])
await press("Backspace", ["Meta"])
await press("a", ["Meta"])
await press("Backspace")
await page.keyboard.type("milk")
assert.deepEqual(await page.$$eval("#results li .title", els => els.map(e => e.textContent)), ["Groceries", "Ideas"])
await press("ArrowDown")
await clear()
await press("Enter")
assert.equal((await last("select"))?.id, "Ideas")
await press("Backspace", ["Meta"])
assert.equal((await last("trash"))?.id, "Ideas")
await press("r", ["Meta"])
assert.equal(await last("rename"), undefined, "renaming moved to the title bar")
await press("Escape")
assert.equal(await page.evaluate(() => document.getElementById("switcher").hidden), true)

// Every row shows Pin and Trash, so moving the pointer never changes a row's height.
await receive("switcher", {notes, force: true})
const rowHeights = () => page.$$eval("#results li", els => els.map(e => e.getBoundingClientRect().height))
const before = await rowHeights()
await page.hover("#results li:nth-child(3)")
assert.deepEqual(await rowHeights(), before)
assert.equal(new Set(before).size, 1, "rows without snippets share one height")
assert.equal(await page.$$eval("#results li .meta", els => els.length), 0, "no dates")
assert.deepEqual(
  await page.$$eval("#results li .action.pin", els => els.map(e => e.getAttribute("aria-pressed"))),
  ["true", "false", "false"])
await clear()
await page.click("#results li:nth-child(2) .action.pin")
assert.equal((await last("pin"))?.id, "Meeting notes")
// Trash only asks; Swift confirms before deleting.
await page.click("#results li[aria-selected='true'] .action.trash")
assert.equal((await last("trash"))?.id, "Groceries")
assert.equal(await page.evaluate(() => document.getElementById("switcher").hidden), false)
await press("Escape")

// Pinned notes move with ⌥↑ and ⌥↓, or by dragging their handle, but only in the full list.
const pinnedNotes = [
  {id: "A", title: "A", text: "", pinned: true},
  {id: "B", title: "B", text: "", pinned: true},
  {id: "C", title: "C", text: "", pinned: false},
]
const titles = () => page.$$eval("#results li .title", els => els.map(e => e.textContent))
await receive("switcher", {notes: pinnedNotes, force: true})
assert.deepEqual(await page.$$eval("#results li", els => els.map(e => e.classList.contains("movable"))), [true, true, false])
assert.deepEqual(await page.$$eval("#results li .key", els => els.map(e => e.textContent)), ["⌘1", "⌘2", ""])
await clear()
await press("ArrowDown", ["Alt"])
assert.deepEqual(await titles(), ["B", "A", "C"])
assert.deepEqual((await last("orderPins"))?.ids, ["B", "A"])
await press("ArrowDown", ["Alt"])
assert.deepEqual(await titles(), ["B", "A", "C"], "an unpinned note stays below the pinned ones")
const grip = await (await page.$("#results li:nth-child(2) .grip")).boundingBox()
const firstRow = await (await page.$("#results li:nth-child(1)")).boundingBox()
await page.mouse.move(grip.x + grip.width / 2, grip.y + grip.height / 2)
await page.mouse.down()
await page.mouse.move(grip.x + grip.width / 2, firstRow.y + 2, {steps: 4})
await page.mouse.up()
assert.deepEqual(await titles(), ["A", "B", "C"])
assert.deepEqual((await last("orderPins"))?.ids, ["A", "B"])
assert.equal(await page.evaluate(() => document.getElementById("switcher").hidden), false, "dragging opens nothing")
await page.keyboard.type("b")
await clear()
await press("ArrowUp", ["Alt"])
assert.equal(await last("orderPins"), undefined, "search results keep their order")
await press("Escape")

// A note opened for a match in its text opens with the match selected.
await receive("switcher", {notes, force: true})
await page.keyboard.type("FROTHER")
await press("Enter")
assert.equal((await last("select"))?.id, "Ideas")
await receive("open", {id: "Ideas", text: "a milk frother", keep: false})
await page.keyboard.type("jug")
assert.equal(await changedText(), "a milk jug")

// The interface text size sets the switcher and footer, but not the note's text.
await receive("options", {fontSize: 14, uiFontSize: 20})
assert.equal(await page.$eval("#query", e => getComputedStyle(e).fontSize), "20px")
assert.equal(await page.$eval("#count", e => getComputedStyle(e).fontSize), "16px")
assert.equal(await page.$eval(".cm-content", e => getComputedStyle(e).fontSize), "14px")
await receive("options", {fontSize: 14, uiFontSize: 15})

// Show whitespace and the spaces Tab adds come from Settings, and hold for a note opened later.
const marks = selector => page.$$eval(selector, els => els.length)
await receive("options", {fontSize: 14, uiFontSize: 15, showWhitespace: true, indentSize: 2})
await receive("open", {id: "Spaces", text: "a b\tc\u3000d"})
assert.deepEqual(
  [await marks(".cm-highlightSpace"), await marks(".cm-highlightTab"), await marks(".cm-ideographicSpace")],
  [1, 1, 1])
await page.click(".cm-content")
await press("Tab")
assert.equal(await changedText(), "  a b\tc\u3000d")
await receive("options", {fontSize: 14, uiFontSize: 15})
assert.deepEqual(
  [await marks(".cm-highlightSpace"), await marks(".cm-highlightTab"), await marks(".cm-ideographicSpace")],
  [0, 0, 0])
await press("Tab")
assert.equal(await changedText(), "      a b\tc\u3000d", "4 spaces by default")

// A list item's and a quote's wrapped rows start under their text; a paragraph's and a ``` block's
// start at the edge.
const words = "word ".repeat(30)
await receive("open", {id: "Wrap", text: `- ${words}\n${words}\n> ${words}\n\`\`\`\n- ${words}\n\`\`\``})
await pause(50)
const rowStarts = await page.$$eval(".cm-line", lines => lines.map(line => {
  const range = document.createRange()
  range.selectNodeContents(line)
  const starts = {}
  for (const r of range.getClientRects()) if (r.width) starts[Math.round(r.top)] = Math.min(starts[Math.round(r.top)] ?? Infinity, r.left)
  return Object.values(starts)
}))
const itemText = await page.evaluate(() => {
  const walker = document.createTreeWalker(document.querySelector(".cm-line"), NodeFilter.SHOW_TEXT)
  let node
  while ((node = walker.nextNode())) if (node.textContent.includes("word")) break
  const at = node.textContent.indexOf("word")
  const range = document.createRange()
  range.setStart(node, at)
  range.setEnd(node, at + 1)
  return range.getBoundingClientRect().left
})
assert.ok([0, 1, 2, 4].every(i => rowStarts[i].length > 1), "the lines wrap")
assert.ok(rowStarts[0].slice(1).every(x => Math.abs(x - itemText) < 1), "a list item's rows start under its text")
assert.ok(rowStarts[2].slice(1).every(x => Math.abs(x - itemText) < 1), "a quote's rows start under its text")
assert.ok(rowStarts[1].every(x => Math.abs(x - rowStarts[1][0]) < 1), "a paragraph's rows start at the edge")
assert.ok(rowStarts[4].every(x => Math.abs(x - rowStarts[1][0]) < 1), "a ``` block's rows start at the edge")

// The page never asks for a window height: the panel keeps the size the user gave it.
await receive("open", {id: "Count", text: "ab\ncd"})
await pause(50)
assert.equal(await last("height"), undefined)
assert.equal(await page.$eval("#count", e => e.textContent), "4 characters")
await receive("status", "Couldn't save")
assert.equal(await page.$eval("#status", e => e.textContent), "Couldn't save")

// The history lists the note's versions over the note. Return copies the chosen one, Cmd-A selects
// only its text, nothing there changes the note, and Escape goes back to it.
await receive("open", {id: "Plan", text: "now"})
await clear()
const earlier = [
  {date: new Date().toISOString(), text: "a minute ago"},
  {date: new Date(Date.now() - 40 * 86_400_000).toISOString(), text: "older\ntext"},
]
const historyOpen = () => page.evaluate(() => !document.getElementById("history").hidden)
const historyShown = async () => (await last("historyShown"))?.shown
await receive("history", {id: "Plan", versions: earlier})
assert.equal(await historyOpen(), true)
assert.equal(await historyShown(), true, "Swift hears that the history opened")
assert.equal(await page.evaluate(() => document.activeElement.id), "history")
assert.equal(await page.$eval("#editor", e => getComputedStyle(e).opacity), "0", "the note is out of sight")
assert.match(await page.$eval("#versions li .title", e => e.textContent), /^Today \d+:\d\d$/)
assert.equal(await page.$eval("#version", e => e.textContent), "a minute ago")
await press("ArrowDown")
assert.equal(await page.$eval("#version", e => e.textContent), "older\ntext")
await press("Enter")
assert.equal((await last("copy"))?.text, "older\ntext")
assert.ok(
  await page.$eval("#versions li[aria-selected='true'] .action.copy", e => e.innerHTML.includes("M5 12.5")),
  "the button ticks")
await press("a", ["Meta"])
assert.equal(await page.evaluate(() => getSelection().toString()), "older\ntext")
await press("Tab", ["Shift"])
await page.keyboard.type("x")
assert.equal(await page.evaluate(() => document.activeElement.id), "history", "Tab stays in the history")
await page.click("#versions li:first-child .action.copy")
assert.equal((await last("copy"))?.text, "a minute ago")
await page.click("#versions li:first-child")
assert.equal(await page.$eval("#version", e => e.textContent), "a minute ago")
await press("Escape")
assert.equal(await historyOpen(), false)
assert.equal(await historyShown(), false, "and that Escape closed it")
assert.equal(await doc(), "now")
assert.equal(await last("changed"), undefined, "the note never changed")
// Cmd-Y again closes it, and the switcher or another note takes its place.
await receive("history", {id: "Plan", versions: []})
assert.equal(await page.$eval("#versions", e => e.textContent), "No earlier versions")
await receive("history", {id: "Plan", versions: []})
assert.equal(await historyOpen(), false)
await receive("history", {id: "Plan", versions: earlier})
await receive("switcher", {notes, force: true})
assert.equal(await historyOpen(), false)
assert.equal(await historyShown(), false)
await press("Escape")
await receive("history", {id: "Plan", versions: earlier})
await receive("open", {id: "Count", text: "ab\ncd"})
assert.equal(await historyOpen(), false)

// A message in the footer closes the history and the switcher, which hide the footer.
await receive("history", {id: "Count", versions: earlier})
await receive("status", "")
assert.equal(await historyOpen(), true, "clearing the message closes nothing")
await receive("status", "Couldn't open")
assert.equal(await historyOpen(), false)
await receive("switcher", {notes, force: true})
// A note renamed while the switcher is open goes by its new name there.
await receive("renamed", {from: "Ideas", to: "Thoughts"})
assert.deepEqual(
  await page.$$eval("#results li .title", els => els.map(e => e.textContent)), ["Groceries", "Meeting notes", "Thoughts"])
await receive("status", "Couldn't open")
assert.equal(await page.evaluate(() => document.getElementById("switcher").hidden), true)
assert.equal(await page.$eval("#status", e => getComputedStyle(e.parentElement).opacity), "1", "the footer is in sight")

// A search wants every word, in a note's name or in its text. Each note found is its name over
// the lines of its text that have a word, and the lines are the rows to choose.
const found = [
  {id: "Budget 2026", title: "Budget 2026", text: "# Budget 2026\n\nHardware budget was cut.\n| Q1 | budget review |", pinned: true},
  {id: "Weekly plan", title: "Weekly plan", text: "- Send the ＢＵＤＧＥＴ draft\r\n- Plan the review", pinned: false},
  {id: "Inbox", title: "Inbox", text: "call the dentist", pinned: false},
]
const groups = () => page.$$eval("#results .group", els => els.map(e =>
  [e.querySelector(".title").textContent, ...[...e.querySelectorAll(".line")].map(line => line.textContent)]))
const chosen = () => page.$eval("#results [aria-selected='true']", e => e.textContent)
const queryValue = () => page.$eval("#query", e => e.value)
const switcherOpen = () => page.evaluate(() => !document.getElementById("switcher").hidden)
await receive("status", "")
await receive("switcher", {notes: found, force: true})
assert.equal(await page.$eval("#total", e => e.textContent), "3 notes")
await page.keyboard.type("review　budget")
assert.deepEqual(await groups(), [
  ["Budget 2026", "Hardware budget was cut.", "Q1 | budget review |"],
  ["Weekly plan", "Send the ＢＵＤＧＥＴ draft", "Plan the review"],
])
assert.equal(await page.$eval("#total", e => e.textContent), "2 notes")
assert.deepEqual(
  await page.$$eval("#results mark", els => els.map(e => e.textContent)),
  ["Budget", "budget", "budget", "review", "ＢＵＤＧＥＴ", "review"])
// The arrows go through the lines and pass the names, which aren't rows.
assert.deepEqual(await page.$$eval("#results .name", els => els.map(e => e.getAttribute("role"))), [null, null])
assert.equal(await chosen(), "Hardware budget was cut.")
await press("ArrowDown")
await press("ArrowDown")
assert.equal(await chosen(), "Send the ＢＵＤＧＥＴ draft")
// A press on a name opens the note at its first line.
await clear()
await page.click("#results .group:first-child .name")
assert.equal((await last("select"))?.id, "Budget 2026")
// The note opens with its find on the row's word and the match selected, so typing replaces it.
await clear()
await press("Enter")
assert.equal((await last("select"))?.id, "Weekly plan")
await receive("open", {id: "Weekly plan", text: found[1].text, keep: false})
assert.equal(await switcherOpen(), false)
assert.equal(await page.$eval(".cm-search [name=search]", e => e.value), "budget")
await page.keyboard.type("plan")
assert.equal(await changedText(), "- Send the plan draft\n- Plan the review")
// That find is the search done, so the switcher opens on all notes again. A find the user
// started carries over: what the note doesn't have, another may.
await receive("switcher", {notes: found, force: true})
assert.equal(await queryValue(), "")
await press("Escape")
await press("f", ["Meta"])
await page.keyboard.type("dentist")
await receive("switcher", {notes: found, force: true})
assert.equal(await queryValue(), "dentist")
assert.deepEqual(await groups(), [["Inbox", "call the dentist"]])
// A note found by its name alone is a row itself.
await page.keyboard.type("wkpl")
assert.deepEqual(await groups(), [["Weekly plan"]])
assert.equal(await chosen(), "Weekly plan")
await page.keyboard.type("zzz")
assert.equal(await page.$eval("#results", e => e.textContent), "No notes match")
await press("Escape")
// Escape in the note closes its find.
await press("Escape")
assert.equal(await page.$(".cm-search"), null)

// Under the list is the chosen row's note, at the row's line, with every match marked as the
// note's find will mark them.
const previewMarks = () => page.$$eval("#preview .cm-searchMatch", els =>
  els.map(e => [e.textContent, e.classList.contains("cm-searchMatch-selected")]))
await receive("switcher", {notes: found, force: true})
assert.match(await page.$eval("#preview .cm-content", e => e.innerText), /^# Budget 2026/)
assert.deepEqual(await previewMarks(), [])
await page.keyboard.type("budget review")
assert.deepEqual(await previewMarks(), [["Budget", false], ["budget", true], ["budget", false], ["review", false]])
await press("ArrowDown")
await press("ArrowDown")
assert.match(await page.$eval("#preview .cm-content", e => e.innerText), /^- Send the ＢＵＤＧＥＴ draft/)
assert.deepEqual(await previewMarks(), [["ＢＵＤＧＥＴ", true], ["review", false]])
// A press in the note's text opens the note there.
await clear()
await page.click("#preview .cm-line:last-child")
assert.equal((await last("select"))?.id, "Weekly plan")
await press("a", ["Meta"])
await press("Backspace")
// The bar under the list sets how much of the switcher the text takes: from none, as far as
// leaving the search field and the pinned notes' rows, two rows at the least. Swift keeps it.
const previewHeight = () => page.$eval("#preview", e => e.offsetHeight)
const dragBar = async y => {
  const bar = await (await page.$("#split")).boundingBox()
  await page.mouse.move(bar.x + bar.width / 2, bar.y + bar.height / 2)
  await page.mouse.down()
  await page.mouse.move(bar.x + bar.width / 2, y, {steps: 3})
  await page.mouse.up()
}
assert.equal(await previewHeight(), 160)
await receive("options", {fontSize: 14, uiFontSize: 15, noteShare: 0.25})
assert.equal(await previewHeight(), 100)
await clear()
await dragBar(390)
assert.equal(await previewHeight(), 0)
assert.equal((await last("noteShare"))?.share, 0)
await dragBar(0)
assert.equal((await last("noteShare"))?.share, 1)
assert.equal(
  await page.$eval("#results", e => e.clientHeight), 2 * (await page.$eval("#results li", e => e.offsetHeight)))
assert.equal(await page.evaluate(() => document.activeElement.id), "query", "the search field keeps the focus")
await receive("options", {fontSize: 14, uiFontSize: 15})
assert.equal(await previewHeight(), 160)
await press("Escape")

// ↑ on the first row goes back through what was searched for; ↓ goes down the rows as ever.
for (const text of ["review", "budget"]) {
  await receive("switcher", {notes: found, force: true})
  await page.keyboard.type(text)
  await press("Escape")
}
await receive("switcher", {notes: found, force: true})
assert.equal(await queryValue(), "")
await press("ArrowUp")
assert.equal(await queryValue(), "budget")
assert.equal(await chosen(), "Hardware budget was cut.")
await press("ArrowDown")
assert.equal(await chosen(), "Q1 | budget review |")
await press("ArrowUp")
assert.deepEqual([await queryValue(), await chosen()], ["budget", "Hardware budget was cut."])
await press("ArrowUp")
assert.equal(await queryValue(), "review")
// The search brought back is selected, so typing replaces it, and ↑ starts from the last again.
await page.keyboard.type("x")
assert.equal(await queryValue(), "x")
await press("ArrowUp")
assert.equal(await queryValue(), "budget")
await press("Escape")

// Brought up by the search hot key, the panel goes with the switcher on Escape.
await receive("switcher", {notes: found, force: true, dismiss: true})
await clear()
await press("Escape")
assert.equal(await switcherOpen(), false)
assert.equal((await last("escape"))?.type, "escape")
await receive("switcher", {notes: found, force: true})
await clear()
await press("Escape")
assert.equal(await last("escape"), undefined, "opened in the panel, the switcher closes alone")

assert.deepEqual(errors, [])
console.log("smoke test passed")
await browser.close()
