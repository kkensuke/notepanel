// Macros for KaTeX that work as the commands of LaTeX's physics package do, so math written for
// LaTeX with it shows the same here. A star turns off the sizing of brackets to what's in them, as
// in physics. Not here: the long names (\commutator for \comm), matrices (\mqty), the brackets
// physics sizes after \sin and the like, and \div for the divergence, which stays ÷; the
// divergence is \divergence.

// TeX for tokens as KaTeX hands them over, last first. KaTeX drops the space after a command, so
// one goes back where a letter follows, or "\alpha x" would come out as "\alphax".
function source(tokens) {
  let text = ""
  for (const token of tokens.toReversed()) {
    if (/\\[a-zA-Z@]+$/.test(text) && /^[a-zA-Z@]/.test(token.text)) text += " "
    text += token.text
  }
  return text
}

// The token after any spaces, left where it is.
function next(context) {
  context.consumeSpaces()
  return context.future().text
}

function star(context) {
  if (next(context) !== "*") return false
  context.popToken()
  return true
}

const argument = context => `{${source(context.consumeArg().tokens)}}`
// An argument in braces if one follows, or null.
const more = context => (next(context) === "{" ? argument(context) : null)

// "[…]" if it follows, in braces, or null.
function optional(context) {
  if (next(context) !== "[") return null
  context.popToken()
  return `{${source(context.consumeArg(["]"]).tokens)}}`
}

// The TeX up to the `close` that pairs with an `open` already read, as in "\qty( f(x) )".
function upTo(context, open, close) {
  const tokens = []
  for (let depth = 0; ; ) {
    const token = context.popToken()
    if (token.text === "EOF") throw new Error(`\\qty has no closing ${close}`)
    if (token.text === close) {
      if (depth === 0) return source(tokens)
      depth--
    } else if (token.text === open) depth++
    tokens.unshift(token)
  }
}

// `parts` between `left` and `right` with a bar between them, all sized to the parts if `sized`.
const pair = (sized, left, right, ...parts) =>
  sized ? `\\left${left}${parts.join("\\middle\\vert ")}\\right${right}` : left + parts.join("\\vert ") + right
const angles = (sized, ...parts) => pair(sized, "\\langle ", "\\rangle ", ...parts)
// A command of one argument, as \abs, and one of two with a comma between them, as \comm.
const around = (left, right) => context => pair(!star(context), left, right, "{#1}")
const listed = (left, right) => context =>
  pair(!star(context), left, right, `${argument(context)},${argument(context)}`)

// \dv{f}{x}, \dv{x} for d/dx, \dv[n]{f}{x}, and \pdv{f}{x}{y} for a mixed one. A star gives df/dx.
const derivative = d => context => {
  const slash = star(context)
  const order = optional(context)
  const power = order ? `^${order}` : ""
  const first = argument(context)
  const rest = []
  for (let variable; (variable = more(context)); ) rest.push(variable)
  let top = d + power + first
  let bottom = rest.map(variable => d + variable).join("") + power
  if (!rest.length) [top, bottom] = [d + power, d + first + power]
  else if (rest.length > 1) top = `${d}^{${rest.length}}${first}`
  return slash ? `${top}/${bottom}` : `\\frac{${top}}{${bottom}}`
}

const words = "if then else otherwise unless given using assume since let for all even odd integer and or as in"

