// Drives web/index.html in headless Chrome, posing as a Mac so CodeMirror uses its Cmd bindings.
// Run with `npm run smoke`; set CHROME to the browser binary if it is not at the default path.
import puppeteer from "puppeteer-core"
import assert from "node:assert/strict"

const pageURL = new URL("../../web/index.html", import.meta.url).href
const chrome = process.env.CHROME ?? (process.platform === "darwin"
  ? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  : "/usr/bin/google-chrome")
const browser = await puppeteer.launch({executablePath: chrome, args: ["--no-sandbox"]})
const errors = []
// The page as Swift loads it, which keeps what it posts in `sent`.
// Each in a window of its own, as in the app, so that neither is a tab out of sight and paused.
const open = async width => {
  const page = await browser.newPage({type: "window"})
  await page.setViewport({width, height: 400})
  await page.evaluateOnNewDocument(() => {
    Object.defineProperty(navigator, "platform", {get: () => "MacIntel"})
    window.sent = []
    window.webkit = {messageHandlers: {native: {postMessage: m => window.sent.push(m)}}}
  })
  page.on("pageerror", e => errors.push(e.message))
  await page.goto(pageURL)
  await page.waitForFunction(() => window.sent.some(m => m.type === "ready"))
  return page
}
// The note's page, in the panel; the switcher's page, in its window beside it, comes later.
const page = await open(480)

