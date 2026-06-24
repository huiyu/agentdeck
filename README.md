# agentdeck

**English** · [简体中文](README.zh-CN.md)

> Mission control for your terminal coding agents — one board across **Claude Code**, **Codex** (and more), on **zellij** or **tmux**.

Running several coding agents at once means babysitting a wall of tabs to find
the one that finished or is blocked on you. `agentdeck` gives you a single board
that shows every live session, its status, and lets you jump straight to it —
plus a desktop notification the moment a background session needs you. **Click
the notification and it brings you back to the exact tab.**

```
agentdeck>  🟡 🟣 blibee:main          3s      ← waiting on you (Claude)
            🔴 🔵 api:fix-auth         12s      ← working (Codex)
            🟢 🟣 dotfiles:main         2m      ← done (Claude)
  🟡 waiting · 🔴 working · 🟢 idle    │ Enter: jump · Ctrl-x: kill · Ctrl-d: forget
```

Status: 🟡 **waiting** (needs you) · 🔴 **working** · 🟢 **idle** (finished).

> **New here?** Jump to [Quick start](#quick-start). Want every flag and a
> troubleshooting guide? See the **[Usage manual](docs/USAGE.md)**.

## Contents

- [Why](#why)
- [How it works](#how-it-works)
- [Quick start](#quick-start)
- [Usage](#usage)
- [Notifications & click-to-focus](#notifications--click-to-focus)
- [Configuration](#configuration)
- [State model](#state-model)
- [Extending agentdeck](#extending-agentdeck)
- [Limitations](#limitations)
- [Roadmap](#roadmap)
- [License](#license)

## Why

[craftzdog/tmux-claude-session-manager](https://github.com/craftzdog/tmux-claude-session-manager)
nailed this for **tmux + Claude**. agentdeck generalizes the idea along two axes:

- **Any agent** — Claude Code and Codex now ship the *same* hook design (JSON on
  stdin, identical event names), so unifying them is a thin per-agent profile,
  not a rewrite. New agents = one small file.
- **Any multiplexer** — state lives in plain files, not tmux session variables,
  so the board works under both zellij and tmux.

Why a picker + notifications rather than an always-on per-tab dot: multiplexers
render the *focused* tab's title and swallow a background pane's escape
sequences, so a background agent can't reliably mark its own tab. The board reads
state directly, and desktop banners cover the proactive "needs you" moment.

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

The same state file powers **click-to-focus**: a clicked notification runs
`agentdeck focus <file>`, which reads the session's recorded host terminal and
multiplexer and brings that exact tab to the front. See
[Notifications & click-to-focus](#notifications--click-to-focus).

## Quick start

Requires **bash**, **jq**, **fzf**, and a notifier (`terminal-notifier` on
macOS — see [Notifications](#notifications--click-to-focus); `notify-send` on
Linux).

```sh
git clone https://github.com/huiyu/agentdeck ~/.agentdeck
~/.agentdeck/install.sh        # symlink `agentdeck` onto your PATH
agentdeck install              # wire Claude / Codex hooks (idempotent)
agentdeck doctor               # verify deps, detected agents, wiring

# (macOS) for clickable, jump-back notifications:
brew install terminal-notifier
```

Bind the board to a key, e.g. in zsh:

```sh
alias ad='agentdeck pick'
```

`agentdeck install` patches each detected agent's config in place, adding only
its own entries (idempotent, won't clobber yours):

- **Claude Code** → `~/.claude/settings.json` `hooks` (SessionStart, UserPromptSubmit, Notification, Stop, SessionEnd)
- **Codex** → `~/.codex/hooks.json` (working/idle/end) **and** a `notify` entry in `~/.codex/config.toml` (the `waiting` signal — see [Limitations](#limitations))

Full install/wiring details: **[Usage manual → Install & wiring](docs/USAGE.md#install--wiring)**.

## Usage

| Command | What |
|---|---|
| `agentdeck pick` | Open the board. **Enter** jumps · **Ctrl-x** kills the agent · **Ctrl-d** forgets the row |
| `agentdeck new [agent]` | Launch an agent in the current directory's project tab (default: first detected) |
| `agentdeck doctor` | Deps, detected agents, wiring status |
| `agentdeck install [agent…]` | Wire hooks (default: all detected) |
| `agentdeck list` | Raw TSV rows (scriptable) |
| `agentdeck dir` | Print the state directory (scriptable) |
| `agentdeck version` · `help` | Version / usage |

`ingest` and `focus` exist for hooks and notification clicks — you don't call
them by hand. Every command, flag, and exit code: **[Usage manual → Commands](docs/USAGE.md#commands)**.

**kill vs forget.** Ctrl-x **terminates the agent**: agentdeck records each
session's pid (walking up from the hook to the agent process) and sends it
SIGTERM — after re-checking the live process still belongs to that agent, so a
reused pid can't hit something else. The tab stays open as a plain shell. Ctrl-d
just drops the row, leaving the agent running — for clearing stale/crashed
entries.

## Notifications & click-to-focus

agentdeck posts a desktop banner when a session needs you (**waiting**) and, by
default, when one **finishes** (toggle with `AGENTDECK_NOTIFY_ON_STOP`).
**Click the banner to jump back to that session's tab.**

It picks the first available notifier:

| Notifier | Banner | Click-to-focus | Notes |
|---|---|---|---|
| **terminal-notifier** | ✅ | ✅ | macOS; `brew install terminal-notifier`. The only backend that supports a click action |
| **osascript** (built-in) | ✅ | ❌ | macOS fallback; macOS forbids custom click actions on these |
| **notify-send** | ✅ | partial | Linux |

**Click-to-focus** (macOS + terminal-notifier) is controlled by
`AGENTDECK_NOTIFY_FOCUS` and degrades gracefully per host terminal:

- **Ghostty** — focuses the *exact* tab (matched by working directory).
- **iTerm2 / others** — brings the terminal app forward.
- **VS Code** — reuses the project's window.
- Target tab closed or its cwd drifted → falls back to just bringing the app forward.

### macOS setup (do this once)

The feature is silent without it:

1. `brew install terminal-notifier`
2. **System Settings → Notifications → terminal-notifier** → turn on *Allow
   Notifications*, and set the style to **Alerts** (Banners auto-dismiss and are
   easy to miss/misclick).
3. The **first** time you click a banner, macOS asks to let *terminal-notifier
   control your terminal* — click **Allow** (it persists).

Banners not showing or clicks not jumping? See
**[Usage manual → Troubleshooting](docs/USAGE.md#troubleshooting)**.

## Configuration

Copy `agentdeck.example.config` to `~/.config/agentdeck/config` (plain
`KEY=value`; all optional). Every key also reads from the environment.

| Key | Default | What |
|---|---|---|
| `AGENTDECK_STATE_DIR` | `$XDG_STATE_HOME/agentdeck` | Where per-session state files live |
| `AGENTDECK_TTL` | `86400` | Prune state files untouched for this many seconds (dead/crashed sessions) |
| `AGENTDECK_MUX` | *(autodetect)* | Force a multiplexer instead of detecting from `$ZELLIJ` / `$TMUX` |
| `AGENTDECK_NOTIFY_ON_STOP` | `1` | Desktop banner when a session finishes; set `0` to alert only on *waiting* |
| `AGENTDECK_NOTIFY_FOCUS` | `auto` | Click a banner to jump back. `auto` detects the host (Ghostty → exact tab; others → app forward; VS Code → project window); force with `ghostty` / `vscode` / `app:<bundle-id>`, or `off`. macOS + `terminal-notifier` only |
| `AGENTDECK_NOTIFY_SENDER` | *(none)* | Borrow another app's notification icon + identity (a bundle id, e.g. `com.apple.Terminal`). `terminal-notifier` only |
| `AGENTDECK_NOTIFY_ICON` | *(none)* | Path/URL to a custom notification icon image. `terminal-notifier` only |
| `AGENTDECK_CONFIG` | `~/.config/agentdeck/config` | Path to the config file itself |

## State model

State lives as one JSON file per session under `$AGENTDECK_STATE_DIR`, named
`<agent>-<session_id>.json`:

```json
{ "id": "…", "agent": "claude", "state": "waiting",
  "proj": "blibee", "tab": "blibee:main", "cwd": "/…",
  "transcript": "/…", "msg": "…", "pid": 12345,
  "host": "ghostty", "mux": "tmux", "ts": 1750000000 }
```

`host` (the terminal that launched the agent) and `mux` (the multiplexer) are
captured at hook time and let the detached notification-click handler jump back
without a terminal of its own. Field-by-field reference:
**[Usage manual → State files](docs/USAGE.md#state-files)**.

## Extending agentdeck

The board, state store, and notifications are agent- and mux-agnostic. Adding
support is a single file behind one of two adapter axes.

**A new agent** — `lib/agents/<name>.sh` (model it on `claude.sh`):

- `AGENT_F_SID` / `AGENT_F_CWD` / `AGENT_F_TRANSCRIPT` — jq paths into the hook JSON
- `agent_detect` — is this agent installed?
- `agent_state_for <event>` — map a hook event to `idle` / `working` / `waiting` / `gone` / `skip`
- `agent_notify_state <type>` — same, for the out-of-band `notify` transport (or `echo skip`)
- `agent_installed` / `agent_install <self>` — check and idempotently wire the hook

Then add its icon to `_agentdeck_icon_json` in `lib/core.sh`.

**A new multiplexer** — `lib/mux/<name>.sh` implements three functions:

- `mux_jump <proj> <tab>` — focus that session's tab (powers `agentdeck pick`)
- `mux_launch <proj> <tab> <cwd> <cmd>` — open a new tab running `<cmd>` (powers `agentdeck new`)
- `mux_select <proj> <tab>` — select that window **without attaching** (powers click-to-focus, which runs detached)

Both the zellij (`lib/mux/zellij.sh`) and tmux (`lib/mux/tmux.sh`) backends are
references. Full walkthrough: **[Usage manual → Extending](docs/USAGE.md#extending)**.

## Limitations

- **Codex `waiting` is best-effort.** Codex doesn't yet expose `approval-requested`
  to hooks ([openai/codex#14813](https://github.com/openai/codex/issues/14813)),
  so it arrives via the `notify` program, which carries no session id or cwd
  ([#4005](https://github.com/openai/codex/issues/4005)); agentdeck matches it to
  the newest Codex session in that directory. Working/idle (via hooks) are exact.
- **Click-to-focus precision is Ghostty-only** today. Other terminals bring the
  app forward but can't select the exact tab from outside; VS Code reuses the
  project window. iTerm2 / WezTerm / kitty precise focus is a future adapter.
- **Click-to-focus matches by working directory**, so if the target tab was
  closed or its cwd drifted (multiple windows in one tmux session), it falls back
  to bringing the host app forward.
- **zellij window-select on click is a no-op** for now (zellij can't select a
  tab in a detached session from outside the way tmux can); the host app still
  comes forward.
- **Jumping across zellij sessions** requires detaching first (you can't attach a
  session from inside another).

## Roadmap

- More agents (gemini-cli, aider, opencode) as their hook support lands.
- Precise click-to-focus adapters for iTerm2 / WezTerm / kitty.
- Optional zellij `zjstatus` widget for an always-on aggregate count in the
  status bar.

## License

MIT © Jeff Yu
