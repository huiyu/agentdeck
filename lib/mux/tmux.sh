# Multiplexer adapter: tmux (planned for v0.2).
#
# The full state engine, board, and notifications already work under tmux — only
# these two functions need real bodies. Sketch of the intended implementation:
#   mux_inside → tmux display-message -p '#S'
#   mux_jump   → tmux switch-client -t "<proj>:<window>"   (or attach if outside),
#                then tmux select-window -t "<proj>:<tab>"
# Contributions welcome.

mux_inside() { [[ -n "${TMUX:-}" ]] && tmux display-message -p '#S' 2>/dev/null; }

mux_jump() {
  echo "agentdeck: tmux backend is not implemented yet (v0.2). Target: $1 / $2" >&2
  return 1
}
