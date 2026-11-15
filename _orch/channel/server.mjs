// _orch/channel/server.mjs -- one-way Claude Code channel for the orchestrator (issue #212).
// No tools. Tails $ORCH_STATE_DIR/channel-outbox-<ppid>.jsonl (written ONLY by the
// heartbeat, once it has seen a fresh liveness file for this ppid) and emits one
// notifications/claude/channel per line. Publishes $ORCH_STATE_DIR/channel-<ppid>.json
// so the heartbeat can tell whether the channel is really loaded: this server also
// spawns WITHOUT the dev-channels flag (events are then silently dropped by Claude
// Code), so `loaded` = the parent claude's argv carries the flag.
import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import fs from 'node:fs'
import path from 'node:path'
import { execFileSync } from 'node:child_process'

const FLAG = '--dangerously-load-development-channels'
const state = process.env.ORCH_STATE_DIR || path.resolve('.')
const ppid = process.ppid
const livePath = path.join(state, `channel-${ppid}.json`)
const outbox = path.join(state, `channel-outbox-${ppid}.jsonl`)
const cursorPath = path.join(state, `channel-cursor-${ppid}`)
const started = Math.floor(Date.now() / 1000)

function parentCmdline() {
  try { return fs.readFileSync(`/proc/${ppid}/cmdline`, 'utf8').replace(/\0/g, ' ') } catch {}
  try { return execFileSync('ps', ['-o', 'command=', '-p', String(ppid)], { encoding: 'utf8' }) } catch {}
  return ''
}
const loaded = parentCmdline().includes(FLAG)

function writeAtomic(p, data) {
  const tmp = `${p}.tmp.${process.pid}`
  fs.writeFileSync(tmp, data)
  fs.renameSync(tmp, p)
}
const beat = () => {
  try {
    writeAtomic(livePath, JSON.stringify({ pid: process.pid, ppid, started, loaded, ts: Math.floor(Date.now() / 1000) }))
  } catch (e) { console.error('liveness write failed', e) }
}
// Only remove OUR liveness file: when Claude Code restarts this server (same
// ppid), the replacement may already have written its own before we exit.
const cleanup = () => {
  try { if (JSON.parse(fs.readFileSync(livePath, 'utf8')).pid === process.pid) fs.unlinkSync(livePath) } catch {}
}
for (const s of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(s, () => { cleanup(); process.exit(0) })
process.on('exit', cleanup)

const mcp = new Server({ name: 'orch', version: '0.1.0' }, {
  capabilities: { experimental: { 'claude/channel': {} } },
  // Absolute paths: the master's cwd is the target repo, which need not hold _orch/.
  instructions: `Events arrive as <channel source="orch" id=".." event=".." ts="..">. They are one-way worker events from the tmux orchestrator, equivalent to an "[orchestrator heartbeat]" message: read ${path.join(state, 'workers')}/*.json, then decide and dispatch next steps (assign, review, or shut down). If you're at all unsure of current orchestration state (e.g. right after a compaction), run ${path.join(state, '..', 'rehydrate.sh')} first. No reply is expected.`,
})
await mcp.connect(new StdioServerTransport())
// Parent (claude) closing our stdin means the session is over.
process.stdin.on('end', () => { cleanup(); process.exit(0) })

// cursor = bytes of the outbox already emitted (persisted); readOff = bytes read so far.
// A trailing partial line stays in buf until its newline arrives. buf holds raw
// bytes (split on 0x0A only), so a read that ends mid UTF-8 sequence -- a large
// append can reach the file in several write()s -- never decodes a half
// character and the byte cursor stays exact.
let cursor = 0
try { cursor = parseInt(fs.readFileSync(cursorPath, 'utf8'), 10) || 0 } catch {}
let readOff = cursor
let buf = Buffer.alloc(0)
let ino = null
beat(); setInterval(beat, 2000)

let busy = false
async function pump() {
  // Not loaded => Claude Code would drop the notifications; leave them unconsumed.
  if (!loaded || busy) return
  busy = true
  try {
    let st
    try { st = fs.statSync(outbox) } catch { return }
    // Truncated, or replaced (the heartbeat renames an orphaned outbox away and a
    // new one appears at the same path): start the new file from byte 0.
    if (st.size < readOff || (ino !== null && st.ino !== ino)) { cursor = 0; readOff = 0; buf = Buffer.alloc(0) }
    ino = st.ino
    if (st.size > readOff) {
      const fd = fs.openSync(outbox, 'r')
      const b = Buffer.alloc(st.size - readOff)
      try { fs.readSync(fd, b, 0, b.length, readOff) } finally { fs.closeSync(fd) }
      readOff = st.size
      buf = Buffer.concat([buf, b])
    }
    // Runs even with no new bytes, so a line whose notification failed last time
    // (still at the head of buf) is retried on the next pump.
    let i
    while ((i = buf.indexOf(0x0a)) >= 0) {
      // Consume the line only after it was sent: a failed notification leaves it
      // in buf (and the cursor unadvanced) so the next pump retries it.
      const line = buf.subarray(0, i).toString('utf8')
      if (line.trim()) {
        let j; try { j = JSON.parse(line) } catch { j = { text: line } }
        if (j.ppid === undefined || Number(j.ppid) === ppid) {
          await mcp.notification({ method: 'notifications/claude/channel', params: {
            content: String(j.text ?? line),
            // meta keys must be [A-Za-z0-9_]; hyphenated keys are dropped by Claude Code.
            meta: { id: String(j.id ?? ''), event: String(j.event ?? ''), ts: String(j.ts ?? '') } } })
        }
      }
      buf = buf.subarray(i + 1)
      cursor += i + 1
      try { writeAtomic(cursorPath, String(cursor)) } catch {}
    }
  } finally { busy = false }
}
setInterval(() => pump().catch(e => console.error(e)), 300)
