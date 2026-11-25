// The math the cursor or the pointer is in, typeset by KaTeX in a popup under it. The note itself
// stays as written.
import {StateField, StateEffect} from "@codemirror/state"
import {hoverTooltip, showTooltip, repositionTooltips, ViewPlugin} from "@codemirror/view"
import {mathAt, linkAt} from "./logic.js"
import {physicsMacros} from "./physics.js"

// KaTeX is as big as the rest of the page, so it's a file of its own beside the page's, loaded
// when a note first shows math: its script, which sets window.katex, and its styles and fonts.
let loading
function loadKaTeX() {
  return (loading ??= new Promise(resolve => {
    const styles = document.createElement("link")
    styles.rel = "stylesheet"
    styles.href = "katex/katex.min.css"
    const script = document.createElement("script")
    script.src = "katex/katex.min.js"
    script.onload = resolve
    document.head.append(styles, script)
  }))
}

// What KaTeX gets besides the math. \label names an equation for LaTeX's references and shows
// nothing; equations pasted from LaTeX have it, and KaTeX doesn't know it.
const macros = {
  ...physicsMacros,
  "\\label"(context) {
    context.consumeArg()
    return ""
  },
}

// A popup of `math` typeset, under its last row, or over its first where there's no room under.
function popup(math, className = "cm-math") {
  return {
    pos: math.from,
    end: math.to,
    math,
    create(view) {
      const dom = document.createElement("div")
      dom.className = className
      // A click on the popup leaves the focus in the note.
      dom.addEventListener("mousedown", event => event.preventDefault())
      loadKaTeX().then(() => {
        try {
          // A copy of the macros, since KaTeX adds what the math defines with \gdef to them.
          window.katex.render(math.tex, dom, {displayMode: math.display, macros: {...macros}})
        } catch (error) {
          // What KaTeX couldn't read, and where.
          dom.textContent = error.message
          dom.classList.add("cm-math-error")
        }
        // The popup has its size only now.
        repositionTooltips(view)
      })
      return {
        dom,
        getCoords() {
          const start = view.coordsAtPos(math.from, 1)
          const end = view.coordsAtPos(math.to, -1)
          return start && end && {left: start.left, right: start.left, top: start.top, bottom: end.bottom}
        },
      }
    },
  }
}

// The popup of the math the cursor is in or next to. It's the same popup while the cursor moves
// in the math, and a new one when the math is written in.
function atCursor(state, shown) {
  const math = mathAt(state, state.selection.main.head)
  if (!math) return null
  const same = shown && math.from === shown.math.from && math.to === shown.math.to && math.tex === shown.math.tex
  return same ? shown : popup(math, "cm-math cm-math-cursor")
}
const cursorMath = StateField.define({
  create: state => atCursor(state),
  update: (shown, {state, docChanged, selection}) => (docChanged || selection ? atCursor(state, shown) : shown),
  provide: field => showTooltip.from(field),
})

// Whether the cursor's popup shows `math`.
const shownAtCursor = (view, math) => view.hasFocus && view.state.field(cursorMath)?.pos === math.from

// Pointing at math in a line shows it at once, as pointing at a link shows its buttons; 1, since
// CodeMirror reads 0 as its default of 300 ms. Not in a link's text: CodeMirror puts the link's
// buttons and the math in one box, which then sits in neither's place.
const lineMath = hoverTooltip(
  (view, pos) => {
    const math = mathAt(view.state, pos)
    const line = view.state.doc.lineAt(pos)
    if (!math || math.display || shownAtCursor(view, math) || linkAt(line.text, pos - line.from)) return null
    return popup(math)
  },
  {hoverTime: 1, hideOnChange: true},
)

// Pointing at any line of a display, past its end too, shows it at once, as pointing at a code
// block shows its Copy button: a popup of its own, which the pointer can move onto.
const pointAt = StateEffect.define()
const displayMath = StateField.define({
  create: () => null,
  update(shown, transaction) {
    for (const effect of transaction.effects) if (effect.is(pointAt)) return effect.value
    return transaction.docChanged || transaction.selection ? null : shown
  },
  provide: field => showTooltip.from(field),
})
const displayPointer = ViewPlugin.define(view => {
  // The line the pointer was last on, so the note is read again only when it goes to another.
  let line = 0
  const point = math => {
    if (view.state.field(displayMath)?.pos === math?.from) return
    view.dispatch({effects: pointAt.of(math && popup(math))})
  }
  const move = event => {
    if (event.target.closest?.(".cm-math")) return
    const pos = view.posAtCoords({x: event.clientX, y: event.clientY})
    const at = pos === null ? 0 : view.state.doc.lineAt(pos).number
    if (at === line) return
    line = at
    const math = pos === null ? null : mathAt(view.state, pos)
    point(math?.display && !shownAtCursor(view, math) ? math : null)
  }
  const leave = () => {
    line = 0
    point(null)
  }
  view.dom.addEventListener("mousemove", move)
  view.dom.addEventListener("mouseleave", leave)
  return {
    update(update) {
      if (update.docChanged || update.selectionSet) line = 0
    },
    destroy() {
      view.dom.removeEventListener("mousemove", move)
      view.dom.removeEventListener("mouseleave", leave)
    },
  }
})

export const math = [cursorMath, lineMath, displayMath, displayPointer]