export const physicsMacros = {
  // Brackets.
  "\\qty"(context) {
    const sized = !star(context)
    const open = next(context)
    if (open === "{") return pair(sized, "\\{", "\\}", argument(context))
    const close = {"(": ")", "[": "]", "|": "|"}[open]
    if (!close) throw new Error("\\qty needs ( [ { or | after it")
    context.popToken()
    const inside = `{${upTo(context, open, close)}}`
    return open === "|" ? pair(sized, "\\vert ", "\\vert ", inside) : pair(sized, open, close, inside)
  },
  "\\pqty": around("(", ")"),
  "\\bqty": around("[", "]"),
  "\\Bqty": around("\\{", "\\}"),
  "\\vqty": around("\\vert ", "\\vert "),
  "\\abs": around("\\lvert ", "\\rvert "),
  "\\norm": around("\\lVert ", "\\rVert "),
  "\\eval": context => (star(context) ? "{#1}\\vert " : "\\left.{#1}\\right\\vert "),
  "\\order": context => `\\mathcal{O}${pair(!star(context), "(", ")", "{#1}")}`,
  "\\comm": listed("[", "]"),
  "\\acomm": listed("\\{", "\\}"),
  "\\pb": listed("\\{", "\\}"),

  // Dirac's notation.
  "\\ket": context => (star(context) ? "\\vert{#1}\\rangle " : "\\left\\vert{#1}\\right\\rangle "),
  "\\bra"(context) {
    const sized = !star(context)
    const bra = argument(context)
    if (next(context) !== "\\ket") return sized ? `\\left\\langle ${bra}\\right\\vert ` : `\\langle ${bra}\\vert `
    // \bra{a}\ket{b} is one bracket.
    context.popToken()
    star(context)
    return angles(sized, bra, argument(context))
  },
  "\\braket"(context) {
    const sized = !star(context)
    const bra = argument(context)
    const ket = more(context)
    // \braket{a|b} is the braket package's, which KaTeX reads this way.
    if (!ket && bra.includes("|")) return `\\mathinner{\\langle ${bra}\\rangle}`
    return angles(sized, bra, ket ?? bra)
  },
  "\\ip": "\\braket",
  "\\dyad"(context) {
    const sized = !star(context)
    const ket = argument(context)
    const bra = more(context) ?? ket
    return sized
      ? `\\left\\vert ${ket}\\middle\\rangle\\!\\middle\\langle ${bra}\\right\\vert `
      : `\\vert ${ket}\\rangle\\!\\langle ${bra}\\vert `
  },
  "\\ketbra": "\\dyad",
  "\\op": "\\dyad",
  "\\expval"(context) {
    const sized = !star(context)
    const operator = argument(context)
    const state = more(context)
    return state ? angles(sized, state, operator, state) : angles(sized, operator)
  },
  "\\ev": "\\expval",
  "\\mel": context => angles(!star(context), argument(context), argument(context), argument(context)),
  "\\matrixel": "\\mel",

  // Derivatives.
  "\\dd"(context) {
    const order = optional(context)
    return `\\mathop{}\\!\\mathrm{d}${order ? `^${order}` : ""}${more(context) ?? ""}`
  },
  "\\dv": derivative("\\mathrm{d}"),
  "\\pdv": derivative("\\partial "),
  "\\fdv": derivative("\\delta "),

  // Operators.
  "\\Tr": "\\operatorname{Tr}",
  "\\tr": "\\operatorname{tr}",
  "\\rank": "\\operatorname{rank}",
  "\\erf": "\\operatorname{erf}",
  "\\Res": "\\operatorname{Res}",
  "\\Re": "\\operatorname{Re}",
  "\\Im": "\\operatorname{Im}",

  // Vectors: upright bold, or with a star italic bold, which Greek letters need.
  "\\vb": context => (star(context) ? "\\boldsymbol{#1}" : "\\mathbf{#1}"),
  "\\va": context => (star(context) ? "\\vec{\\boldsymbol{#1}}" : "\\vec{\\mathbf{#1}}"),
  "\\vu": context => (star(context) ? "\\hat{\\boldsymbol{#1}}" : "\\hat{\\mathbf{#1}}"),
  "\\vdot": "\\mathbin{\\boldsymbol\\cdot}",
  "\\cross": "\\mathbin{\\boldsymbol\\times}",
  "\\grad": "\\boldsymbol\\nabla ",
  "\\divergence": "\\boldsymbol\\nabla\\vdot ",
  "\\curl": "\\boldsymbol\\nabla\\cross ",
  "\\laplacian": "\\nabla^2 ",

  // Words with a quad on each side: \qq{…}, and \qif, \qand and the rest.
  "\\qq": "\\quad\\text{#1}\\quad ",
  "\\qc": ",\\quad ",
  "\\qcc": "\\quad\\text{c.c.}\\quad ",
  ...Object.fromEntries(words.split(" ").map(word => [`\\q${word}`, `\\quad\\text{${word}}\\quad `])),
}
