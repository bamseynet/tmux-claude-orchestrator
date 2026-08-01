# Quickstart: two workers in 5 minutes

Assumes you've run `./install.sh` inside a git repo and have `tmux`, `jq`, `claude`,
`perl`, `git` on PATH.

## 1. Start the orchestrator

```bash
cd /path/to/your/repo
./orch up
./orch attach
```

You're now in the tmux session. Window `orchestrator` holds the master Claude, which has
already read `_orch/CLAUDE.md` and is waiting for tasks. The status bar shows `no workers`.

## 2. Dispatch two unrelated tasks

From the master session, just ask in natural language:

```
Spawn a Sonnet worker "docs" to rewrite README.md for clarity, and a Haiku worker
"deps" to audit package.json for outdated dependencies and write findings to NOTES.md.
```

The master runs `./orch spawn docs sonnet "..."` and `./orch spawn deps haiku "..."`.
Two new windows appear; the status bar now reads `docs:working deps:working`.

Or drive it yourself from a second shell:

```bash
./orch spawn docs sonnet "Rewrite README.md for clarity. Keep all facts."
./orch spawn deps haiku  "Audit package.json for outdated deps; write findings to NOTES.md."
./orch status
```

## 3. Watch notifications flow

When `deps` finishes, its `Stop` hook writes an event; the heartbeat wakes the master
with `[orchestrator heartbeat] Worker events ... deps done`. The master reads
`_orch/state/workers/deps.json`, reviews the branch, and decides what's next — without you
polling anything. The `deps` window tab flags yellow when it moves; the HUD flips it to
green when done.

## 4. A related cluster (worker runs its own team)

```
Spawn an Opus worker "billing" and have it lead a 3-teammate agent team to build the
billing module across api/, ui/, and tests/. Report back when merged and green.
```

`billing` becomes a team lead in its own window, splitting into panes for its teammates —
a full second tier of parallelism, coordinated by that worker, not by you.

## 5. Wind down

```bash
./orch down                         # stop heartbeat + watchdog
tmux kill-session -t orch           # close everything
git worktree prune                  # clean up worker worktrees
```

## Tuning knobs

- `_orch/config.json` — intervals, `max_workers`, watchdog on/off.
- `_orch/lib.sh` — `is_busy` / `is_ready` regexes. If a Claude Code TUI update changes the
  spinner or input box, adjust these two functions; everything else keys off them.
