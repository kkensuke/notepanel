// The editor page: CodeMirror 6 for the note (editor.js), with the note's history over it
// (history.js). The same page, told it's the switcher's, is the note switcher (switcher.js), in a
// window of its own at the panel's left. Swift calls `receive(message)`; the page answers with
// `post(type, data)`.
import {post} from "./dom.js"
import {statusElement} from "./footer.js"
import {view, openNote, renameNote, forgetNote, land, markMatches, applyOptions, updateCount} from "./editor.js"
import {
  isSwitcherOpen,
  showSwitcher,
  closeSwitcher,
  chooseNote,
  renameInList,
  setNotes,
  focusSwitcher,
  lineFeeds,
} from "./switcher.js"
import {isHistoryOpen, openHistory, closeHistory, focusHistory} from "./history.js"

window.receive = ({type, data}) => {
  switch (type) {
    case "open":
      openNote(data.id, data.text, data.opening)
      // Its versions are another note's.
      closeHistory()
      updateCount()
      // A note the switcher asked for opens at the match its row is for.
      if (data.land) land(data.land)
      break
    case "marks":
      // What's typed in the switcher, found in this note as it's typed. Nothing, as the switcher
      // closes.
      markMatches(data)
      break
    case "side":
      // This page is the switcher's, in its own window.
      document.body.classList.add("side")
      break
    case "close":
      closeSwitcher()
      break
    case "current":
      chooseNote(data)
      break
    case "renamed":
      renameNote(data.from, data.to)
      renameInList(data.from, data.to)
      break
    case "trashed":
      forgetNote(data)
      break
    case "switcher":
      showSwitcher(lineFeeds(data.notes), data)
      break
    case "notes":
      setNotes(data)
      break
    case "history":
      if (isHistoryOpen()) closeHistory()
      else openHistory(data.versions)
      break
    case "focus":
      // Back where it was: in the switcher, the list or the search field, and in the note's page,
      // the history if it's open, or else the note.
      if (isSwitcherOpen()) focusSwitcher()
      else if (isHistoryOpen()) focusHistory()
      else view.focus()
      break
    case "options":
      applyOptions(data)
      break
    case "status":
      statusElement.textContent = data
      // The footer is hidden while the history covers the note, so a message closes it: it may
      // say why what was done there did nothing.
      if (data) closeHistory()
      break
  }
}

applyOptions({})
updateCount()
post("ready")
