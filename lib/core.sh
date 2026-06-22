# core.sh — agentdeck shared engine. Sourced by bin/agentdeck.
#
# Everything here is agent- and multiplexer-agnostic: the state store, the fzf
# board, notifications, ranking. The only parts that vary live behind two thin
# adapter axes loaded on demand:
#   lib/agents/<name>.sh  — how an agent's events map to state, + how to wire it
#   lib/mux/<name>.sh     — how to jump to a session's tab in a multiplexer
#
# State lives as one JSON file per session under $AGENTDECK_STATE_DIR, named
# "<agent>-<session_id>.json". This replaces tmux's per-session variables and is
# what makes the board work across agents and multiplexers uniformly.

AGENTDECK_VERSION="0.1.0"

# Per-agent palette for the board (kept distinct from the 🔴🟡🟢 state dots).
_agentdeck_icon_json='{"claude":"🟣","codex":"🔵","gemini":"🟤","aider":"🟠"}'

# ── adapters ──────────────────────────────────────────────────────────────────
_load_agent() {
  local a="$1"
  [[ -f "$AGENTDECK_LIB/agents/$a.sh" ]] || { echo "agentdeck: unknown agent '$a'" >&2; return 2; }
  # shellcheck source=/dev/null
  source "$AGENTDECK_LIB/agents/$a.sh"
}

_load_mux() {
  local m="${AGENTDECK_MUX:-}"
  if [[ -z "$m" ]]; then
    if   [[ -n "${ZELLIJ:-}" ]]; then m=zellij
    elif [[ -n "${TMUX:-}"   ]]; then m=tmux
    else m=zellij; fi
  fi
  [[ -f "$AGENTDECK_LIB/mux/$m.sh" ]] || { echo "agentdeck: unknown multiplexer '$m'" >&2; return 2; }
  # shellcheck source=/dev/null
  source "$AGENTDECK_LIB/mux/$m.sh"
}

_self() { printf '%s' "$AGENTDECK_ROOT/bin/agentdeck"; }

# ── naming: cwd → project (= mux session) + tab (= repo:branch) ────────────────
# Mirrors the zellij zj/zjp convention so the picker maps cleanly back to a tab.
# Sets globals `proj` and `tab`.
_derive_names() {
  local cwd="${1:-$PWD}" branch repo remote
  proj="${ZELLIJ_SESSION_NAME:-}"
  branch="$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null \
            || git -C "$cwd" rev-parse --short HEAD 2>/dev/null || true)"
  repo=""
  if remote="$(git -C "$cwd" config --get remote.origin.url 2>/dev/null)"; then
    repo="${remote%.git}"; repo="${repo##*/}"; repo="${repo##*:}"
  fi
  [[ -n "$repo" ]] || repo="$(basename "${cwd:-$PWD}")"
  [[ -n "$proj" ]] || proj="$repo"
  if [[ -n "$branch" ]]; then tab="$repo:$branch"; else tab="$(basename "${cwd:-$PWD}")"; fi
}

# ── notifications (portable: macOS / Linux) ───────────────────────────────────
_notify() {
  local title="${1//[\"\\]/ }" msg="${2//[\"\\]/ }"
  if   command -v terminal-notifier >/dev/null 2>&1; then
    terminal-notifier -title "$title" -message "$msg" >/dev/null 2>&1 || true
  elif command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$msg\" with title \"$title\" sound name \"Glass\"" >/dev/null 2>&1 || true
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "$title" "$msg" >/dev/null 2>&1 || true
  fi
}

# ── state file IO ─────────────────────────────────────────────────────────────
# _persist <agent> <sid> <state> <proj> <tab> <cwd> <transcript> <msg>
_persist() {
  mkdir -p "$AGENTDECK_STATE_DIR"
  local agent="$1" sid="$2" state="$3" proj="$4" tab="$5" cwd="$6" transcript="$7" msg="$8"
  local file="$AGENTDECK_STATE_DIR/${agent}-${sid//[^A-Za-z0-9._-]/-}.json"
  # Preserve the last non-empty assistant message across state-only updates.
  [[ -z "$msg" && -f "$file" ]] && msg="$(jq -r '.msg // empty' "$file" 2>/dev/null || true)"
  jq -n --arg id "$sid" --arg agent "$agent" --arg state "$state" \
        --arg proj "$proj" --arg tab "$tab" --arg cwd "$cwd" \
        --arg transcript "$transcript" --arg msg "$msg" --argjson ts "$(date +%s)" \
    '{id:$id, agent:$agent, state:$state, proj:$proj, tab:$tab,
      cwd:$cwd, transcript:$transcript, msg:$msg, ts:$ts}' > "$file"
}

