#!/usr/bin/env node
// Typefaces tried in the real client: fetches the faces of each proposal (open licences, from Fontsource) into
// build/font_proposals/<id>/fonts and takes its pictures there with tools/screenshots.mjs, over `--font-dir`: nothing is
// installed on the system, and nothing is sent to the opencode server. Prints what each would add to the program.
//   node tools/font_proposals.mjs [--only id[,id]] [--toolkit folder] [--exe file]
import { spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, statSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs } from 'node:util'

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const { values: opt } = parseArgs({ options: { only: { type: 'string' }, toolkit: { type: 'string' }, exe: { type: 'string' } } })
const only = opt.only ? opt.only.split(',') : null

// ui: the interface; prose: the answers, when it is another family; mono: code, paths and figures.
const PROPOSALS = [
  { id: 'actuel' },
  { id: 'etabli', ui: 'ibm-plex-sans', mono: 'ibm-plex-mono' },
  { id: 'space', ui: 'space-grotesk', mono: 'space-mono' },
  { id: 'chivo', ui: 'chivo', mono: 'chivo-mono' },
  { id: 'lecture', ui: 'hanken-grotesk', prose: 'newsreader', mono: 'dm-mono', monoBold: 500 },
  { id: 'terminal', ui: 'jetbrains-mono', mono: 'jetbrains-mono' },
].filter((p) => !only || only.includes(p.id))

async function face(family, weight, style, file) {
  if (existsSync(file)) return statSync(file).size
  const url = `https://cdn.jsdelivr.net/fontsource/fonts/${family}@latest/latin-${weight}-${style}.ttf`
  const r = await fetch(url)
  if (r.status === 404 && style === 'italic') return 0   // (a family with no italic: the upright one serves)
  if (!r.ok) throw new Error(`${url}: ${r.status}`)
  const data = Buffer.from(await r.arrayBuffer())
  writeFileSync(file, data)
  return data.length
}

for (const p of PROPOSALS) {
  const out = join(repo, 'build', 'font_proposals', p.id)
  const fonts = join(out, 'fonts')
  mkdirSync(fonts, { recursive: true })
  let bytes = 0
  if (p.ui) {
    const roles = [['ui', p.ui], ['mono', p.mono], ...(p.prose ? [['prose', p.prose]] : [])]
    for (const [role, family] of roles) {
      const bold = role === 'mono' ? (p.monoBold ?? 700) : 600
      bytes += await face(family, 400, 'normal', join(fonts, `${role}.ttf`))
      bytes += await face(family, bold, 'normal', join(fonts, `${role}-bold.ttf`))
      if (role !== 'mono') {
        bytes += await face(family, 400, 'italic', join(fonts, `${role}-italic.ttf`))
        bytes += await face(family, bold, 'italic', join(fonts, `${role}-bold-italic.ttf`))
      }
    }
  }
  const args = [join(repo, 'tools', 'screenshots.mjs'), '--out', out, '--only', 'conversation,subagents,settings']
  if (p.ui) args.push('--font-dir', fonts)
  if (opt.toolkit) args.push('--toolkit', opt.toolkit)
  if (opt.exe) args.push('--exe', opt.exe)
  const r = spawnSync(process.execPath, args, { stdio: 'inherit' })
  if (r.status !== 0) process.exit(1)
  console.log(`${p.id}: ${Math.round(bytes / 1024)} KiB of faces (Latin only)`)
}
