#!/usr/bin/env bash
# Plain-bash assertions for the pure helpers in lib/focus.sh and lib/core.sh.
# No framework: run `bash test/focus_test.sh`. Exits non-zero on first failure.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTDECK_LIB="$ROOT/lib"
# shellcheck source=/dev/null
source "$AGENTDECK_LIB/focus.sh"

fail=0
eq() { # eq <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}

eq "bundle ghostty" "com.mitchellh.ghostty" "$(_bundle_for_host ghostty)"
eq "bundle vscode"  "com.microsoft.VSCode"  "$(_bundle_for_host vscode)"
eq "bundle iterm"   "com.googlecode.iterm2" "$(_bundle_for_host iTerm.app)"
eq "bundle term"    "com.apple.Terminal"    "$(_bundle_for_host Apple_Terminal)"
eq "bundle unknown" ""                      "$(_bundle_for_host whatever)"

eq "strat ghostty" "ghostty" "$(_focus_strategy_for_host ghostty)"
eq "strat vscode"  "vscode"  "$(_focus_strategy_for_host vscode)"
eq "strat basic"   "basic"   "$(_focus_strategy_for_host iTerm.app)"
eq "strat empty"   "basic"   "$(_focus_strategy_for_host '')"

exit $fail
