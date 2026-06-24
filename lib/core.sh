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

# Resolve the multiplexer name from config/env (no sourcing). Recorded in state
# so the detached click handler knows which backend to drive.
_mux_name() {
  local m="${AGENTDECK_MUX:-}"
  if [[ -z "$m" ]]; then
    if   [[ -n "${ZELLIJ:-}" ]]; then m=zellij
    elif [[ -n "${TMUX:-}"   ]]; then m=tmux
    else m=zellij; fi
  fi
  printf '%s' "$m"
}

_load_mux() {
  local m; m="$(_mux_name)"
  [[ -f "$AGENTDECK_LIB/mux/$m.sh" ]] || { echo "agentdeck: unknown multiplexer '$m'" >&2; return 2; }
  # shellcheck source=/dev/null
  source "$AGENTDECK_LIB/mux/$m.sh"
}

# Best-effort host terminal (raw TERM_PROGRAM). Inside tmux, TERM_PROGRAM is
# overwritten with "tmux", but the server keeps the real value in its global
# environment — recover it from there. Empty when undetectable.
_detect_host() {
  local tp="${TERM_PROGRAM:-}"
  if { [[ -z "$tp" || "$tp" == "tmux" ]]; } && command -v tmux >/dev/null 2>&1; then
    tp="$(tmux show-environment -g TERM_PROGRAM 2>/dev/null | sed -n 's/^TERM_PROGRAM=//p')"
  fi
  printf '%s' "$tp"
}

_self() { printf '%s' "$AGENTDECK_ROOT/bin/agentdeck"; }

# The command string to bake into an agent's config. Prefer the stable launcher
# `$HOME/.local/bin/agentdeck` (kept literal so it stays portable across machines
# and survives the repo moving) when it links back to us; else the resolved path.
_self_cmd() {
  local link="$HOME/.local/bin/agentdeck"
  if [[ -L "$link" && "$(readlink "$link" 2>/dev/null)" == "$AGENTDECK_ROOT/bin/agentdeck" ]]; then
    printf '$HOME/.local/bin/agentdeck'
  else
    printf '%s' "$AGENTDECK_ROOT/bin/agentdeck"
  fi
}

# Best-effort: find the agent's own pid by walking up from the hook's parent.
# Hooks are spawned by the agent, so the nearest ancestor whose command matches
# the agent (Claude may run as `node`) is it. Stored so `kill` can really stop it.
_agent_pid() {
  local want="$1" pid="$PPID" depth=0 comm pat
  case "$want" in claude) pat='^(claude|node)$' ;; *) pat="^${want}$" ;; esac
  while [[ -n "$pid" && "$pid" != 0 && "$pid" != 1 && $depth -lt 8 ]]; do
    comm="$(ps -o comm= -p "$pid" 2>/dev/null | sed 's#.*/##' || true)"
    [[ "$comm" =~ $pat ]] && { printf '%s' "$pid"; return 0; }
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    depth=$((depth + 1))
  done
  return 1
}

# ── naming: cwd → project (= mux session) + tab (= repo:branch) ────────────────
# Mirrors the zellij zj/zjp convention so the picker maps cleanly back to a tab.
# Sets globals `proj`, `tab`, and `repo`.
_derive_names() {
  local cwd="${1:-$PWD}" branch remote
  proj="${ZELLIJ_SESSION_NAME:-}"
  # Inside tmux (no zellij): the session name is the project, mirroring zellij.
  [[ -z "$proj" && -n "${TMUX:-}" ]] && proj="$(tmux display-message -p '#S' 2>/dev/null || true)"
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
    # Optional custom icon: AGENTDECK_NOTIFY_SENDER borrows another app's icon
    # and identity (a bundle id, e.g. com.apple.Terminal); AGENTDECK_NOTIFY_ICON
    # is a path/URL to a custom image. Both are no-ops on the osascript path,
    # whose icon is locked to Script Editor by macOS.
    local -a tn=(-title "$title" -message "$msg")
    [[ -n "${AGENTDECK_NOTIFY_SENDER:-}" ]] && tn+=(-sender "$AGENTDECK_NOTIFY_SENDER")
    [[ -n "${AGENTDECK_NOTIFY_ICON:-}"   ]] && tn+=(-appIcon "$AGENTDECK_NOTIFY_ICON")
    terminal-notifier "${tn[@]}" >/dev/null 2>&1 || true
  elif command -v osascript >/dev/null 2>&1; then
    # Force UTF-8 for AppleScript text: CoreFoundation picks the encoding from
    # __CF_USER_TEXT_ENCODING, which hook/launchd subprocesses often lack — then
    # osascript decodes our UTF-8 as MacRoman and the banner shows mojibake.
    __CF_USER_TEXT_ENCODING=0x0:0x8000100:0x8000100 \
      osascript -e "display notification \"$msg\" with title \"$title\" sound name \"Glass\"" >/dev/null 2>&1 || true
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "$title" "$msg" >/dev/null 2>&1 || true
  fi
}

