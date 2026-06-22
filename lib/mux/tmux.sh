# Multiplexer adapter: tmux (planned for v0.2).
#
# The full state engine, board, and notifications already work under tmux — only
# these two functions need real bodies. Sketch of the intended implementation:
#   mux_jump   → tmux switch-client -t "<proj>:<tab>"   (or attach if outside),
#                then tmux select-window -t "<proj>:<tab>"
#   mux_launch → tmux new-window -t "<proj>" -n "<tab>" -c "<cwd>" "<cmd>"
#                (or new-session if <proj> doesn't exist yet)
# Contributions welcome.

mux_jump() {
  echo "agentdeck: tmux backend is not implemented yet (v0.2). Target: $1 / $2" >&2
  return 1
}

mux_launch() {
  echo "agentdeck: tmux backend is not implemented yet (v0.2). Would launch: $4 in $3" >&2
  return 1
}
