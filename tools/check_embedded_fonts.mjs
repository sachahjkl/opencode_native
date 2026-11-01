#!/usr/bin/env node
// Checks that a build of the client holds every font of assets/fonts, byte for byte. Exit code 1 if one is missing.
//   node tools/check_embedded_fonts.mjs <program>
import { readdirSync, readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const program = process.argv[2]
if (!program) { console.error('usage: node tools/check_embedded_fonts.mjs <program>'); process.exit(2) }
const bytes = readFileSync(program)
const fonts = join(repo, 'assets', 'fonts')
let missing = 0
for (const name of readdirSync(fonts).filter((f) => f.endsWith('.ttf'))) {
  const face = readFileSync(join(fonts, name))
  const at = bytes.indexOf(face)
  console.log(`${at >= 0 ? 'ok     ' : 'MISSING'} ${name} (${Math.round(face.length / 1024)} KiB)`)
  if (at < 0) missing++
}
process.exit(missing ? 1 : 0)
