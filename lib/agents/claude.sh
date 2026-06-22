# Agent profile: Claude Code (https://claude.com/claude-code)
#
# A profile is just: an icon, a detector, the field paths into the hook JSON,
# an event→state map, and how to wire/check the hook. Claude's hooks deliver
# JSON on stdin with session_id / cwd / transcript_path / hook_event_name.

AGENT_F_SID='.session_id'
AGENT_F_CWD='.cwd'
AGENT_F_TRANSCRIPT='.transcript_path'

agent_detect() { command -v claude >/dev/null 2>&1 || [[ -e "$HOME/.claude/settings.json" ]]; }

agent_state_for() {
  case "$1" in
    SessionStart|Stop|SubagentStop)          echo idle ;;
    UserPromptSubmit|PreToolUse|PostToolUse) echo working ;;
    Notification)                            echo waiting ;;
    SessionEnd)                              echo gone ;;
    *)                                       echo skip ;;
  esac
}

# Claude exposes a real Notification event, so it never needs the notify path.
agent_notify_state() { echo skip; }

_claude_cfg() { printf '%s' "$HOME/.claude/settings.json"; }
_claude_cmd() { printf '"%s" ingest claude' "$1"; }

agent_installed() {
  jq -e --arg c "$(_claude_cmd "$(_self)")" \
    '[.hooks[]?[]?.hooks[]?.command] | index($c) != null' "$(_claude_cfg)" >/dev/null 2>&1
}

# Idempotently add our ingest command to each relevant hook event, preserving
# any hooks the user already configured.
agent_install() {
  local self="$1" cfg cmd tmp
  cfg="$(_claude_cfg)"; cmd="$(_claude_cmd "$self")"
  mkdir -p "$(dirname "$cfg")"; [[ -f "$cfg" ]] || echo '{}' > "$cfg"
  tmp="$(mktemp)"
  jq --arg cmd "$cmd" '
    .hooks = (.hooks // {}) |
    reduce ("SessionStart","UserPromptSubmit","Notification","Stop","SessionEnd") as $ev (.;
      .hooks[$ev] = (
        ((.hooks[$ev] // []) | map(select(([.hooks[]?.command] | index($cmd)) | not)))
        + [{hooks: [{type: "command", command: $cmd}]}]
      ))
  ' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
}
