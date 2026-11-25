// Builds ../web/editor.js, copies KaTeX to ../web/katex, and writes ../web/THIRD_PARTY_LICENSES.txt
// from the packages that go into the two.
import {build} from "esbuild"
import {cpSync, readFileSync, readdirSync, writeFileSync} from "node:fs"

const outfile = "../web/editor.js"

const {metafile} = await build({
  entryPoints: ["src/main.js"],
  bundle: true,
  minify: true,
  format: "iife",
  target: "safari17",
  outfile,
  metafile: true,
  logLevel: "info",
})

// KaTeX isn't in editor.js: the page loads it from ../web/katex when a note first shows math.
// Its styles offer each font as woff2, woff and ttf. The app's web view takes the first, woff2,
// so the other two stay out.
const katex = "node_modules/katex"
for (const file of ["katex.min.js", "katex.min.css"]) cpSync(`${katex}/dist/${file}`, `../web/katex/${file}`)
cpSync(`${katex}/dist/fonts`, "../web/katex/fonts", {recursive: true, filter: path => !/\.(woff|ttf)$/.test(path)})

// The output's inputs leave out packages tree-shaking removed. The innermost node_modules entry
// is the package, so a nested copy gets its own notice.
const dirs = new Set(Object.keys(metafile.outputs[outfile].inputs)
  .map(path => path.match(/^(.*node_modules\/(?:@[^/]+\/)?[^/]+)\//)?.[1])
  .filter(Boolean)
  .concat(katex))
const notices = [...dirs].sort().map(dir => {
  const {name, version} = JSON.parse(readFileSync(`${dir}/package.json`, "utf8"))
  const file = readdirSync(dir).find(f => /^licen[cs]e/i.test(f))
  if (!file) throw new Error(`${name} has no license file, so its notice cannot be included`)
  return `${name} ${version}\n\n${readFileSync(`${dir}/${file}`, "utf8").trim()}\n`
})
writeFileSync("../web/THIRD_PARTY_LICENSES.txt",
  "The editor of notepanel comes with the packages below: KaTeX in katex/, and the others bundled " +
  "into editor.js. Their licenses follow.\n\n" +
  notices.join(`\n${"-".repeat(72)}\n\n`))
