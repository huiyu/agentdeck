# agentdeck

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
  so the board works under zellij today and tmux next.

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
| `agentdeck pick` | Open the board; Enter jumps, Ctrl-x forgets a session |
| `agentdeck doctor` | Deps, detected agents, wiring status |
| `agentdeck install [agent…]` | Wire hooks (default: all detected) |
| `agentdeck list` | Raw TSV rows (scriptable) |

## Configuration

Copy `agentdeck.example.config` to `~/.config/agentdeck/config` (plain `KEY=value`):
state dir, prune TTL, whether to notify on finish, and a forced multiplexer.

## Limitations (v0.1)

- **zellij only.** tmux is a ~15-line adapter away (stub in `lib/mux/tmux.sh`) — v0.2.
- **Codex `waiting` is best-effort.** Codex doesn't yet expose `approval-requested`
  to hooks ([openai/codex#14813](https://github.com/openai/codex/issues/14813)),
  so it arrives via the `notify` program, which carries no session id or cwd
  ([#4005](https://github.com/openai/codex/issues/4005)); agentdeck matches it to
  the newest Codex session in that directory. Working/idle (via hooks) are exact.
- **Jumping across zellij sessions** requires detaching first (you can't attach a
  session from inside another).

## Roadmap

- v0.2: tmux backend; optional zellij `zjstatus` widget for an always-on
  aggregate count in the status bar.
- Later: more agents (gemini-cli, aider, opencode) as their hook support lands.

## License

MIT © Jeff Yu
