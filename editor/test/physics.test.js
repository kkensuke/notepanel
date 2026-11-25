import {test} from "node:test"
import assert from "node:assert/strict"
import katex from "katex"
import {physicsMacros} from "../src/physics.js"

const mathML = tex => katex.renderToString(tex, {output: "mathml", macros: {...physicsMacros}})
// What KaTeX shows for `tex`, as text: the symbols in reading order, with one kind of bar.
const shown = tex =>
  mathML(tex)
    .replace(/<annotation[^]*<\/annotation>/, "")
    .replace(/<[^>]+>/g, "")
    .replace(/&#x([0-9a-f]+);/gi, (_, code) => String.fromCodePoint(parseInt(code, 16)))
    .replace(/∣/g, "|")
    .replace(/[\s⁡-⁤]/g, "")

test("the physics macros show what LaTeX's physics package does", () => {
  const cases = String.raw`
    \expval{A}                      ⟨A⟩
    \expval{A}{\psi}                ⟨ψ|A|ψ⟩
    \ev{\alpha x} {\beta y}         ⟨βy|αx|βy⟩
    \expval{\comm{A}{B}}{\psi}      ⟨ψ|[A,B]|ψ⟩
    \braket{a}{b}                   ⟨a|b⟩
    \braket{a}                      ⟨a|a⟩
    \braket{\phi|\psi}              ⟨ϕ|ψ⟩
    \ip{a}{b}                       ⟨a|b⟩
    \bra{\phi}\ket{\psi}            ⟨ϕ|ψ⟩
    \bra{\phi}U\ket*{\psi}          ⟨ϕ|U|ψ⟩
    \dyad{0}                        |0⟩⟨0|
    \ketbra{\psi}{\phi}             |ψ⟩⟨ϕ|
    \mel{\phi}{H}{\psi}             ⟨ϕ|H|ψ⟩
    \comm{A}{B}\acomm{A}{B}\pb{q}{p}  [A,B]{A,B}{q,p}
    \qty(\frac{a}{b})               (ab)
    \qty(f(x)+g(y))                 (f(x)+g(y))
    \qty[x]\qty{y}\qty|z|\qty*(w)   [x]{y}|z|(w)
    \pqty{a}\bqty{b}\Bqty{c}\vqty{d}  (a)[b]{c}|d|
    \abs{x}\abs*{y}                 |x||y|
    \norm{v}_2                      ∥v∥2
    \eval{x^2}_0^1                  x2|01
    \order{x^2}                     O(x2)
    \dd x\dd{y}\dd[3]{z}            dxdyd3z
    \dv{f}{x}                       dfdx
    \dv{x}                          ddx
    \dv[2]{f}{t}                    d2fdt2
    \dv*{f}{x}                      df/dx
    \pdv{f}{x}                      ∂f∂x
    \pdv[n+1]{f}{x}                 ∂n+1f∂xn+1
    \pdv{f}{x}{y}                   ∂2f∂x∂y
    \fdv{F}{\phi}                   δFδϕ
    \Tr(\rho)\tr\rho\rank A         Tr(ρ)trρrankA
    \Re z+\Im z                     Rez+Imz
    \grad f                         ∇f
    \divergence\vb{E}               ∇⋅E
    \curl\vb{B}                     ∇×B
    \laplacian\phi                  ∇2ϕ
    \vb{a}\vdot\vb{b}\cross\vb{c}   a⋅b×c
    x\qq{so}y\qif z\qc w            xsoyifz,w
    a\div b                         a÷b
  `
  for (const line of cases.trim().split("\n")) {
    const [tex, text] = line.trim().split(/\s{2,}/)
    assert.equal(shown(tex), text, tex)
  }
})

test("the physics macros size brackets unless starred, and set vectors in bold", () => {
  assert.match(mathML(String.raw`\abs{\frac{a}{b}}`), /fence="true"/)
  assert.match(mathML(String.raw`\abs*{\frac{a}{b}}`), /stretchy="false"/)
  assert.match(mathML(String.raw`\braket{\frac{a}{b}}{c}`), /fence="true"/)
  assert.match(mathML(String.raw`\vb{a}`), /mathvariant="bold"/)
  assert.match(mathML(String.raw`\vb*{\theta}`), /mathvariant="bold-italic"/)
  assert.match(mathML(String.raw`\va{a}`), /mathvariant="bold"/)
  assert.throws(() => mathML(String.raw`\qty(a`), /no closing \)/)
})