// Each takes the page to use last, which is the note's unless said.
const sent = (on = page) => on.evaluate(() => window.sent)
const last = async (type, on = page) => (await sent(on)).filter(m => m.type === type).at(-1)
const clear = (on = page) => on.evaluate(() => (window.sent = []))
const receive = (type, data, on = page) => on.evaluate((type, data) => window.receive({type, data}), type, data)
const doc = () => page.evaluate(() => document.querySelector(".cm-content").innerText)
const changedText = async () => (await last("changed"))?.text
const press = async (key, mods = [], on = page) => {
  for (const m of mods) await on.keyboard.down(m)
  await on.keyboard.press(key)
  for (const m of mods.reverse()) await on.keyboard.up(m)
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

// The switcher is the same page in a window of its own, which Swift tells it's the switcher's.
// It's the switcher and nothing else, out to its window's edges.
const side = await open(220)
await receive("side", true, side)
const switcherOpen = () => side.evaluate(() => !document.getElementById("switcher").hidden)
const focused = (on = side) => on.evaluate(() => document.activeElement.id)
const titles = () => side.$$eval("#results li .title", els => els.map(e => e.textContent))
const notes = [
  {id: "Groceries", title: "Groceries", text: "milk", pinned: true},
  {id: "Meeting notes", title: "Meeting notes", text: "agenda", pinned: false},
  {id: "Ideas", title: "Ideas", text: "a milk frother", pinned: false},
]
await receive("switcher", {notes, find: true}, side)
assert.deepEqual(
  await side.evaluate(() => [getComputedStyle(document.getElementById("editor")).display,
    document.getElementById("switcher").offsetWidth, innerWidth]),
  ["none", 220, 220])
assert.equal((await last("switcherShown", side))?.shown, true, "Swift hears that the switcher wants its window")

// Fuzzy title search, keyboard selection and trash.
assert.equal(await focused(), "query")
await side.keyboard.type("mtg")
assert.deepEqual(await titles(), ["Meeting notes"])
await press("Backspace", ["Meta"], side)
await press("a", ["Meta"], side)
await press("Backspace", [], side)
await side.keyboard.type("milk")
assert.deepEqual(await titles(), ["Groceries", "Ideas"])
// Tab takes the focus to the list, where the arrows show each row's note beside the list.
await press("Tab", [], side)
await clear(side)
await press("ArrowDown", [], side)
assert.equal((await last("select", side))?.id, "Ideas")
await press("Backspace", ["Meta"], side)
assert.equal((await last("trash", side))?.id, "Ideas")
await press("r", ["Meta"], side)
assert.equal(await last("rename", side), undefined, "renaming moved to the title bar")
await press("Escape", [], side)
assert.equal(await switcherOpen(), false)
assert.equal((await last("switcherShown", side))?.shown, false, "Swift hears that the switcher closed")

// Every row shows Pin and Trash, so moving the pointer never changes a row's height.
await receive("switcher", {notes}, side)
const rowHeights = () => side.$$eval("#results li", els => els.map(e => e.getBoundingClientRect().height))
const before = await rowHeights()
await side.hover("#results li:nth-child(3)")
assert.deepEqual(await rowHeights(), before)
assert.equal(new Set(before).size, 1, "rows without snippets share one height")
assert.equal(await side.$$eval("#results li .meta", els => els.length), 0, "no dates")
assert.deepEqual(
  await side.$$eval("#results li .action.pin", els => els.map(e => e.getAttribute("aria-pressed"))),
  ["true", "false", "false"])
await clear(side)
await side.click("#results li:nth-child(2) .action.pin")
assert.equal((await last("pin", side))?.id, "Meeting notes")
// Trash only asks; Swift confirms before deleting.
await side.click("#results li[aria-selected='true'] .action.trash")
assert.equal((await last("trash", side))?.id, "Groceries")
assert.equal(await switcherOpen(), true)
await press("Escape", [], side)

// Pinned notes move with ⌥↑ and ⌥↓, or by dragging their key, but only in the full list.
const pinnedNotes = [
  {id: "A", title: "A", text: "", pinned: true},
  {id: "B", title: "B", text: "", pinned: true},
  {id: "C", title: "C", text: "", pinned: false},
]
await receive("switcher", {notes: pinnedNotes}, side)
assert.deepEqual(await side.$$eval("#results li", els => els.map(e => e.classList.contains("movable"))), [true, true, false])
assert.deepEqual(await side.$$eval("#results li .key", els => els.map(e => e.textContent)), ["⌘1", "⌘2", ""])
await clear(side)
await press("ArrowDown", ["Alt"], side)
assert.deepEqual(await titles(), ["B", "A", "C"])
assert.deepEqual((await last("orderPins", side))?.ids, ["B", "A"])
await press("ArrowDown", ["Alt"], side)
assert.deepEqual(await titles(), ["B", "A", "C"], "an unpinned note stays below the pinned ones")
const key = await (await side.$("#results li:nth-child(2) .key")).boundingBox()
const firstRow = await (await side.$("#results li:nth-child(1)")).boundingBox()
await side.mouse.move(key.x + key.width / 2, key.y + key.height / 2)
await side.mouse.down()
await side.mouse.move(key.x + key.width / 2, firstRow.y + 2, {steps: 4})
await side.mouse.up()
assert.deepEqual(await titles(), ["A", "B", "C"])
assert.deepEqual((await last("orderPins", side))?.ids, ["A", "B"])
assert.equal(await switcherOpen(), true, "dragging opens nothing")
await press("Tab", [], side)
await side.keyboard.type("b")
await clear(side)
await press("ArrowUp", ["Alt"], side)
assert.equal(await last("orderPins", side), undefined, "search results keep their order")
await press("Escape", [], side)

// Dragging the switcher's left edge asks Swift for a width that follows the pointer.
await receive("switcher", {notes}, side)
await clear(side)
await side.mouse.move(1, 200)
await side.mouse.down()
await side.mouse.move(31, 200, {steps: 3})
await side.mouse.up()
assert.equal((await last("sideWidth", side))?.width, 190)
assert.equal(await side.evaluate(() => document.body.classList.contains("resizing")), false)
assert.equal(await last("select", side), undefined, "the edge isn't a row")
await press("Escape", [], side)

// A note opened for a match in its text opens with the match selected. The switcher asks for the
// note with the match; Swift opens it in the note's page, which puts the cursor there.
await receive("switcher", {notes, find: true}, side)
await side.keyboard.type("FROTHER")
await press("Enter", [], side)
const frother = await last("select", side)
assert.equal(frother?.id, "Ideas")
await receive("open", {id: "Ideas", text: "a milk frother", land: frother.land})
await press("Escape", [], side)
await receive("focus", "")
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
await receive("switcherShown", true)
assert.equal(await historyOpen(), false)
assert.equal(await historyShown(), false)
await receive("switcherShown", false)
await receive("history", {id: "Plan", versions: earlier})
await receive("open", {id: "Count", text: "ab\ncd"})
assert.equal(await historyOpen(), false)

// A message in the footer closes the history, which hides the footer.
await receive("history", {id: "Count", versions: earlier})
await receive("status", "")
assert.equal(await historyOpen(), true, "clearing the message closes nothing")
await receive("status", "Couldn't open")
assert.equal(await historyOpen(), false)
// A note renamed while the switcher is open goes by its new name there.
await receive("switcher", {notes}, side)
await receive("renamed", {from: "Ideas", to: "Thoughts"}, side)
assert.deepEqual(await titles(), ["Groceries", "Meeting notes", "Thoughts"])
await press("Escape", [], side)

// ⌘P brings the switcher up with the focus in the list, on the open note. The arrows go from note
// to note, each showing in the note's page beside the switcher.
const found = [
  {id: "Budget 2026", title: "Budget 2026", text: "# Budget 2026\n\nHardware budget was cut.\n| Q1 | budget review |", pinned: true},
  {id: "Weekly plan", title: "Weekly plan", text: "- Send the ＢＵＤＧＥＴ draft\r\n- Plan the review", pinned: false},
  {id: "Inbox", title: "Inbox", text: "call the dentist", pinned: false},
]
const weekly = "- Send the ＢＵＤＧＥＴ draft\n- Plan the review"
const groups = () => side.$$eval("#results .group", els => els.map(e =>
  [e.querySelector(".title").textContent, ...[...e.querySelectorAll(".line")].map(line => line.textContent)]))
const chosen = () => side.$eval("#results [aria-selected='true']", e => e.textContent)
const queryValue = () => side.$eval("#query", e => e.value)
const noteMarks = () => page.$$eval("#editor .cm-searchMatch", els =>
  els.map(e => [e.textContent, e.classList.contains("cm-searchMatch-selected")]))
// What Swift does with the switcher's `select`: opens the note in the note's page, where to land.
const showChosen = async () => {
  const {id, land} = await last("select", side)
  await receive("open", {id, text: found.find(note => note.id === id).text.replace(/\r\n/g, "\n"), land})
}
await receive("status", "")
await receive("open", {id: "Weekly plan", text: weekly})
await receive("switcher", {notes: found, current: "Weekly plan"}, side)
assert.deepEqual([await focused(), await chosen()], ["results", "Weekly plan"])
assert.equal(await side.$eval("#total", e => e.textContent), "3 notes")
await clear(side)
await press("ArrowDown", [], side)
assert.deepEqual(await last("select", side), {type: "select", id: "Inbox", land: {query: "", place: null}})
await showChosen()
assert.deepEqual([await switcherOpen(), await focused()], [true, "results"])
assert.match(await doc(), /call the dentist/)
// Return closes the switcher on the note in sight.
await clear(side)
await press("Enter", [], side)
assert.equal(await switcherOpen(), false)
assert.equal(await last("select", side), undefined)

// ⌘F brings it up with the focus in the search field. A search wants every word, in a note's
// name or in its text. The note in sight is listed first, and the note's page marks its matches as
// the search is typed, so the switcher is the find for one note too.
await receive("open", {id: "Weekly plan", text: weekly})
await receive("switcher", {notes: found, find: true, current: "Weekly plan"}, side)
assert.equal(await focused(), "query")
await side.keyboard.type("review　budget")
assert.deepEqual(await groups(), [
  ["Weekly plan", "Send the ＢＵＤＧＥＴ draft", "Plan the review"],
  ["Budget 2026", "Hardware budget was cut.", "Q1 | budget review |"],
])
assert.equal(await side.$eval("#total", e => e.textContent), "2 notes")
assert.deepEqual(
  await side.$$eval("#results mark", els => els.map(e => e.textContent)),
  ["ＢＵＤＧＥＴ", "review", "Budget", "budget", "budget", "review"])
assert.deepEqual(await side.$$eval("#results .name", els => els.map(e => e.getAttribute("role"))), [null, null])
assert.equal((await last("marks", side))?.query, "review　budget")
await receive("marks", "review　budget")
assert.deepEqual(await noteMarks(), [["ＢＵＤＧＥＴ", false], ["review", false]])
// Return takes the focus to the top of the list, and that row's note shows. The arrows go on
// from there, through the note in sight and then into the next note.
await clear(side)
await press("Enter", [], side)
assert.equal((await last("select", side))?.id, "Weekly plan")
await showChosen()
assert.deepEqual(await noteMarks(), [["ＢＵＤＧＥＴ", true], ["review", false]])
assert.deepEqual([await focused(), await chosen()], ["results", "Send the ＢＵＤＧＥＴ draft"])
await press("ArrowDown", [], side)
await press("ArrowDown", [], side)
assert.deepEqual([(await last("select", side))?.id, await chosen()], ["Budget 2026", "Hardware budget was cut."])
await showChosen()
assert.deepEqual(await noteMarks(), [["Budget", false], ["budget", true], ["budget", false], ["review", false]])
// Tab goes to the search field and back. The arrows there are the field's own.
await press("Tab", [], side)
await press("ArrowDown", [], side)
assert.deepEqual([await focused(), await chosen()], ["query", "Hardware budget was cut."])
await press("Tab", [], side)
assert.equal(await focused(), "results")
// Escape closes the switcher. Swift takes the marks away and gives the note the focus, with the
// cursor on the match, so typing replaces it.
await press("Escape", [], side)
assert.equal(await switcherOpen(), false)
await receive("switcherShown", false)
await receive("focus", "")
assert.deepEqual(await noteMarks(), [])
await page.keyboard.type("plan")
assert.equal(await changedText(), "# Budget 2026\n\nHardware plan was cut.\n| Q1 | budget review |")
// The marks are the note's own matches: written in since the list was made, the note still
// gets its cursor on a match and its marks where the words are now.
await receive("open", {id: "Budget 2026", text: "budget: x\n# Budget 2026", land: {query: "budget", place: {from: 2, to: 8, term: 0}}})
assert.deepEqual(await noteMarks(), [["budget", true], ["Budget", false]])

// A press on a row or a name shows the note and leaves the switcher open. A note found by its
// name alone is a row itself.
await receive("switcher", {notes: found, find: true, current: "Budget 2026"}, side)
await side.keyboard.type("budget")
await clear(side)
await side.click("#results .group:nth-child(2) .name")
assert.equal((await last("select", side))?.id, "Weekly plan")
assert.deepEqual([await focused(), await chosen()], ["results", "Send the ＢＵＤＧＥＴ draft"])
await press("Tab", [], side)
await press("a", ["Meta"], side)
await side.keyboard.type("wkpl")
assert.deepEqual(await groups(), [["Weekly plan"]])
assert.equal(await chosen(), "Weekly plan")
await side.keyboard.type("zzz")
assert.equal(await side.$eval("#results", e => e.textContent), "No notes match")
await press("Escape", [], side)
// Escape in the note goes to Swift, which closes the switcher if it's up: the switcher hears
// `close`.
await receive("switcher", {notes: found}, side)
await clear(side)
await receive("close", "", side)
assert.equal(await switcherOpen(), false)
assert.equal((await last("switcherShown", side))?.shown, false)

// In the search field ↑ goes back through what was searched for and ↓ comes forward again, as
// far as what was typed. The list isn't theirs.
for (const text of ["review", "budget"]) {
  await receive("switcher", {notes: found, find: true}, side)
  await side.keyboard.type(text)
  await press("Escape", [], side)
}
await receive("switcher", {notes: found, find: true}, side)
assert.equal(await queryValue(), "")
await side.keyboard.type("in")
await press("ArrowUp", [], side)
assert.deepEqual([await queryValue(), await focused()], ["budget", "query"])
await press("ArrowUp", [], side)
assert.equal(await queryValue(), "review")
await press("ArrowDown", [], side)
assert.equal(await queryValue(), "budget")
await press("ArrowDown", [], side)
assert.equal(await queryValue(), "in")
assert.deepEqual(await groups(), [["Inbox"]])
await press("ArrowDown", [], side)
assert.deepEqual([await queryValue(), await focused()], ["in", "query"])
await press("Escape", [], side)
// A search is remembered once it's used, without closing the switcher, and a search the field
// already has is passed over.
await receive("switcher", {notes: found, find: true}, side)
await side.keyboard.type("dentist")
await press("Enter", [], side)
await press("Tab", [], side)
await press("ArrowUp", [], side)
assert.equal(await queryValue(), "in")
await press("Escape", [], side)

// Brought up by the search hot key, the panel goes with the switcher on Escape.
await receive("switcher", {notes: found, find: true, dismiss: true}, side)
await clear(side)
await press("Escape", [], side)
assert.equal(await switcherOpen(), false)
assert.equal((await last("escape", side))?.type, "escape")
await receive("switcher", {notes: found, find: true}, side)
await clear(side)
await press("Escape", [], side)
assert.equal(await last("escape", side), undefined, "opened in the panel, the switcher closes alone")
// ⌘P and ⌘F are toggles: with the focus already where the key puts it, the switcher closes, and
// else the focus goes there. Swift says whether the switcher's window has the focus at all
// (`key`). The list button closes it from anywhere; the search hot key never.
await receive("switcher", {notes: found, find: true}, side)
await receive("switcher", {notes: found, key: true}, side)
assert.deepEqual([await switcherOpen(), await focused()], [true, "results"])
await receive("switcher", {notes: found, find: true, key: true}, side)
assert.deepEqual([await switcherOpen(), await focused()], [true, "query"])
await receive("switcher", {notes: found, find: true, force: true, key: true}, side)
assert.equal(await switcherOpen(), true)
await receive("switcher", {notes: found, find: true, key: true}, side)
assert.equal(await switcherOpen(), false)
await receive("switcher", {notes: found}, side)
await receive("switcher", {notes: found, key: false}, side)
assert.equal(await switcherOpen(), true, "from the note, ⌘P takes the focus to the list")
await receive("switcher", {notes: found, key: true}, side)
assert.equal(await switcherOpen(), false)
await receive("switcher", {notes: found, toggle: true}, side)
await press("Tab", [], side)
await receive("switcher", {notes: found, toggle: true}, side)
assert.equal(await switcherOpen(), false)
// ⌘F with some of a line selected in the note is that text typed and Return: the focus is at the
// top of the list, on the note's first match. Swift asks the note's page what's selected. The
// match the search leaves selected isn't asked for, so the next ⌘F is a new search.
const findText = () => page.evaluate(() => findText())
await receive("open", {id: "Weekly plan", text: weekly})
await page.click(".cm-content")
await press("ArrowDown", ["Meta"])
await press("ArrowLeft", ["Shift", "Alt"])
assert.equal(await findText(), "review")
await clear(side)
await receive("switcher", {notes: found, find: true, current: "Weekly plan", picked: "review"}, side)
assert.deepEqual([await queryValue(), await focused(), (await last("select", side))?.id], ["review", "results", "Weekly plan"])
await showChosen()
assert.equal(await chosen(), "Plan the review")
await press("Escape", [], side)
await receive("focus", "")
assert.equal(await findText(), "")
// More than a line selected is no search.
await press("a", ["Meta"])
assert.equal(await findText(), "")
// When Swift gives the focus back to the switcher, after a sheet, it goes where it was there: the
// list or the search field. In the note's page it goes to the note.
await receive("switcher", {notes: found}, side)
await receive("focus", "", side)
assert.equal(await focused(), "results")
await press("Tab", [], side)
await receive("focus", "", side)
assert.equal(await focused(), "query")
await press("Escape", [], side)
await receive("focus", "")
assert.equal(await page.evaluate(() => document.activeElement.className.includes("cm-content")), true)

assert.deepEqual(errors, [])
console.log("smoke test passed")
await browser.close()
