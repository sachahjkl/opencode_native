#!/usr/bin/env node
// Regenerates docs/screenshots/*.png, and the copies of them in site/img, over the Chrome DevTools Protocol: the pictures
// are the frames the client rendered, so the mouse, the keyboard and the windows in front are left alone. It runs with an
// empty settings folder and reads the demo session of the local opencode server; nothing is sent to it but the shell of the
// terminal's picture, closed right after.
//   node tools/screenshots.mjs [--build] [--only name[,name]] [--exe file] [--session id] [--toolkit folder]
//     --build     builds build/screenshots(.exe) first
//     --only      just these pictures
//     --exe       the client to run (default build/screenshots(.exe))
//     --session   the session to show (only ever one made for pictures: they are published)
//     --work-session  the one that edits a file and keeps a todo list (made for pictures too)
//     --toolkit   where gui_toolkit is (default ext/gui_toolkit, for tools/cdp.mjs and the build)
//     --out       write there instead, the site untouched
//     --font-dir  try these faces (src/main.odin: fonts_from_dir)
//     --linux     just linux.png: this Linux build of the client, run in WSL (tools/wsl_client.sh), Windows only
//     --linux-build  the same from this tree, built in WSL with the flake (tools/wsl_build.sh): no release needed
import { spawn, spawnSync } from 'node:child_process'
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, openSync, readFileSync, rmSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs } from 'node:util'

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const { values: opt } = parseArgs({ options: {
  build: { type: 'boolean' }, only: { type: 'string' }, exe: { type: 'string' },
  session: { type: 'string', default: 'ses_e7633e562ffeJfyNPycNzsVrb1' },
  'work-session': { type: 'string', default: 'ses_e5584daa0ffe0rZ9lqsYByWGPw' },
  toolkit: { type: 'string', default: join(repo, 'ext', 'gui_toolkit') },
  linux: { type: 'string' }, 'linux-build': { type: 'boolean' },
  out: { type: 'string' }, 'font-dir': { type: 'string' },
} })
const windows = process.platform === 'win32'
const only = opt.only ? opt.only.split(',') : null
const toolkit = resolve(repo, opt.toolkit)
if (opt['linux-build']) {
  const script = spawnSync('wsl.exe', ['--exec', 'wslpath', '-a', join(repo, 'tools', 'wsl_build.sh').replaceAll('\\', '/')], { encoding: 'utf8' }).stdout.trim()
  const r = spawnSync('wsl.exe', ['--exec', 'bash', '-l', script], { encoding: 'utf8', maxBuffer: 1 << 26 })
  const built = (r.stdout ?? '').trim().split('\n').at(-1)
  if (r.status !== 0 || !built.startsWith('/')) { console.error((r.stdout ?? '').slice(-2000), (r.stderr ?? '').slice(-2000)); process.exit(1) }
  opt.linux = built
}
const wslPath = (f) => spawnSync('wsl.exe', ['--exec', 'wslpath', '-a', f.replaceAll('\\', '/')], { encoding: 'utf8' }).stdout.trim()
const exe = opt.exe ? resolve(opt.exe) : join(repo, 'build', 'screenshots' + (windows ? '.exe' : ''))
const docs = opt.out ? resolve(opt.out) : join(repo, 'docs', 'screenshots')
mkdirSync(docs, { recursive: true })
const PORT = 9391
const SIZE = '1460x920'   // window pixels, whichever screen it opens on
// (grey text: the colours of the stripes belong to a screen, and a picture is seen on others, scaled)
const COMMON = ['--pref', 'appearance.accent=peach', '--pref', 'appearance.text_smoothing=grey', '--pref', 'appearance.zoom=1', '--scale=1.25', `--size=${SIZE}`, ...(opt['font-dir'] ? [`--font-dir=${resolve(opt['font-dir'])}`] : [])]
const SESSION = [`--session=${opt.session}`, '--search=Tour']
const WORK_TITLE = 'Python clock'   // what the sidebar's search leaves of the sessions, and shows once they are read
const WORK = [`--session=${opt['work-session']}`, `--search=${WORK_TITLE}`]

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const cdp = (...cmd) => {
  const r = spawnSync(process.execPath, [join(toolkit, 'tools', 'cdp.mjs'), '--port', String(PORT), ...cmd], { encoding: 'utf8' })
  return { ok: r.status === 0, out: r.stdout ?? '', err: r.stderr ?? '' }
}
const must = (...cmd) => {
  const r = cdp(...cmd)
  if (!r.ok) throw new Error(`cdp ${cmd.join(' ')}: ${r.err || r.out}`)
  return r.out
}

// The first box whose text holds `text`: where it is, in CSS pixels (null: not built, it is far from the view).
function top(text) {
  const m = must('find', text).match(/@(-?[\d.]+),(-?[\d.]+)/)
  return m ? Number(m[2]) : null
}

