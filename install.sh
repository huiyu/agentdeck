#!/usr/bin/env bash
# Install agentdeck: symlink the CLI onto your PATH, then wire your agents.
set -euo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${AGENTDECK_BIN_DIR:-$HOME/.local/bin}"

mkdir -p "$BIN_DIR"
ln -snf "$REPO/bin/agentdeck" "$BIN_DIR/agentdeck"
echo "✓ linked $BIN_DIR/agentdeck → $REPO/bin/agentdeck"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "! $BIN_DIR is not on your PATH — add: export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

missing=()
for d in jq fzf; do command -v "$d" >/dev/null 2>&1 || missing+=("$d"); done
if (( ${#missing[@]} )); then
  echo "! missing dependencies: ${missing[*]} (e.g. brew install ${missing[*]})"
fi

echo
echo "Next:"
echo "  agentdeck install      # wire Claude / Codex hooks"
echo "  agentdeck doctor       # verify setup"
echo "  agentdeck pick         # open the board"