# ── ingest: the hook entrypoint ───────────────────────────────────────────────
core_ingest() {
  local agent="${1:-}"; shift || true
  [[ -n "$agent" ]] || { echo "agentdeck ingest: need an agent name" >&2; return 2; }
  _load_agent "$agent"
  if [[ "${1:-}" == "--notify" ]]; then
    _ingest_notify "$agent" "${2:-}"
  else
    _ingest_hook "$agent"
  fi
}

# Hooks transport (Claude + Codex): JSON on stdin, identical field names.
_ingest_hook() {
  local agent="$1" input event state sid cwd transcript msg
  input="$(cat)"
  event="$(jq -r '.hook_event_name // empty' <<<"$input")"
  state="$(agent_state_for "$event")"
  [[ "$state" == "skip" ]] && return 0
  sid="$(jq -r "${AGENT_F_SID} // empty" <<<"$input")"
  [[ -n "$sid" ]] || return 0
  if [[ "$state" == "gone" ]]; then
    rm -f "$AGENTDECK_STATE_DIR/${agent}-${sid//[^A-Za-z0-9._-]/-}.json"
    return 0
  fi
  cwd="$(jq -r "${AGENT_F_CWD} // empty" <<<"$input")"
  transcript="$(jq -r "${AGENT_F_TRANSCRIPT} // empty" <<<"$input")"
  msg="$(jq -r '.last_assistant_message // empty' <<<"$input" | head -c 280)"
  _derive_names "$cwd"
  _persist "$agent" "$sid" "$state" "$proj" "$tab" "$cwd" "$transcript" "$msg"

  # Ambient banner: the one signal that works no matter which tab is focused.
  case "$event" in
    Notification) _notify "⏳ $tab 在等你" "${msg:-需要确认}" ;;
    Stop) [[ "$AGENTDECK_NOTIFY_ON_STOP" == "1" ]] && _notify "✅ $tab 跑完了" "${msg:-$cwd}" ;;
  esac
  return 0
}

# notify transport (Codex): JSON as a single argv token, no session_id and no
# cwd (codex issue #4005), so we key off the agent's PWD and update the newest
# matching session. Best-effort until approval-requested lands in hooks (#14813).
_ingest_notify() {
  local agent="$1" payload="$2" type state cwd file sid msg
  type="$(jq -r '.type // empty' <<<"$payload")"
  state="$(agent_notify_state "$type" 2>/dev/null || echo skip)"
  [[ "$state" == "skip" || -z "$state" ]] && return 0
  cwd="$PWD"
  _derive_names "$cwd"
  file="$( { ls -t "$AGENTDECK_STATE_DIR/${agent}-"*.json 2>/dev/null || true; } | while read -r f; do
             [[ "$(jq -r '.cwd' "$f" 2>/dev/null)" == "$cwd" ]] && { printf '%s' "$f"; break; }
           done )"
  if [[ -n "$file" ]]; then sid="$(jq -r '.id' "$file")"; else sid="notify-${tab//[^A-Za-z0-9._-]/-}"; fi
  msg="$(jq -r '."last-assistant-message" // .last_assistant_message // empty' <<<"$payload" | head -c 280)"
  _persist "$agent" "$sid" "$state" "$proj" "$tab" "$cwd" "" "$msg"
  [[ "$state" == "waiting" ]] && _notify "⏳ $tab 在等你" "${msg:-需要确认}"
  return 0
}

