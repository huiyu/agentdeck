# Host-focus layer (axis ②): bring the right terminal app / tab to the front
# when a notification is clicked. Sourced on demand by core_focus; the pure
# mapping helpers are also unit-tested directly (see test/focus_test.sh).
#
# Strategy tiers:
#   ghostty — precise: AppleScript focuses the tab whose cwd matches the agent.
#   vscode  — best-effort: activate VS Code, reuse the folder's window.
#   basic   — activate the host app by bundle id (no per-tab control).

# Map a raw TERM_PROGRAM value to a macOS bundle id. Empty for unknown hosts.
_bundle_for_host() {
  case "$1" in
    ghostty)        printf 'com.mitchellh.ghostty' ;;
    vscode)         printf 'com.microsoft.VSCode' ;;
    iTerm.app)      printf 'com.googlecode.iterm2' ;;
    Apple_Terminal) printf 'com.apple.Terminal' ;;
    WezTerm)        printf 'com.github.wez.wezterm' ;;
    *)              printf '' ;;
  esac
}

# Map a host to its focus strategy under AGENTDECK_NOTIFY_FOCUS=auto.
_focus_strategy_for_host() {
  case "$1" in
    ghostty) printf 'ghostty' ;;
    vscode)  printf 'vscode' ;;
    *)       printf 'basic' ;;
  esac
}

# Activate an app by bundle id (basic tier). No-op when bundle is empty.
_focus_app() {
  local bundle="$1"
  [[ -n "$bundle" ]] && open -b "$bundle" >/dev/null 2>&1 || true
}

# Ghostty precise tier: focus the tab whose terminal cwd equals <cwd>. cwd is
# passed as argv (not interpolated into the script) to avoid AppleScript
# injection. Falls back to plain app activation when no tab matches.
_focus_ghostty() {
  local cwd="$1"
  osascript - "$cwd" >/dev/null 2>&1 <<'APPLESCRIPT' || _focus_app com.mitchellh.ghostty
on run argv
  set needle to item 1 of argv
  tell application "Ghostty"
    activate
    set t to first terminal whose working directory is needle
    focus t
  end tell
end run
APPLESCRIPT
}

# VS Code best-effort: bring VS Code forward and reuse the window for the
# agent's folder. The integrated terminal panel cannot be focused externally
# without an extension, so we stop at the project window.
_focus_vscode() {
  local cwd="$1"
  _focus_app com.microsoft.VSCode
  command -v code >/dev/null 2>&1 && [[ -n "$cwd" ]] && code "$cwd" >/dev/null 2>&1 || true
}

# Dispatch on the resolved strategy. <strat> is AGENTDECK_NOTIFY_FOCUS verbatim
# (auto | ghostty | vscode | app:<bundle> | off); <host> is the recorded
# TERM_PROGRAM; <cwd> is the agent's working directory.
focus_host() {
  local strat="$1" host="$2" cwd="$3"
  case "$strat" in
    off)    return 0 ;;
    app:*)  _focus_app "${strat#app:}"; return 0 ;;
    auto|'') strat="$(_focus_strategy_for_host "$host")" ;;
  esac
  case "$strat" in
    ghostty) _focus_ghostty "$cwd" ;;
    vscode)  _focus_vscode "$cwd" ;;
    *)       _focus_app "$(_bundle_for_host "$host")" ;;
  esac
}
