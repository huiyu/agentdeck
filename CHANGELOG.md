# Changelog

## [Unreleased]

### Added
- Initial scaffold: `agentdeck` CLI with `ingest`, `pick`, `list`, `preview`,
  `kill`, `install`, `doctor`.
- Agent profiles: **Claude Code** and **Codex** (shared hook schema; Codex
  `waiting` via the `notify` program until `approval-requested` lands in hooks).
- Multiplexer adapter: **zellij**. tmux planned for v0.2 (stub in place).
- Portable desktop notifications: terminal-notifier → osascript → notify-send.
