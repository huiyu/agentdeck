# agentdeck

**English** · [简体中文](README.zh-CN.md)

> Mission control for your terminal coding agents — one board across **Claude Code**, **Codex** (and more), on **zellij** or **tmux**.

Running several coding agents at once means babysitting a wall of tabs to find
the one that finished or is blocked on you. `agentdeck` gives you a single board
that shows every live session, its status, and lets you jump straight to it —
plus a desktop notification the moment a background session needs you.

```
agentdeck>  🟡 🟣 blibee:main          3s      ← waiting on you (Claude)
            🔴 🔵 api:fix-auth         12s      ← working (Codex)
            🟢 🟣 dotfiles:main         2m      ← done (Claude)
  🟡 waiting · 🔴 working · 🟢 idle    │ Enter: jump · Ctrl-x: forget
```

Status: 🟡 **waiting** (needs you) · 🔴 **working** · 🟢 **idle** (finished).

## Why

[craftzdog/tmux-claude-session-manager](https://github.com/craftzdog/tmux-claude-session-manager)
nailed this for **tmux + Claude**. agentdeck generalizes the idea along two axes:

- **Any agent** — Claude Code and Codex now ship the *same* hook design (JSON on
  stdin, identical event names), so unifying them is a thin per-agent profile,
  not a rewrite. New agents = one small file.
- **Any multiplexer** — state lives in plain files, not tmux session variables,
  so the board works under both zellij and tmux.

## How it works

```
        ┌──────────────── core (shared) ────────────────┐
        │  state files · fzf board · notifications · rank │
        └───────┬─────────────────────────────┬──────────┘
            agent adapter                  mux adapter
        (events → state, wiring)        (where am I, jump)
        claude · codex · …              zellij · tmux · …
```

Each agent calls `agentdeck ingest <agent>` from its hooks. That writes one JSON
file per session to `$XDG_STATE_HOME/agentdeck/`. `agentdeck pick` reads those
files — so the status is always accurate regardless of which tab is focused, and
the picker can map a session back to its multiplexer tab to jump there.

Why a picker + notifications rather than an always-on per-tab dot: multiplexers
render the *focused* tab's title and swallow a background pane's escape
sequences, so a background agent can't reliably mark its own tab. The board reads
state directly, and desktop banners cover the proactive "needs you" moment.

## Project layout

```
bin/agentdeck            single entrypoint — resolves lib/, loads config, dispatches
lib/core.sh              shared engine — state store, fzf board, notifications, ranking
lib/agents/<name>.sh     agent adapter — events → state, + how to wire/detect the hook
   ├─ claude.sh          Claude Code profile
   └─ codex.sh           Codex profile (+ notify fallback for "waiting")
lib/mux/<name>.sh        mux adapter — "where am I" + "jump to a tab"
   ├─ zellij.sh          zellij backend (implemented)
   └─ tmux.sh            tmux backend (implemented)
install.sh               symlink the CLI onto PATH
agentdeck.example.config example config to copy to ~/.config/agentdeck/config
```

State lives as one JSON file per session under `$AGENTDECK_STATE_DIR`, named
`<agent>-<session_id>.json`:

```json
{ "id": "…", "agent": "claude", "state": "waiting", "proj": "blibee",
  "tab": "blibee:main", "cwd": "/…", "transcript": "/…", "msg": "…", "ts": 1750000000 }
```

## Install

Requires **bash**, **jq**, **fzf** (and a notifier: `terminal-notifier`/
`osascript` on macOS, `notify-send` on Linux).

```sh
git clone https://github.com/huiyu/agentdeck ~/.agentdeck
~/.agentdeck/install.sh        # symlink `agentdeck` onto your PATH
agentdeck install              # wire Claude / Codex hooks (idempotent)
agentdeck doctor               # verify deps, detected agents, wiring
```

Then bind the board to a key, e.g. zsh:

```sh
alias ad='agentdeck pick'
```

`agentdeck install` patches each detected agent's config in place:

- **Claude Code** → `~/.claude/settings.json` `hooks` (SessionStart, UserPromptSubmit, Notification, Stop, SessionEnd)
- **Codex** → `~/.codex/hooks.json` (working/idle/end) **and** a `notify` entry in `~/.codex/config.toml` (the `waiting` signal — see Limitations)

It only adds its own entries and won't duplicate on re-run or clobber an existing
Codex `notify` (it prints the line to add instead).

## Usage

| Command | What |
|---|---|
| `agentdeck pick` | Open the board. **Enter** jumps · **Ctrl-x** kills the agent · **Ctrl-d** forgets the row |
| `agentdeck new [agent]` | Launch an agent in the current directory's project tab (default: first detected) |
| `agentdeck doctor` | Deps, detected agents, wiring status |
| `agentdeck install [agent…]` | Wire hooks (default: all detected) |
| `agentdeck list` | Raw TSV rows (scriptable) |
| `agentdeck dir` | Print the state directory (scriptable) |

**kill vs forget.** Ctrl-x **terminates the agent**: agentdeck records each
session's pid (walking up from the hook to the agent process) and sends it
SIGTERM — after re-checking the live process still belongs to that agent, so a
reused pid can't hit something else. The tab stays open as a plain shell (closing
a *background* tab in zellij would require yanking focus). Ctrl-d just drops the
row, leaving the agent running — for clearing stale/crashed entries.

