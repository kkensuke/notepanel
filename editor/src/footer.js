// The footer: the message and the character count, over the note's last lines.
import {$} from "./dom.js"

const editorElement = $("editor")
const footer = $("footer")
export const statusElement = $("status")
export const countElement = $("count")
// Kept up to date as the footer changes size.
export let footerHeight = 0

// The footer lies over the note's last lines. Its height and the boxes of its texts, with room for
// the note to fade out, go to style.css, which hides the note only behind those texts.
const room = 12
const footerObserver = new ResizeObserver(() => {
  footerHeight = footer.offsetHeight
  const {style} = editorElement
  style.setProperty("--footer-height", `${footerHeight}px`)
  const status = statusElement.offsetWidth && statusElement.offsetLeft + statusElement.offsetWidth + room
  style.setProperty("--status-width", `${status}px`)
  style.setProperty("--count-width", `${footer.clientWidth - countElement.offsetLeft + room}px`)
})
for (const element of [footer, statusElement, countElement]) footerObserver.observe(element)
