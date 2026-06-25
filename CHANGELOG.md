# Changelog

## [Unreleased]

### Added
- feat(notify): clicking a banner now jumps back to the waiting agent — Ghostty
  focuses the exact tab, other terminals come forward, VS Code reuses the project
  window. Configurable via `AGENTDECK_NOTIFY_FOCUS`. Fixes the old behaviour where
  clicking opened terminal-notifier's install folder in Finder.
- Multiplexer adapter: **tmux** (`lib/mux/tmux.sh`) — `jump` switches/attaches to
  a session's window; `new` opens a window running the agent, creating the session
  if needed. Windows are resolved by id (not the colon-bearing `repo:branch` name)
  and `automatic-rename` is disabled so jump targets stay stable (#1).
- Configurable notification icon: `AGENTDECK_NOTIFY_SENDER` (borrow another app's
  icon + identity by bundle id) and `AGENTDECK_NOTIFY_ICON` (custom image). Both
  require `terminal-notifier`; no effect on the osascript fallback.
- Simplified Chinese README (`README.zh-CN.md`), cross-linked with the English one.

### Changed
- `_derive_names` now uses the tmux session name as the project when running
  inside tmux, mirroring the existing zellij behavior.
- Stop notification falls back to the repo name instead of the full cwd path.

### Fixed
- osascript notifications no longer show mojibake for the ✅ emoji or non-ASCII
  messages: force `__CF_USER_TEXT_ENCODING` to UTF-8, which hook/launchd
  subprocesses often lack (CoreFoundation otherwise decodes our UTF-8 as MacRoman).

## [0.1.0] - 2026-06-22

### Added
- Initial scaffold: `agentdeck` CLI with `ingest`, `pick`, `new`, `list`,
  `preview`, `kill`, `forget`, `install`, `doctor`.
- Agent profiles: **Claude Code** and **Codex** (shared hook schema; Codex
  `waiting` via the `notify` program until `approval-requested` lands in hooks).
- Multiplexer adapter: **zellij**. tmux planned for v0.2 (stub in place).
- Portable desktop notifications: terminal-notifier → osascript → notify-send.
- **Real kill** (Ctrl-x): ingest records the agent pid (walking the process
  tree); `kill` SIGTERMs it after verifying the live process still matches the
  agent (guards against pid reuse). **Ctrl-d** forgets a row without killing.
- **`agentdeck new [agent]`**: launch an agent in the current project's tab
  (zellij, via a generated one-off layout).
