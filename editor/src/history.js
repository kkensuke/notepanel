// The history: the open note's earlier versions, over the note, to copy from.
import {versionLabel} from "./logic.js"
import {post, $, element, actionButton, flashCopied} from "./dom.js"
import {view} from "./editor.js"

const historyView = $("history")
const versionList = $("versions")
const versionText = $("version")

// The open note's earlier versions, newest first, to copy from. Nothing here changes the note.
let versions = []
let chosen = 0

export const isHistoryOpen = () => !historyView.hidden

export function openHistory(list) {
  versions = list
  chosen = 0
  historyView.hidden = false
  renderHistory()
  historyView.focus()
  post("historyShown", {shown: true})
}

// Swift colors the history button while the history is open, and Escape closes it here alone.
export function closeHistory() {
  if (!isHistoryOpen()) return
  historyView.hidden = true
  view.focus()
  post("historyShown", {shown: false})
}

function renderHistory() {
  const now = new Date()
  const items = versions.map((version, index) => versionRow(version, index, now))
  versionList.replaceChildren(...(items.length ? items : [element("li", "empty", "No earlier versions")]))
  versionText.textContent = versions[chosen]?.text ?? ""
  versionText.scrollTop = 0
  const active = items[chosen]
  if (active) historyView.setAttribute("aria-activedescendant", active.id)
  else historyView.removeAttribute("aria-activedescendant")
  active?.scrollIntoView({block: "nearest"})
}

function versionRow(version, index, now) {
  const item = document.createElement("li")
  item.id = `version-${index}`
  item.setAttribute("role", "option")
  item.setAttribute("aria-selected", String(index === chosen))
  const actions = element("span", "actions", "")
  actions.append(actionButton("copy", "Copy This Version (↩)", () => copyVersion(index)))
  item.append(element("span", "title", versionLabel(new Date(version.date), now)), actions)
  item.addEventListener("mousedown", event => {
    event.preventDefault()
    chosen = index
    renderHistory()
  })
  return item
}

// The row's button shows a tick for a moment, as the link popup's Copy button does.
function copyVersion(index) {
  const version = versions[index]
  if (!version) return
  post("copy", {text: version.text})
  const button = versionList.children[index]?.querySelector(".action.copy")
  if (button) flashCopied(button)
}

function chooseVersion(index) {
  chosen = Math.max(0, Math.min(index, versions.length - 1))
  renderHistory()
}

// ⌘C copies what's selected in the version, as anywhere on the page.
historyView.addEventListener("keydown", event => {
  const plain = !event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey
  const command = event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey
  let handled = true
  if (plain && event.key === "ArrowDown") chooseVersion(chosen + 1)
  else if (plain && event.key === "ArrowUp") chooseVersion(chosen - 1)
  else if (plain && event.key === "Enter") copyVersion(chosen)
  else if (plain && event.key === "Escape") closeHistory()
  // Only the version, not the list too.
  else if (command && event.key.toLowerCase() === "a") getSelection().selectAllChildren(versionText)
  // Focus stays here: Shift-Tab would reach the hidden note, and typing would change it.
  else if (event.key === "Tab") {}
  else handled = false
  if (handled) event.preventDefault()
})

export function focusHistory() {
  historyView.focus()
}
