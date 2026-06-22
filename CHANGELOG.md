# Changelog

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
