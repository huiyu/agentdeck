# Multiplexer adapter: tmux.
#
# The board is mux-agnostic; only "where am I" and "jump there" are not. Unlike
# zellij, tmux can target a window in a detached session by name, and new-window
# takes both a cwd (-c) and a command directly — so this adapter is simpler than
# the zellij one (no throwaway layout, no sleep-then-rename dance).
#
# agentdeck's `tab` is `repo:branch`, which contains a colon — and tmux's target
# syntax is `session:window`. To avoid that ambiguity we never target a window by
# its `proj:tab` name string; we resolve the window's unique id (@N) by exact
# name match and target that instead.

# Resolve <proj>'s window named exactly <tab> to its window id (@N). Empty if none.
_tmux_window_id() {
  local proj="$1" tab="$2"
  tmux list-windows -t "=$proj" -F $'#{window_id}\t#{window_name}' 2>/dev/null \
    | awk -F'\t' -v n="$tab" '$2==n {print $1; exit}'
}

# Jump to <proj>'s <tab>. Switch in place when already inside tmux, otherwise
# select the target window and attach.
mux_jump() {
  local proj="$1" tab="$2" wid
  tmux has-session -t "=$proj" 2>/dev/null \
    || { echo "agentdeck: tmux session '$proj' not found" >&2; return 1; }
  wid="$(_tmux_window_id "$proj" "$tab")"
  [[ -n "$wid" ]] \
    || { echo "agentdeck: window '$tab' not found in tmux session '$proj'" >&2; return 1; }
  if [[ -n "${TMUX:-}" ]]; then
    tmux switch-client -t "$wid"
  else
    [[ "${TERM_PROGRAM:-}" == "ghostty" ]] && printf '\e]0;%s\a' "$proj"
    tmux select-window -t "$wid"
    tmux attach -t "=$proj"
  fi
}

# Launch <cmd> in a new window named <tab> (cwd <cwd>) in session <proj>.
# Creates the session first if it doesn't exist. automatic-rename is disabled so
# the running process can't clobber the `repo:branch` name that mux_jump matches.
mux_launch() {
  local proj="$1" tab="$2" cwd="$3" cmd="$4" wid
  if [[ -n "${TMUX:-}" ]]; then
    # Inside a session (assumed to be this project's): add the window here.
    wid="$(tmux new-window -t "=$proj" -n "$tab" -c "$cwd" -P -F '#{window_id}' "$cmd")"
    [[ -n "$wid" ]] && tmux set-option -w -t "$wid" automatic-rename off 2>/dev/null
  elif tmux has-session -t "=$proj" 2>/dev/null; then
    # Session exists detached: add the window, then attach.
    wid="$(tmux new-window -t "=$proj" -n "$tab" -c "$cwd" -P -F '#{window_id}' "$cmd")"
    [[ -n "$wid" ]] && tmux set-option -w -t "$wid" automatic-rename off 2>/dev/null
    [[ "${TERM_PROGRAM:-}" == "ghostty" ]] && printf '\e]0;%s\a' "$proj"
    tmux attach -t "=$proj"
  else
    # No session yet: create it detached with the window, then attach.
    [[ "${TERM_PROGRAM:-}" == "ghostty" ]] && printf '\e]0;%s\a' "$proj"
    wid="$(tmux new-session -d -s "$proj" -n "$tab" -c "$cwd" -P -F '#{window_id}' "$cmd")"
    [[ -n "$wid" ]] && tmux set-option -w -t "$wid" automatic-rename off 2>/dev/null
    tmux attach -t "=$proj"
  fi
}

# Select <proj>'s <tab> window WITHOUT attaching. Used by the notification
# click handler, which runs detached (launchd, no tty) so it cannot attach.
# Makes the agent's window active in its session; any attached client follows.
mux_select() {
  local proj="$1" tab="$2" wid
  tmux has-session -t "=$proj" 2>/dev/null || return 1
  wid="$(_tmux_window_id "$proj" "$tab")"
  [[ -n "$wid" ]] || return 1
  tmux select-window -t "$wid" 2>/dev/null || true
}
