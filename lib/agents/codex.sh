# Agent profile: OpenAI Codex CLI (https://developers.openai.com/codex)
#
# Codex converged on the same hook design as Claude Code: JSON on stdin with
# identical field names (session_id / cwd / transcript_path / hook_event_name)
# and the same event set — so the field paths and most of the state map are
# shared. Two differences from Claude:
#   1. Hooks are wired via ~/.codex/hooks.json (not a settings.json block).
#   2. There is no "Notification" hook yet; the "needs you" (approval-requested)
#      signal is only delivered to the `notify` program (argv JSON). So we wire
#      both: hooks.json for working/idle/end, and notify for waiting.
#      Tracking: https://github.com/openai/codex/issues/14813

AGENT_F_SID='.session_id'
AGENT_F_CWD='.cwd'
AGENT_F_TRANSCRIPT='.transcript_path'

agent_detect() { command -v codex >/dev/null 2>&1 || [[ -d "$HOME/.codex" ]]; }

agent_state_for() {
  case "$1" in
    SessionStart|Stop)                       echo idle ;;
    UserPromptSubmit|PreToolUse|PostToolUse) echo working ;;
    SessionEnd)                              echo gone ;;
    *)                                       echo skip ;;
  esac
}

# notify payload .type → state (the waiting signal Codex hooks don't carry yet).
agent_notify_state() {
  case "$1" in
    approval-requested)  echo waiting ;;
    agent-turn-complete) echo idle ;;
    *)                   echo skip ;;
  esac
}

_codex_hooks_json() { printf '%s' "$HOME/.codex/hooks.json"; }
_codex_config()     { printf '%s' "$HOME/.codex/config.toml"; }
_codex_cmd()        { printf '"%s" ingest codex' "$1"; }

agent_installed() {
  jq -e --arg c "$(_codex_cmd "$(_self)")" \
    '[.hooks[]?[]?.hooks[]?.command] | index($c) != null' "$(_codex_hooks_json)" >/dev/null 2>&1
}

agent_install() {
  local self="$1" hj cmd tmp ct
  hj="$(_codex_hooks_json)"; cmd="$(_codex_cmd "$self")"
  mkdir -p "$HOME/.codex"; [[ -f "$hj" ]] || echo '{}' > "$hj"
  tmp="$(mktemp)"
  jq --arg cmd "$cmd" '
    .hooks = (.hooks // {}) |
    reduce ("SessionStart","UserPromptSubmit","Stop","SessionEnd") as $ev (.;
      .hooks[$ev] = (
        ((.hooks[$ev] // []) | map(select(([.hooks[]?.command] | index($cmd)) | not)))
        + [{hooks: [{type: "command", command: $cmd}]}]
      ))
  ' "$hj" > "$tmp" && mv "$tmp" "$hj"

  # notify (waiting). Only append if the user has no notify yet — never clobber.
  ct="$(_codex_config)"; touch "$ct"
  if grep -qE '^[[:space:]]*notify[[:space:]]*=' "$ct"; then
    {
      echo "  ! ~/.codex/config.toml already sets 'notify' — for the 'waiting' state, set it to:"
      echo "      notify = [\"$self\", \"ingest\", \"codex\", \"--notify\"]"
    } >&2
  else
    printf '\nnotify = ["%s", "ingest", "codex", "--notify"]\n' "$self" >> "$ct"
  fi
}
