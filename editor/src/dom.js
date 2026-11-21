// What every part of the page uses: talking to Swift, finding elements and making them, and the
// icons and buttons drawn with the text color.

// Outside the app (in a plain browser) there is no handler, so nothing is sent.
export const post = (type, data = {}) => window.webkit?.messageHandlers?.native?.postMessage({type, ...data})

export const $ = id => document.getElementById(id)

export function element(tag, className, text) {
  const node = document.createElement(tag)
  node.className = className
  node.textContent = text
  return node
}

// An element holding `text`, with the ranges a search matched marked.
export function marked(tag, className, text, ranges) {
  const node = element(tag, className, "")
  let end = 0
  for (const [from, to] of ranges) {
    node.append(text.slice(end, from), element("mark", "", text.slice(from, to)))
    end = to
  }
  node.append(text.slice(end))
  return node
}

// Line icons drawn with the text color; a pinned note's pin is filled.
const icons = {
  pin: '<path d="M9 3.5h6M10 3.5v5.2l-3.2 3.1c-.4.4-.1 1.2.5 1.2h9.4c.6 0 .9-.8.5-1.2L14 8.7V3.5Z"/><path d="M12 13v8"/>',
  copy: '<rect x="8.5" y="8.5" width="11" height="11" rx="2"/><path d="M15.5 8.5v-2a2 2 0 0 0-2-2h-7a2 2 0 0 0-2 2v7a2 2 0 0 0 2 2h2"/>',
  open: '<path d="M14 4.5h5.5V10M19.5 4.5 11 13M17.5 13.5v4a2 2 0 0 1-2 2h-9a2 2 0 0 1-2-2v-9a2 2 0 0 1 2-2h4"/>',
  check: '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
  trash: '<path d="M4.5 6.5h15M9.5 6.5V5.3c0-1 .8-1.8 1.8-1.8h1.4c1 0 1.8.8 1.8 1.8v1.2M6.5 6.5l.9 12.2a2 2 0 0 0 2 1.8h5.2a2 2 0 0 0 2-1.8l.9-12.2M10.2 10v6.5M13.8 10v6.5"/>',
}

export const iconSVG = name => `<svg viewBox="0 0 24 24" aria-hidden="true">${icons[name]}</svg>`

export function actionButton(name, label, onClick, pressed) {
  const button = document.createElement("button")
  button.className = `action ${name}`
  button.title = label
  button.setAttribute("aria-label", label)
  if (pressed !== undefined) button.setAttribute("aria-pressed", String(pressed))
  button.innerHTML = iconSVG(name)
  // Pressing a button must not take focus from the search field or open the row.
  button.addEventListener("mousedown", event => {
    event.preventDefault()
    event.stopPropagation()
  })
  button.addEventListener("click", event => {
    event.stopPropagation()
    onClick()
  })
  return button
}
