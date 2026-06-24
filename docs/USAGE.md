# agentdeck — Usage manual

**English** · [简体中文](USAGE.zh-CN.md) · [← README](../README.md)

A complete reference for installing, wiring, configuring, and troubleshooting
agentdeck. For a one-screen overview, read the [README](../README.md) first.

## Contents

- [Concepts](#concepts)
- [Install & wiring](#install--wiring)
- [Commands](#commands)
- [The board](#the-board)
- [Notifications & click-to-focus](#notifications--click-to-focus)
- [Configuration](#configuration)
- [State files](#state-files)
- [Multiplexer behavior](#multiplexer-behavior)
- [Agent wiring details](#agent-wiring-details)
- [Extending](#extending)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)

## Concepts

agentdeck has three moving parts:

- **Core** (`lib/core.sh`) — the shared engine: the state store, the fzf board,
  ranking, and notifications. Agent- and multiplexer-agnostic.
- **Agent adapters** (`lib/agents/<name>.sh`) — map a coding agent's hook events
  to a state, and know how to wire/detect that agent. Ship: `claude`, `codex`.
- **Multiplexer adapters** (`lib/mux/<name>.sh`) — answer "where am I" and "jump
  to a tab". Ship: `tmux`, `zellij`.

Everything flows through one entrypoint, `bin/agentdeck`, which resolves its
`lib/` directory (following symlinks), loads config, then dispatches a subcommand.

Two vocabulary notes used throughout:

- **proj** — the project, which maps to a multiplexer *session* name.
- **tab** — `repo:branch`, which maps to a multiplexer *window/tab*.

## Install & wiring

### Dependencies

| Tool | Required | For |
|---|---|---|
| `bash` | yes | the engine |
| `jq` | yes | reading/writing state JSON |
| `fzf` | yes | the `pick` board |
| `tmux` or `zellij` | yes | the multiplexer you run agents in |
| `terminal-notifier` | macOS, for clickable notifications | banners + click-to-focus |
| `osascript` | built into macOS | banner fallback (no click action) |
| `notify-send` | Linux | banners |

### Steps

```sh
git clone https://github.com/huiyu/agentdeck ~/.agentdeck
~/.agentdeck/install.sh        # symlinks bin/agentdeck into ~/.local/bin
agentdeck install              # wires detected agents (idempotent)
agentdeck doctor               # prints deps, detected agents, wiring, notifier
brew install terminal-notifier # macOS: enables clickable, jump-back banners
```

`install.sh` only puts the launcher on your PATH. `agentdeck install` does the
per-agent hook wiring. `agentdeck doctor` is your verification command — run it
any time something looks off.

### What `agentdeck install` writes

It patches each *detected* agent's config in place, adding only its own entries.
Re-running is safe (idempotent) and it never clobbers your existing settings.

- **Claude Code** → `~/.claude/settings.json`, under `hooks`: `SessionStart`,
  `UserPromptSubmit`, `Notification`, `Stop`, `SessionEnd`. Each calls
  `agentdeck ingest claude`.
- **Codex** → `~/.codex/hooks.json` for working/idle/end, **and** a `notify`
  entry in `~/.codex/config.toml` for the `waiting` signal. If you already have a
  Codex `notify` program, agentdeck won't overwrite it — it prints the line to
  add instead.

The command baked into each hook is the stable launcher (`$HOME/.local/bin/agentdeck`)
when it links back to the repo, so it survives the repo moving.

## Commands

```
agentdeck <command> [args]
```

| Command | Synopsis | Notes |
|---|---|---|
| `pick` | Open the fzf board | Enter jumps · Ctrl-x kills · Ctrl-d forgets |
| `new [agent]` | Launch an agent in this dir's project tab | Default: first detected agent |
| `install [agent…]` | Wire hooks | Default: all detected agents |
| `doctor` | Show deps / agents / wiring / notifier | Verification command |
| `list` | Raw TSV rows | Scriptable; used internally by `pick` |
| `dir` | Print the state directory | Scriptable |
| `version` | Print version | |
| `help` | Print usage | |
| `ingest <agent>` | Hook entrypoint | Agents call this; **not for humans** |
| `focus <file>` | Notification-click handler | Clicks call this; **not for humans** |
| `preview <file>` | Render one session for the fzf preview pane | Internal |
| `kill <file>` | Terminate the agent + drop the row | Internal (Ctrl-x in the board) |
| `forget <file>` | Drop the row, leave the agent running | Internal (Ctrl-d in the board) |

### `agentdeck new [agent]`

Launches an agent in a tab for the current directory's project. With no argument
it uses the first detected agent (checks `claude`, then `codex`). The mux adapter
creates the session if needed, names the tab `repo:branch`, and attaches.

### `agentdeck focus <file>`

The click handler. `<file>` is a state-file basename. It is invoked **detached**
(by macOS launchd via terminal-notifier's `-execute`), with no controlling
terminal and a minimal `PATH`. It reads the recorded `host`/`mux`/`proj`/`tab`/`cwd`
and:

1. **Axis ①** — selects the agent's window *without attaching* (`mux_select`).
2. **Axis ②** — brings the host app/tab to the front (`focus_host`).

The focus strategy is resolved **at click time** from `AGENTDECK_NOTIFY_FOCUS`
plus the recorded host, so changing config takes effect without relaunching
agents. You never run this by hand; it's the target of the notification's click.

## The board

`agentdeck pick` opens an fzf picker over your live sessions.

**Columns** (sorted: waiting → working → idle, newest first within a state):

```
🟡 🟣 blibee:main   3s   ← state dot · agent icon · tab · age
```

- **State dot** — 🟡 waiting · 🔴 working · 🟢 idle.
- **Agent icon** — 🟣 claude · 🔵 codex · 🟤 gemini · 🟠 aider.
- **tab** — `repo:branch`.
- **age** — time since the last state update.

**Keys:**

| Key | Action |
|---|---|
| `Enter` | Jump to that session's tab |
| `Ctrl-x` | **Kill** the agent (SIGTERM) and drop the row |
| `Ctrl-d` | **Forget** the row (agent keeps running) |

The right pane previews the selected session: agent/proj/tab/state/cwd/age plus
the recent assistant message and a transcript tail.

**kill vs forget.** `kill` records each session's pid (walking up from the hook
to the agent process) and sends SIGTERM — after re-checking the live process
still belongs to that agent, so a reused pid can't hit an innocent process. The
tab stays open as a plain shell. `forget` only drops the state row, leaving the
agent running — use it to clear stale or crashed entries.

## Notifications & click-to-focus

### When banners fire

- **waiting** — the agent needs you (Claude `Notification` event; Codex via the
  `notify` program). Always notifies.
- **finished** — the agent stopped (Claude `Stop`). Notifies when
  `AGENTDECK_NOTIFY_ON_STOP=1` (default); set `0` to alert only on *waiting*.

### Backend selection

`_notify` picks the first available of: `terminal-notifier` → `osascript` →
`notify-send`. **Only `terminal-notifier` can carry a click action.** On the
osascript fallback, banners still appear but clicking does nothing useful (macOS
forbids custom click actions on `display notification`).

### The click pipeline

```
banner click
   └─ launchd runs:  agentdeck focus <agent>-<sid>.json   (detached, minimal env)
        └─ core_focus reads state → mux_select (axis ①) → focus_host (axis ②)
             └─ Ghostty: osascript focuses the tab whose working dir == agent cwd
```

The command is baked into the notification with `terminal-notifier -execute`,
shell-quoted with `printf %q` so it is robust regardless of the install path.

### Strategies — `AGENTDECK_NOTIFY_FOCUS`

| Value | Click behavior |
|---|---|
| `auto` (default) | Detect the host terminal and pick the best strategy below |
| `ghostty` | Focus the exact Ghostty tab (matched by working directory) |
| `vscode` | Activate VS Code and reuse the project's window (`code <cwd>`) |
| `app:<bundle-id>` | Just activate that app, e.g. `app:com.apple.Terminal` |
| `off` | No click action |

Under `auto`, the host is recovered at hook time even inside tmux (which
overwrites `TERM_PROGRAM`) by reading the tmux server's global environment.
Recognized hosts map to: Ghostty → exact-tab focus; VS Code → project window;
everything else → bring the app forward (the "basic" tier).

### macOS setup (once)

1. `brew install terminal-notifier`
2. **System Settings → Notifications → terminal-notifier**: *Allow Notifications*
   ON, style **Alerts** (Banners auto-dismiss and are easy to miss/misclick).
3. First click → allow *terminal-notifier to control your terminal* (persists).

See [Troubleshooting](#troubleshooting) if banners don't show or clicks don't jump.

## Configuration

Config is a plain shell file of `KEY=value` lines. Resolution order: the file at
`AGENTDECK_CONFIG` (default `~/.config/agentdeck/config`) is sourced first, then
any environment variable of the same name overrides it. Copy
`agentdeck.example.config` to get started. All keys are optional.

| Key | Default | What |
|---|---|---|
| `AGENTDECK_STATE_DIR` | `$XDG_STATE_HOME/agentdeck` (`~/.local/state/agentdeck`) | Per-session state files |
| `AGENTDECK_TTL` | `86400` | Prune state files untouched this many seconds (dead/crashed sessions) |
| `AGENTDECK_MUX` | autodetect | Force `tmux` / `zellij` instead of detecting from `$ZELLIJ` / `$TMUX` |
| `AGENTDECK_NOTIFY_ON_STOP` | `1` | Banner on finish; `0` = only on waiting |
| `AGENTDECK_NOTIFY_FOCUS` | `auto` | Click-to-focus strategy: `auto` / `ghostty` / `vscode` / `app:<bundle-id>` / `off`. macOS + terminal-notifier only |
| `AGENTDECK_NOTIFY_SENDER` | none | Borrow another app's icon + identity (a bundle id). terminal-notifier only |
| `AGENTDECK_NOTIFY_ICON` | none | Custom notification icon (path/URL). terminal-notifier only |
| `AGENTDECK_CONFIG` | `~/.config/agentdeck/config` | Path to the config file itself (env only) |

## State files

One JSON file per session at `$AGENTDECK_STATE_DIR/<agent>-<session_id>.json`:

| Field | Meaning |
|---|---|
| `id` | The agent's session id |
| `agent` | `claude` / `codex` / … |
| `state` | `waiting` / `working` / `idle` |
| `proj` | Project = mux session name |
| `tab` | `repo:branch` = mux window/tab name |
| `cwd` | The agent's working directory (the click-to-focus match key) |
| `transcript` | Path to the agent's transcript (powers the preview) |
| `msg` | Last assistant message (preview + banner body) |
| `pid` | The agent's pid (so `kill` can terminate it) |
| `host` | Terminal that launched the agent (e.g. `ghostty`) — for click-to-focus |
| `mux` | `tmux` / `zellij` — which backend the detached click handler drives |
| `ts` | Last-update unix timestamp (drives age + TTL pruning) |

**Lifecycle.** Hooks write the file on every state change. `SessionEnd` (or
Codex end) removes it. Crashed sessions that never send an end event are pruned
by `AGENTDECK_TTL` (a file untouched longer than the TTL is dropped on the next
`list`/`pick`). `host`/`mux` are detected at hook time; state written before this
release lacks them and click-to-focus degrades to bringing the app forward.

## Multiplexer behavior

### tmux

- **Jump** (`mux_jump`): inside tmux, `switch-client` to the window; otherwise
  `select-window` then `attach`.
- **Select** (`mux_select`, click-to-focus): `select-window` on the resolved
  window id **without attaching** — safe from the detached click context.
- Windows are resolved to their unique `@N` id by exact name match, never
  targeted by the colon-bearing `repo:branch` string (tmux target syntax is
  `session:window`).

### zellij

- **Jump**: set the tab title, attach, then go to the tab once a client is
  connected (rename/go-to are no-ops while detached).
- **Select** on click is currently a **no-op** — zellij can't select a tab in a
  detached/other session from outside the way tmux can. The host app still comes
  forward.
- Jumping across zellij sessions requires detaching first (you can't attach a
  session from inside another).

## Agent wiring details

### Claude Code

Hooks in `~/.claude/settings.json` map to states:

| Event | State |
|---|---|
| `SessionStart` / `UserPromptSubmit` | working / session bookkeeping |
| `Notification` | waiting |
| `Stop` | idle (finished) |
| `SessionEnd` | gone (file removed) |

Each hook pipes its JSON to `agentdeck ingest claude` on stdin.

### Codex

- **Hooks** (`~/.codex/hooks.json`) cover working / idle / end — these are exact.
- **`notify`** (`~/.codex/config.toml`) carries the `waiting` signal. Because
  Codex's `notify` payload has no session id or cwd, agentdeck keys off the
  current directory and updates the newest matching Codex session. This is
  best-effort until Codex exposes `approval-requested` to hooks.

## Extending

### A new agent — `lib/agents/<name>.sh`

Model it on `claude.sh`. Define:

- `AGENT_F_SID` / `AGENT_F_CWD` / `AGENT_F_TRANSCRIPT` — jq paths into the hook JSON.
- `agent_detect` — is this agent installed?
- `agent_state_for <event>` — map a hook event to `idle` / `working` / `waiting` / `gone` / `skip`.
- `agent_notify_state <type>` — same, for the out-of-band `notify` transport (or `echo skip`).
- `agent_installed` / `agent_install <self>` — check and idempotently wire the hook.

Then add an icon for it to `_agentdeck_icon_json` in `lib/core.sh`.

### A new multiplexer — `lib/mux/<name>.sh`

Implement three functions:

- `mux_jump <proj> <tab>` — focus that session's tab (powers `pick`).
- `mux_launch <proj> <tab> <cwd> <cmd>` — open a new tab running `<cmd>` (powers `new`).
- `mux_select <proj> <tab>` — select that window **without attaching** (powers
  click-to-focus, which runs detached with no tty). Return non-zero if the
  session/window is gone so the caller degrades gracefully.

Use `lib/mux/tmux.sh` and `lib/mux/zellij.sh` as references.

## Troubleshooting

Start with `agentdeck doctor` — it prints your deps, detected agents, wiring
status, and which notifier is active.

### No board / "no active agent sessions"

- `agentdeck doctor` → is `fzf`/`jq` present, are agents detected and wired?
- `agentdeck list` → any rows? If empty, hooks aren't firing. Re-run
  `agentdeck install` and confirm the hook lines in the agent's config.
- Sessions auto-prune after `AGENTDECK_TTL`; a long-idle session may have been
  dropped.

### No notification banner appears

This is usually a macOS permission/style issue with terminal-notifier, **not**
agentdeck:

1. `command -v terminal-notifier` — installed? If not: `brew install terminal-notifier`.
   Without it, agentdeck falls back to osascript (banner only, no click).
2. **System Settings → Notifications → terminal-notifier** → *Allow Notifications*
   ON, style **Alerts**. A freshly installed terminal-notifier often starts
   unregistered/disallowed and macOS silently drops its banners.
3. Check it isn't being suppressed by **Focus / Do Not Disturb**.
4. `terminal-notifier -list ALL` — if your notifications appear here, they were
   *delivered* (the issue is display style/Focus, not delivery).
5. Still missing from the settings list? Re-register the app bundle:
   `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(find /opt/homebrew/Cellar/terminal-notifier -name '*.app' -maxdepth 3 -type d | head -1)"`

### Clicking the banner doesn't jump

- **First click** prompts to allow *terminal-notifier to control your terminal* —
  you must click **Allow**. The first click may be consumed by the prompt; click
  the next banner.
- **The target tab was closed**, or its cwd no longer matches (multiple windows
  in one tmux session): click-to-focus matches by working directory, so it falls
  back to just bringing the host app forward. This is expected.
- **Non-Ghostty terminal**: precise tab focus is Ghostty-only today; others just
  come forward. Force a tier with `AGENTDECK_NOTIFY_FOCUS=app:<bundle-id>` if the
  host isn't detected.
- **Disabled**: check `AGENTDECK_NOTIFY_FOCUS` isn't `off`.

### Clicking jumps to a Finder folder

That's the old behavior of terminal-notifier with no click action. Upgrade to a
build of agentdeck that ships click-to-focus (it attaches an `-execute`), and
make sure `AGENTDECK_NOTIFY_FOCUS` isn't `off`.

## FAQ

**Do I need tmux/zellij?** Yes — agentdeck launches and jumps to agents through a
multiplexer. The board reads plain state files, but jumping needs a backend.

**Does click-to-focus work on Linux?** No. It's macOS + terminal-notifier. On
Linux you still get banners via notify-send.

**Will it mess with my existing Claude/Codex config?** No. `agentdeck install` is
idempotent and only adds its own entries; it won't overwrite an existing Codex
`notify` (it prints the line instead).

**Can I see the active notifier?** `agentdeck doctor` prints it.

**Where are the state files?** `agentdeck dir`.
