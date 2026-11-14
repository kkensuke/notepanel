// Builds ../web/editor.js, and ../web/THIRD_PARTY_LICENSES.txt from the packages bundled into it.
import {build} from "esbuild"
import {readFileSync, readdirSync, writeFileSync} from "node:fs"

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

// The output's inputs leave out packages tree-shaking removed. The innermost node_modules entry
// is the package, so a nested copy gets its own notice.
const dirs = new Set(Object.keys(metafile.outputs[outfile].inputs)
  .map(path => path.match(/^(.*node_modules\/(?:@[^/]+\/)?[^/]+)\//)?.[1])
  .filter(Boolean))
const notices = [...dirs].sort().map(dir => {
  const {name, version} = JSON.parse(readFileSync(`${dir}/package.json`, "utf8"))
  const file = readdirSync(dir).find(f => /^licen[cs]e/i.test(f))
  if (!file) throw new Error(`${name} has no license file, so its notice cannot be included`)
  return `${name} ${version}\n\n${readFileSync(`${dir}/${file}`, "utf8").trim()}\n`
})
writeFileSync("../web/THIRD_PARTY_LICENSES.txt",
  "editor.js, the editor of notepanel, bundles the packages below. Their licenses follow.\n\n" +
  notices.join(`\n${"-".repeat(72)}\n\n`))