// A press and a release on the n-th box whose text is exactly `text` (`click` matches any text holding it, in any case).
function clickExact(text, n) {
  const boxes = [...must('find', text).matchAll(/"([^"]*)" @(-?[\d.]+),(-?[\d.]+) ([\d.]+)x([\d.]+)/g)].filter((m) => m[1] === text)
  const b = boxes[n]
  if (!b) throw new Error(`no box ${n} reading ${text}`)
  const x = String(Number(b[2]) + Number(b[4]) / 2), y = String(Number(b[3]) + Number(b[5]) / 2)
  must('move', x, y)
  must('down', x, y)
  must('up', x, y)
}

// A place in the window as parts of it, in CSS pixels: how many a window of SIZE holds depends on the screen's scale.
function at(x, y) {
  const { width, height } = JSON.parse(must('state'))
  return [String(Math.round(width * x)), String(Math.round(height * y))]
}

// The conversation scrolled until `text` is near `y` (as a part of the window's height).
async function scrollTo(text, y) {
  const { height } = JSON.parse(must('state'))
  const [wx, wy] = at(0.65, 0.4)
  for (let i = 0; i < 40; i++) {
    const t = top(text)
    if (t === null) { must('wheel', wx, wy, '-5'); must('idle'); continue }   // (a lazy column: it is further up, what a conversation opened at its end has above)
    const d = t - y * height
    if (Math.abs(d) < height * 0.06) return
    must('wheel', wx, wy, String(Math.sign(d) * Math.max(1, Math.min(10, Math.round(Math.abs(d) / 120)))))
    must('idle')
  }
  throw new Error(`could not bring into view: ${text}`)
}

// The composer on a model anybody has, whatever this server's default is (chosen here, nothing is sent: it goes with a prompt).
function publicModel() {
  must('click', '--name', 'model')
  must('idle')
  must('type', 'deepseek')
  must('idle')
  must('key', 'Enter')
  must('idle')
}

// What each picture shows: the arguments, then what is done before the picture.
const SHOTS = [
  { name: 'conversation', args: SESSION },
  { name: 'subagents', args: SESSION, go: () => scrollTo('Yes, but first launch', 0.2) },
  { name: 'find', args: [...SESSION, '--find=http'], go: () => {   // the last match, in view: the picture shows the current one
    must('key', 'shift+Enter')
    must('idle')
  } },
  { name: 'picker', args: SESSION, go: async () => {
    must('click', '--name', 'model')
    must('idle')
    must('type', 'sonnet')
    must('idle')
  } },
  { name: 'statistics', args: [...SESSION, '--stats'] },
  // (commands only: `>` keeps the sessions of whoever takes the picture out of it)
  { name: 'palette', args: SESSION, go: async () => {
    must('key', 'ctrl+k')
    must('idle')
    must('type', '>')
    must('idle')
  } },
  { name: 'diff', args: WORK, wait: WORK_TITLE, go: async () => { publicModel(); await scrollTo('argparse', 0.25) } },
  { name: 'activity', args: WORK, wait: WORK_TITLE, go: async () => {
    publicModel()
    must('key', 'ctrl+j')
    must('wait', '700')
    must('idle')
  } },
  // (in the demo's folder, the shell closed once taken: `after`)
  { name: 'terminal', args: WORK, wait: WORK_TITLE, go: async () => {
    must('key', 'ctrl+shift+t')
    must('wait', '3000')
    publicModel()
    must('click', '--name', 'term_box')
    must('type', 'Get-ChildItem | Select-Object Name, Length; Write-Host "ready" -ForegroundColor Green')
    must('key', 'Enter')
    must('wait', '2000')
  }, after: () => { must('click', '--name', 'term_x0'); must('wait', '800') } },   // (its request is on its way when the client ends)
  { name: 'mention', args: WORK, wait: WORK_TITLE, go: async () => {
    publicModel()
    must('click', '--name', 'composer')
    must('type', 'What does @cl')
    must('wait', '900')
  } },
  { name: 'files', args: WORK, wait: WORK_TITLE, go: async () => {
    publicModel()
    must('key', 'ctrl+p')
    must('wait', '1000')
    must('click', '--name', 'flr0')
    must('wait', '900')
  } },
  { name: 'schedules', args: WORK, wait: WORK_TITLE, go: async () => {
    publicModel()
    must('key', 'ctrl+k')
    must('idle')
    must('type', 'Schedules of this session')
    must('idle')
    must('key', 'Enter')
    must('wait', '900')
  } },
  // (searched: what shows is what the server can connect, not who is connected to what)
  { name: 'connections', args: [...SESSION, '--settings=6'], go: async () => {
    must('wait', '1500')
    must('click', '--name', 'int_find')
    must('type', 'open')
    must('wait', '600')
  } },
  { name: 'updates', args: [...SESSION, '--settings=3'], go: () => must('wait-for', 'Up to date', '--timeout', '15000') },   // (it looks at start)
  { name: 'settings', args: [...SESSION, '--settings=0'] },
  { name: 'subagent-session', args: SESSION, go: async () => {
    await scrollTo('Summarise src/stats.odin', 0.4)
    clickExact('Open', 2)
    must('wait-for', 'sub-agent')
    must('idle')
  } },
  // the viewer, zoomed in, on the conversation's picture (taken first, above)
  { name: 'viewer', args: () => [...SESSION, `--image=${join(docs, 'conversation.png')}`], go: async () => {
    must('wait-for', 'conversation.png')
    must('wheel', ...at(0.45, 0.45), '-1')   // (about one pixel of the picture per pixel of the window: sharp)
    must('idle')
  } },
  // the Linux build, in WSL, on Windows's server: its port and password from what the service wrote (never printed)
  { name: 'linux', linux: true, args: SESSION },
].filter((s) => (opt.linux ? s.linux : !s.linux && (!only || only.includes(s.name))))

