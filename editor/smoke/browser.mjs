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
await receive("open", {id: "Untitled", text: "one\n\n\nfour"})
await page.click(".cm-content")
await press("ArrowDown", ["Meta"])
await press("ArrowLeft", ["Meta"])
await clear()

// Cmd-Backspace at a line start deletes the line break, so holding it crosses empty lines.
await press("Backspace", ["Meta"])
await press("Backspace", ["Meta"])
await press("Backspace", ["Meta"])
assert.equal(await changedText(), "onefour")
assert.equal((await last("changed")).id, "Untitled")

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

// Cmd-Left goes to the line start, so typing lands there; Enter continues a list.
await receive("open", {id: "List", text: "- item"})
await page.click(".cm-content")
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

// Switching back to a note keeps its undo history.
await receive("open", {id: "Untitled", text: "one\n\n\nfour"})
await page.click(".cm-content")
await press("z", ["Meta", "Shift"])
assert.equal((await last("changed")).id, "Untitled")
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

// The switcher: fuzzy title search, keyboard selection, trash and rename.
const notes = [
  {id: "Groceries", title: "Groceries", modified: Date.now(), text: "milk"},
  {id: "Untitled", title: "Meeting notes", modified: Date.now() - 1000, text: "agenda"},
  {id: "Ideas", title: "Ideas", modified: Date.now() - 2000, text: "a milk frother"},
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
await page.waitForFunction(() => document.activeElement.classList.contains("rename"))
// The whole name starts selected, as in Finder; move to its end to append.
await press("ArrowRight")
await page.keyboard.type(" 2")
await press("Enter")
assert.deepEqual(await last("rename"), {type: "rename", from: "Ideas", to: "Ideas 2"})
await press("Escape")
assert.equal(await page.evaluate(() => document.getElementById("switcher").hidden), true)

// The selected row has Rename and Trash buttons. Trash only asks; Swift confirms before deleting.
await receive("switcher", {notes, force: true})
await clear()
await page.click("#results li[aria-selected='true'] .action.trash")
assert.equal((await last("trash"))?.id, "Groceries")
assert.equal(await page.evaluate(() => document.getElementById("switcher").hidden), false)
await page.click("#results li[aria-selected='true'] .action.rename")
await page.waitForFunction(() => document.activeElement.classList.contains("rename"))
assert.equal(await page.evaluate(() => document.activeElement.value), "Groceries")
await press("Escape")
assert.equal(await page.evaluate(() => document.activeElement.id), "query")
await press("Escape")

// The interface size scales the switcher and footer, but not the note's text.
await receive("options", {fontSize: 14, uiScale: 2})
assert.equal(await page.$eval("#query", e => getComputedStyle(e).fontSize), "28px")
assert.equal(await page.$eval("#count", e => getComputedStyle(e).fontSize), "22px")
assert.equal(await page.$eval(".cm-content", e => getComputedStyle(e).fontSize), "14px")
await receive("options", {fontSize: 14, uiScale: 1.5})

// The page reports a height, and the footer counts characters.
await receive("open", {id: "Count", text: "ab\ncd"})
await pause(50)
assert.ok((await last("height"))?.height > 0)
assert.equal(await page.$eval("#count", e => e.textContent), "4 characters")
await receive("status", "Couldn't save")
assert.equal(await page.$eval("#status", e => e.textContent), "Couldn't save")

assert.deepEqual(errors, [])
console.log("smoke test passed")
await browser.close()
