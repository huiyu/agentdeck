# Multiplexer adapter: zellij.
#
# The board is mux-agnostic; only "where am I" and "jump there" are not. zellij
# stores no external session state and its rename/go-to actions target the
# *focused* tab — which is exactly why agentdeck keeps state in files and only
# asks the mux to do the jump.

# Echo the current session name if we're inside one, else nothing.
mux_inside() { [[ -n "${ZELLIJ:-}" ]] && printf '%s' "${ZELLIJ_SESSION_NAME:-}"; }

# Jump to <session>'s <tab>. Mirrors zjp's nesting rules: you can't attach a
# session from inside another, so handle the three cases explicitly.
mux_jump() {
  local proj="$1" tab="$2"
  if [[ -n "${ZELLIJ:-}" ]]; then
    if [[ "${ZELLIJ_SESSION_NAME:-}" == "$proj" ]]; then
      zellij action go-to-tab-name -- "$tab" 2>/dev/null
    else
      echo "agentdeck: '$proj' is a different zellij session — detach (Ctrl-o d) then run agentdeck pick again" >&2
      return 1
    fi
  else
    # Outside zellij: set the Ghostty tab title, attach, and focus the tab once a
    # client is connected (rename/go-to no-op while detached, so defer past attach).
    [[ "${TERM_PROGRAM:-}" == "ghostty" ]] && printf '\e]0;%s\a' "$proj"
    ( sleep 0.4; zellij --session "$proj" action go-to-tab-name -- "$tab" 2>/dev/null ) &
    zellij attach "$proj"
  fi
}
