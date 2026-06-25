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

# _detect_host: honour TERM_PROGRAM when it is a real terminal (not tmux).
# shellcheck source=/dev/null
source "$AGENTDECK_LIB/core.sh"
eq "host from TERM_PROGRAM" "ghostty" \
  "$(env -u TMUX TERM_PROGRAM=ghostty bash -c 'source "'"$AGENTDECK_LIB"'/core.sh"; _detect_host')"

# _detect_host must not abort under `set -e` when the tmux lookup fails (no
# server). Called directly here (the strict case); prints DONE only if it
# returned instead of aborting.
eq "detect_host tolerates tmux failure" "DONE" \
  "$(bash -euo pipefail -c 'source "'"$AGENTDECK_LIB"'/core.sh"; unset TERM_PROGRAM; tmux() { return 1; }; _detect_host; printf DONE' 2>/dev/null)"

# focus_host dispatch table: stub the GUI leaves (each runs in the command-
# substitution subshell, so the redefinitions don't leak) and assert routing.
_dispatch() { # _dispatch <strat> <host> <cwd>
  _focus_app()     { printf 'app:%s' "$1"; }
  _focus_ghostty() { printf 'ghostty:%s' "$1"; }
  _focus_vscode()  { printf 'vscode:%s' "$1"; }
  focus_host "$1" "$2" "$3"
}
eq "dispatch off"             ""            "$(_dispatch off ghostty /x)"
eq "dispatch app:<bundle>"    "app:com.foo" "$(_dispatch app:com.foo ghostty /x)"
eq "dispatch auto→ghostty"    "ghostty:/x"  "$(_dispatch auto ghostty /x)"
eq "dispatch auto→vscode"     "vscode:/x"   "$(_dispatch auto vscode /x)"
eq "dispatch auto+empty→basic" "app:"       "$(_dispatch auto '' /x)"

exit $fail