# ── list / preview / kill ─────────────────────────────────────────────────────
# Columns (TSV): prio  dot  agent  tab  age  proj  file
# prio/proj/file are hidden in the picker (sort key / jump target / preview key).
core_list() {
  mkdir -p "$AGENTDECK_STATE_DIR"
  # Prune dead sessions that never sent SessionEnd (crash, kill -9).
  find "$AGENTDECK_STATE_DIR" -name '*.json' -type f -mmin "+$((AGENTDECK_TTL / 60))" -delete 2>/dev/null || true
  shopt -s nullglob
  local f
  for f in "$AGENTDECK_STATE_DIR"/*.json; do
    jq -r --argjson ttl "$AGENTDECK_TTL" --argjson icons "$_agentdeck_icon_json" '
      (now - .ts) as $age |
      if $age > $ttl then empty else
        (if .state=="waiting" then "0" elif .state=="working" then "1" else "2" end) as $prio |
        (if .state=="waiting" then "🟡" elif .state=="working" then "🔴" else "🟢" end) as $dot |
        ($icons[.agent] // "⚪") as $ai |
        [$prio, $dot, $ai, .tab, (($age|floor|tostring)+"s"), .proj,
         (input_filename|split("/")|last)] | @tsv
      end' "$f"
  done | sort -t"$(printf '\t')" -k1,1n
}

core_preview() {
  local f="$AGENTDECK_STATE_DIR/$(basename "${1:-}")" t msg
  [[ -f "$f" ]] || { echo "(session gone)"; return 0; }
  jq -C '{agent, proj, tab, state, cwd, age_seconds:((now - .ts)|floor)}' "$f"
  echo; echo "── recent ─────────────────"
  msg="$(jq -r '.msg // empty' "$f")"
  [[ -n "$msg" ]] && { printf '%s\n\n' "$msg"; }
  t="$(jq -r '.transcript // empty' "$f")"
  [[ -f "$t" ]] || return 0
  tail -n 120 "$t" | jq -rR '
    fromjson? | select(.type=="assistant") | .message.content |
    if type=="string" then . else (.[]? | select(.type=="text") | .text) end
  ' 2>/dev/null | tail -n 20
}

core_kill() {
  local b; b="$(basename "${1:-}")"
  [[ -n "$b" && "$b" == *.json ]] && rm -f "$AGENTDECK_STATE_DIR/$b"
}

# ── pick: the fzf board ───────────────────────────────────────────────────────
core_pick() {
  command -v fzf >/dev/null 2>&1 || { echo "agentdeck: fzf not installed" >&2; return 1; }
  local self list sel proj tab
  self="$(_self)"
  list="$(core_list)"
  [[ -n "$list" ]] || { echo "agentdeck: no active agent sessions" >&2; return 0; }
  sel="$(printf '%s\n' "$list" | fzf --no-multi --delimiter=$'\t' --with-nth=2,3,4,5 \
        --prompt='agentdeck> ' \
        --header='🟡 waiting · 🔴 working · 🟢 idle    │ Enter: jump · Ctrl-x: forget' \
        --preview="$self preview {7}" --preview-window='right,55%,wrap' \
        --bind="ctrl-x:execute-silent($self kill {7})+reload($self list)")" || return 0
  [[ -n "$sel" ]] || return 0
  tab="$(printf '%s' "$sel" | cut -f4)"
  proj="$(printf '%s' "$sel" | cut -f6)"
  [[ -n "$proj" && -n "$tab" ]] || return 0
  _load_mux
  mux_jump "$proj" "$tab"
}

# ── install / doctor ──────────────────────────────────────────────────────────
core_install() {
  local agents=("$@")
  (( ${#agents[@]} )) || agents=(claude codex)
  local a
  for a in "${agents[@]}"; do
    _load_agent "$a" || continue
    if ! agent_detect; then echo "– skip $a (not installed)"; continue; fi
    agent_install "$(_self)" && echo "✓ wired $a → agentdeck"
  done
  echo "Done. New agent sessions will appear in: agentdeck pick"
}

core_doctor() {
  printf 'agentdeck %s\n' "$AGENTDECK_VERSION"
  printf 'state dir: %s\n' "$AGENTDECK_STATE_DIR"
  printf 'deps:\n'
  local d
  for d in jq fzf; do command -v "$d" >/dev/null 2>&1 && echo "  ✓ $d" || echo "  ✗ $d (required)"; done
  printf 'notifier: %s\n' "$(command -v terminal-notifier || command -v osascript || command -v notify-send || echo none)"
  printf 'agents:\n'
  local a
  for a in claude codex; do
    _load_agent "$a" || continue
    if agent_detect; then
      if agent_installed; then echo "  ✓ $a (wired)"; else echo "  ○ $a (installed, not wired — run: agentdeck install $a)"; fi
    else
      echo "  – $a (not installed)"
    fi
  done
  local mux=none; [[ -n "${ZELLIJ:-}" ]] && mux=zellij; [[ -n "${TMUX:-}" ]] && mux=tmux
  printf 'multiplexer: %s\n' "$mux"
}

core_usage() {
  cat <<'EOF'
agentdeck — mission control for terminal coding agents

  agentdeck pick                 Open the board (fzf): jump to the session needing you
  agentdeck install [agent…]     Wire the hook into Claude / Codex configs
  agentdeck doctor               Check deps, detected agents, wiring status
  agentdeck list                 Print raw rows (scriptable)
  agentdeck ingest <agent>       Hook entrypoint (agents call this; not for humans)
  agentdeck version | help

State: 🟡 waiting (needs you) · 🔴 working · 🟢 idle (done)
Docs:  https://github.com/huiyu/agentdeck
EOF
}