## Configuration

Copy `agentdeck.example.config` to `~/.config/agentdeck/config` (plain `KEY=value`;
all optional). Every key also reads from the environment.

| Key | Default | What |
|---|---|---|
| `AGENTDECK_STATE_DIR` | `$XDG_STATE_HOME/agentdeck` | Where per-session state files live |
| `AGENTDECK_TTL` | `86400` | Prune state files untouched for this many seconds (dead/crashed sessions) |
| `AGENTDECK_NOTIFY_ON_STOP` | `1` | Desktop banner when a session finishes; set `0` to alert only on *waiting* |
| `AGENTDECK_MUX` | *(autodetect)* | Force a multiplexer instead of detecting from `$ZELLIJ` / `$TMUX` |
| `AGENTDECK_NOTIFY_SENDER` | *(none)* | Borrow another app's notification icon + identity (a bundle id, e.g. `com.apple.Terminal`). Requires `terminal-notifier`; no effect on the osascript fallback |
| `AGENTDECK_NOTIFY_ICON` | *(none)* | Path/URL to a custom notification icon image. Requires `terminal-notifier`; no effect on the osascript fallback |

## Extend it

The board, state store, and notifications are agent- and mux-agnostic. Adding
support is a single file behind one of two adapter axes.

**A new agent** — `lib/agents/<name>.sh` (model it on `claude.sh`):

- `AGENT_F_SID` / `AGENT_F_CWD` / `AGENT_F_TRANSCRIPT` — jq paths into the hook JSON
- `agent_detect` — is this agent installed?
- `agent_state_for <event>` — map a hook event to `idle` / `working` / `waiting` / `gone` / `skip`
- `agent_notify_state <type>` — same, for the out-of-band `notify` transport (or `echo skip`)
- `agent_installed` / `agent_install <self>` — check and idempotently wire the hook

Then add its icon to `_agentdeck_icon_json` in `lib/core.sh`.

**A new multiplexer** — `lib/mux/<name>.sh` needs just two functions:

- `mux_jump <proj> <tab>` — focus that session's tab (powers `agentdeck pick`)
- `mux_launch <proj> <tab> <cwd> <cmd>` — open a new tab running `<cmd>` (powers
  `agentdeck new`)

Both the zellij (`lib/mux/zellij.sh`) and tmux (`lib/mux/tmux.sh`) backends
implement exactly these two functions — use them as references.

## Limitations (v0.1)

- **Codex `waiting` is best-effort.** Codex doesn't yet expose `approval-requested`
  to hooks ([openai/codex#14813](https://github.com/openai/codex/issues/14813)),
  so it arrives via the `notify` program, which carries no session id or cwd
  ([#4005](https://github.com/openai/codex/issues/4005)); agentdeck matches it to
  the newest Codex session in that directory. Working/idle (via hooks) are exact.
- **Jumping across zellij sessions** requires detaching first (you can't attach a
  session from inside another).

## Roadmap

- v0.2: optional zellij `zjstatus` widget for an always-on aggregate count in
  the status bar.
- Later: more agents (gemini-cli, aider, opencode) as their hook support lands.

## License

MIT © Jeff Yu