function startLinux(args) {
  const log = openSync(join(repo, 'build', 'wsl_client.log'), 'w')   // (what went wrong in WSL; the password is not in it)
  const service = JSON.parse(readFileSync(join(homedir(), '.local', 'state', 'opencode', 'service.json'), 'utf8'))
  const env = {
    ...process.env, TOOLKIT_DEVTOOLS: String(PORT), OC_PORT: new URL(service.url).port, OC_PASSWORD: service.password,
    WSLENV: 'TOOLKIT_DEVTOOLS:OC_PORT:OC_PASSWORD',
  }
  return spawn('wsl.exe', ['--exec', 'bash', '-l', wslPath(join(repo, 'tools', 'wsl_client.sh')), opt.linux.startsWith('/') ? opt.linux : wslPath(resolve(opt.linux)), ...args], { env, stdio: ['ignore', log, log] })
}

if (opt.build) {
  const env = { ...process.env, GT: toolkit, OUT: exe }
  const r = windows
    ? spawnSync('cmd.exe', ['/c', '.\\build.bat'], { cwd: repo, env, stdio: 'inherit' })
    : spawnSync('bash', ['build.sh'], { cwd: repo, env, stdio: 'inherit' })
  if (r.status !== 0) process.exit(1)
}
if (!opt.linux && !existsSync(exe)) throw new Error(`${exe} is missing: run with --build`)

async function capture(shot) {
  const settings = mkdtempSync(join(tmpdir(), 'opencode_native_shot_'))
  const env = { ...process.env, TOOLKIT_DEVTOOLS: String(PORT), OPENCODE_NATIVE_NO_SETUP: '1', APPDATA: settings, XDG_CONFIG_HOME: settings }
  const args = [...COMMON, ...(typeof shot.args === 'function' ? shot.args() : shot.args)]
  const child = shot.linux ? startLinux(args) : spawn(exe, args, { env, stdio: 'ignore' })
  try {
    for (let i = 0; ; i++) {
      if (cdp('state').ok) break
      if (child.exitCode !== null) throw new Error(`the client ended (${child.exitCode})${shot.linux ? ': see build/wsl_client.log' : ''}`)
      if (i > (shot.linux ? 600 : 100)) throw new Error(`no answer on port ${PORT}`)   // (WSL may fetch its libraries first)
      await sleep(100)
    }
    must('wait-for', 'connected', '--timeout', '15000')
    must('wait-for', shot.wait ?? 'Tour of picker.odin', '--timeout', '15000')
    must('idle', '--timeout', '15000')
    if (shot.go) await shot.go()
    must('move', ...at(0.5, 0.02))   // the pointer over the title bar: nothing hovered, no scroll bar called up
    must('wait', '500')   // (what hover lit goes out)
    if (shot.linux) must('wait', '3000')   // (through the relay, the last requests are slower)
    must('idle')
    // (these are published: a model that is not public never goes out in one)
    // (what is scrolled out of the window is in the tree, not in the picture)
    const { height } = JSON.parse(must('state'))
    for (const secret of ['iceman', 'Contributor']) {
      for (const m of must('find', secret).matchAll(/@(-?[\d.]+),(-?[\d.]+) ([\d.]+)x([\d.]+)/g)) {
        const y = Number(m[2]), h = Number(m[4])
        if (h > 0 && y + h > 0 && y < height) throw new Error(`${shot.name}: "${secret}" would be in the picture, at y=${y}`)
      }
    }
    const out = join(docs, shot.name + '.png')
    must('shot', out)
    const site = join(repo, 'site', 'img', shot.name + '.png')
    if (!opt.out && shot.name !== 'conversation') copyFileSync(out, site)   // (the README's alone)
    console.log('saved', shot.name)
    if (shot.after) shot.after()
  } finally {
    if (shot.linux) cdp('close')
    child.kill()
    await new Promise((r) => (child.exitCode !== null ? r() : child.once('exit', r)))
    rmSync(settings, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 })
  }
}

for (const shot of SHOTS) await capture(shot)