# ── state file IO ─────────────────────────────────────────────────────────────
# _persist <agent> <sid> <state> <proj> <tab> <cwd> <transcript> <msg> [pid]
_persist() {
  mkdir -p "$AGENTDECK_STATE_DIR"
  local agent="$1" sid="$2" state="$3" proj="$4" tab="$5" cwd="$6" transcript="$7" msg="$8" pid="${9:-}"
  local file="$AGENTDECK_STATE_DIR/${agent}-${sid//[^A-Za-z0-9._-]/-}.json"
  # Preserve the last non-empty message and the pid across state-only updates
  # (e.g. the codex notify path has neither).
  [[ -z "$msg" && -f "$file" ]] && msg="$(jq -r '.msg // empty' "$file" 2>/dev/null || true)"
  [[ -z "$pid" && -f "$file" ]] && pid="$(jq -r '.pid // empty' "$file" 2>/dev/null || true)"
  local host mux
  host="$(_detect_host)"; mux="$(_mux_name)"
  jq -n --arg id "$sid" --arg agent "$agent" --arg state "$state" \
        --arg proj "$proj" --arg tab "$tab" --arg cwd "$cwd" \
        --arg transcript "$transcript" --arg msg "$msg" --arg pid "$pid" \
        --arg host "$host" --arg mux "$mux" \
        --argjson ts "$(date +%s)" \
    '{id:$id, agent:$agent, state:$state, proj:$proj, tab:$tab,
      cwd:$cwd, transcript:$transcript, msg:$msg,
      pid:(if $pid=="" then null else ($pid|tonumber) end),
      host:$host, mux:$mux, ts:$ts}' > "$file"
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
  local agent="$1" input event state sid cwd transcript msg pid
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
  pid="$(_agent_pid "$agent" || true)"
  _derive_names "$cwd"
  _persist "$agent" "$sid" "$state" "$proj" "$tab" "$cwd" "$transcript" "$msg" "$pid"

  # Ambient banner: the one signal that works no matter which tab is focused.
  case "$event" in
    Notification) _notify "⏳ $tab is waiting on you" "${msg:-needs input}" ;;
    Stop) [[ "$AGENTDECK_NOTIFY_ON_STOP" == "1" ]] && _notify "✅ $tab finished" "${msg:-$repo}" ;;
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
  _persist "$agent" "$sid" "$state" "$proj" "$tab" "$cwd" "" "$msg" ""
  [[ "$state" == "waiting" ]] && _notify "⏳ $tab is waiting on you" "${msg:-needs input}"
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

# kill: actually terminate the agent (SIGTERM its pid), then drop the state file.
# Verifies the live process still belongs to the agent before signalling, so a
# reused pid can't get an innocent process killed. The agent's own SessionEnd
# hook also removes the file; the rm here covers crashed/pid-less sessions.
core_kill() {
  local b f pid agent comm
  b="$(basename "${1:-}")"; [[ -n "$b" && "$b" == *.json ]] || return 0
  f="$AGENTDECK_STATE_DIR/$b"
  if [[ -f "$f" ]]; then
    pid="$(jq -r '.pid // empty' "$f" 2>/dev/null || true)"
    agent="$(jq -r '.agent // empty' "$f" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      comm="$(ps -o comm= -p "$pid" 2>/dev/null | sed 's#.*/##' || true)"
      case "${agent}::${comm}" in
        claude::claude|claude::node|*"::${agent}") kill "$pid" 2>/dev/null || true ;;
      esac
    fi
  fi
  rm -f "$f"
}

# forget: drop the state file only, leaving the agent running (for stale rows).
core_forget() {
  local b; b="$(basename "${1:-}")"
  [[ -n "$b" && "$b" == *.json ]] && rm -f "$AGENTDECK_STATE_DIR/$b"
}

# new: launch (or focus a tab for) an agent in the current directory's project.
core_new() {
  local agent="${1:-}" a cwd="$PWD"
  if [[ -z "$agent" ]]; then
    for a in claude codex; do
      _load_agent "$a" 2>/dev/null && agent_detect && { agent="$a"; break; }
    done
  fi
  [[ -n "$agent" ]] || { echo "agentdeck new: no agent given and none detected" >&2; return 2; }
  _load_agent "$agent" || return 2
  agent_detect || { echo "agentdeck new: '$agent' is not installed" >&2; return 2; }
  _derive_names "$cwd"
  _load_mux
  mux_launch "$proj" "$tab" "$cwd" "$agent"
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
        --header='🟡 waiting · 🔴 working · 🟢 idle    │ Enter: jump · Ctrl-x: kill · Ctrl-d: forget' \
        --preview="$self preview {7}" --preview-window='right,55%,wrap' \
        --bind="ctrl-x:execute-silent($self kill {7})+reload($self list)" \
        --bind="ctrl-d:execute-silent($self forget {7})+reload($self list)")" || return 0
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
    agent_install "$(_self_cmd)" && echo "✓ wired $a → agentdeck"
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
  agentdeck new [agent]          Launch an agent in this directory's project tab
  agentdeck install [agent…]     Wire the hook into Claude / Codex configs
  agentdeck doctor               Check deps, detected agents, wiring status
  agentdeck list                 Print raw rows (scriptable)
  agentdeck dir                  Print the state directory (scriptable)
  agentdeck ingest <agent>       Hook entrypoint (agents call this; not for humans)
  agentdeck version | help

In the board: Enter jumps · Ctrl-x kills the agent · Ctrl-d forgets the row

State: 🟡 waiting (needs you) · 🔴 working · 🟢 idle (done)
Docs:  https://github.com/huiyu/agentdeck
EOF
}
