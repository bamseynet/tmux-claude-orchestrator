# tmux-claude-orchestrator

A **master Claude session** in one tmux window that spawns and manages **independent worker
Claude sessions** in other windows — each on its own task, in its own git worktree — and gets
**notified** when they finish or get stuck. Built for Mac + iTerm2, works anywhere tmux runs.

```
┌───────────────────────── tmux session "orch" ─────────────────────────┐
│                                                                        │
│  window: orchestrator      window: w1        window: w2                │
│  ┌──────────────────┐     ┌──────────┐      ┌──────────┐               │
│  │ MASTER (Opus)    │     │ Worker   │      │ Worker   │  ... more     │
│  │ plans, dispatch, │     │ (Sonnet) │      │ (Haiku)  │               │
│  │ reviews          │     │ worktree │      │ worktree │               │
│  └───────┬──────────┘     └────┬─────┘      └────┬─────┘               │
│          │  wakes only on events   │  Stop/Notification hooks          │
│          └───────────┬─────────────┴───────────────                    │
│                      ▼                                                  │
│            _orch/state/{workers,inbox}   ← files                       │
└────────────────────────────────────────────────────────────────────────┘
              ▲
    heartbeat.sh (external bash loop): watch inbox → wake master only on events
    watchdog.sh (external bash loop): catch rate limits → retry exact command
```

## Why this shape

- **Master orchestrates at the tmux level**, not via Agent Teams. So every worker is a *full
  independent Claude session* (own 1M context, own hooks, own MCP) — and a worker handling a
  tightly-coupled cluster can itself run a **native agent team** in its own window. Two tiers of
  parallelism, no nested-team limitation.
- **The LLM decides; bash polls.** An external heartbeat does the cheap watching and only wakes
  the master when there's a decision to make. You don't pay tokens to watch paint dry.
- **Reliable prompt delivery.** All the send-keys gotchas (literal mode, separate Enter,
  buffer-paste for multiline, ANSI stripping, idle handshake) are handled in `_orch/lib.sh`.

## Install

```bash
git clone https://github.com/bamseynet/tmux-claude-orchestrator.git
cd tmux-claude-orchestrator
./install.sh /path/to/your/project     # copies the toolkit into your repo, writes settings
```

Requires: `tmux`, `jq`, `claude` (Claude Code CLI), `perl`, `git`.

## Use

```bash
cd /path/to/your/project
./orch up            # start session + master + heartbeat + watchdog
./orch attach        # watch (master in window 0; workers get their own windows)

./orch spawn w1 sonnet "Implement password reset in src/auth"
./orch spawn docs haiku  "Rewrite README for clarity"
./orch status
./orch send  w1 "Use argon2, not bcrypt"
./orch down          # stop background loops
```

### Resuming a session

By default `spawn` launches a fresh Claude session. To resume prior context instead, pass a
resume flag after the task:

```bash
./orch spawn w1 sonnet "Continue the auth work" --continue          # newest session in that dir
./orch spawn w1 sonnet "Continue the auth work" --resume <session-id>
```

Claude keys sessions by project directory, so a resumed worker must run in the same dir the
session was recorded in. `--continue`/`--resume` therefore **force `--no-worktree`** (running in
`PROJECT_ROOT` rather than an isolated `orch/<id>` worktree); a note is logged when this happens.

Inside the master session you can skip the CLI and just talk to it: *"Spawn a Sonnet worker to
do X and a Haiku worker to research Y."* It calls `./orch` for you. See
[`examples/quickstart.md`](examples/quickstart.md).

## How notifications work

Each worker is spawned with hooks (written to its worktree's `.claude/settings.local.json`):

- **`Stop`** → fires when the worker finishes a turn → `report.sh <id> done`
- **`Notification`** → fires when it needs input/permission → `report.sh <id> needs-input`

`report.sh` appends to `_orch/state/inbox.jsonl` and updates `_orch/state/workers/<id>.json`.
The **heartbeat** drains the inbox and — only when the master's pane is idle — pastes a single
`[orchestrator heartbeat]` message summarizing events, so the master reacts without polling. The
tmux status bar HUD (`hud.sh`) shows `w1:working w2:blocked` live, and window tabs flag on
activity.

## iTerm2 note (`-CC` vs plain)

`tmux -CC` maps each window to a native iTerm2 tab (pretty) **but hides the tmux status line**,
where the HUD lives. Since this rig is about seeing many workers at once, attach with **plain
`tmux attach`** (via `./orch attach`) to keep the HUD and activity flags. Use `-CC` for casual
multi-session work.

## Configuration

`_orch/config.json`:

| Key | Default | Meaning |
|---|---|---|
| `intervals.normal_seconds` | 20 | heartbeat tick while events are flowing |
| `intervals.idle_seconds` | 60 | heartbeat tick when idle |
| `thresholds.max_workers` | 4 | soft cap you should respect |
| `watchdog.enabled` | true | auto-retry on rate limits |
| `watchdog.cooldown_seconds` | 65 | wait before retry (API limits ~60s) |

If a Claude Code TUI update changes the spinner or input box, adjust `is_busy`/`is_ready` in
`_orch/lib.sh` — everything keys off those two functions.

## ⚠️ Caveats — read before unattended runs

- **Security.** For hands-off operation you'll likely run workers with
  `--dangerously-skip-permissions` (add it in `spawn.sh` step 4 if you want it) — a worker can
  then read/write/execute anything in its worktree with no confirmation. **Dev machines and
  version-controlled code only. No production. No sensitive credentials.** Keep the *master* on
  the permission allowlist rather than full skip, and keep a review gate before any merge.
- **Cost.** Each worker is a full session (reportedly ~40K tokens overhead before any work) plus
  its own context; a worker running its own team multiplies that. This can drain a weekly plan
  fast. Lead=Opus, workers=Sonnet, research=Haiku; cap concurrency; watch `/usage`.
- **Reliability.** send-keys orchestration is robust-enough, not bulletproof. Prefer the hook
  signal over pane-scraping. If the master gets a stale prompt, the idle handshake will requeue.
- **Resumption.** Native agent teams don't restore in-process teammates on `/resume`; if a
  worker's team dies, tell that worker to re-spawn its teammates.

## Prior art / credit

The send-keys reliability patterns, idle detection, and rate-limit-retry idea are distilled from
the community orchestration kits — notably **absmartly/Tmux-Orchestrator** and
**primeline-ai/claude-tmux-orchestration**. This repo adds the *worker-can-run-its-own-team*
tier, session-scoped HUD, and a single `orch` CLI.

## License

MIT — see [LICENSE](LICENSE).
