# Notification Click-to-Focus Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use devmuse:mu-code to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 点击 macOS 通知后跳回正在等待的 agent —— Ghostty 精确聚焦到对应 tab，其它终端兜底把 App 调到前台，VS Code 尽力聚焦到对应项目窗口；并通过 `AGENTDECK_NOTIFY_FOCUS` 配置化。同时修复「点击通知会在 Finder 里打开 terminal-notifier 安装目录」的 bug。

**Architecture:** 两条正交轴。轴①「多路复用层」用 `mux_select`（`tmux select-window`，只选不 attach）把等待的 window 设为活动窗口；轴②「宿主终端层」由新 `lib/focus.sh` 按策略把 App/tab 调到前台（Ghostty 用 AppleScript 按 cwd `focus`，已实测可行）。宿主与 mux 在 hook 写状态时探测并存入状态文件；通知挂 `terminal-notifier -execute "<self> focus <file>"`，点击时（launchd 脱离上下文、无 tty）回调 `agentdeck focus <file>` 读状态文件执行。策略在**点击时**由 `AGENTDECK_NOTIFY_FOCUS` + 存储的 host 解析。

**Tech Stack:** Bash, jq, osascript/AppleScript, terminal-notifier, tmux.

**Key facts (已实测):**
- tmux 内 `TERM_PROGRAM=tmux`（被覆盖），但 `tmux show-environment -g TERM_PROGRAM` 仍返回真实宿主 `ghostty` → hook 时可恢复。
- Ghostty 有 AppleScript 字典：`first terminal whose working directory is <cwd>` + `focus` 能精确切到对应 tab（视觉切换已肉眼验证）。
- 状态文件：`$AGENTDECK_STATE_DIR/<agent>-<sid>.json`，现有字段 `id/agent/state/proj/tab/cwd/transcript/msg/pid/ts`；本计划新增 `host`、`mux`。
- 回调子命令 key 复用 `core_list` 的 `{7}` / `core_kill` 的状态文件 basename。

**Scope (已与用户确认):** Ghostty 精确档 + 基础档兜底 + VS Code best-effort。zellij 的 `mux_select` 本期仅留 no-op 占位，后续补。

---

## File Structure

| 文件 | 职责 | 动作 |
|---|---|---|
| `lib/focus.sh` | 轴②：host→strategy/bundle 映射 + 各档聚焦实现（ghostty/vscode/basic） | **Create** |
| `lib/mux/tmux.sh` | 新增 `mux_select`（select-window，不 attach） | Modify |
| `lib/mux/zellij.sh` | 新增 `mux_select` no-op 占位 | Modify |
| `lib/core.sh` | `_mux_name` 重构、`_detect_host`、`_persist` 加字段、`_notify` 加 `-execute`、`core_focus` | Modify |
| `bin/agentdeck` | 分发 `focus` 子命令、版本号 | Modify |
| `test/focus_test.sh` | 纯函数断言（无框架，`bash test/focus_test.sh`） | **Create** |
| `README.md` / `README.zh-CN.md` | `AGENTDECK_NOTIFY_FOCUS` 文档 | Modify |
| `CHANGELOG.md` | 变更条目 | Modify |

---

### Task 1: `lib/focus.sh` — 宿主聚焦层（轴②）

**Files:**
- Create: `lib/focus.sh`
- Test: `test/focus_test.sh`

- [ ] **Step 1: 写失败测试** (`test/focus_test.sh`)

```bash
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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash test/focus_test.sh`
Expected: FAIL —— `lib/focus.sh: No such file` 或函数未定义。

- [ ] **Step 3: 实现 `lib/focus.sh`**

```bash
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
```

- [ ] **Step 4: 跑测试确认通过**

Run: `bash test/focus_test.sh`
Expected: 全部 `ok`，exit 0。

- [ ] **Step 5: 提交**

```bash
git add lib/focus.sh test/focus_test.sh
git commit -m "feat(notify): add host-focus layer (ghostty/vscode/basic tiers)"
```

---

### Task 2: `mux_select` —— 轴①选窗不 attach

**Files:**
- Modify: `lib/mux/tmux.sh`
- Modify: `lib/mux/zellij.sh`

- [ ] **Step 1: tmux 实现** (在 `lib/mux/tmux.sh` 末尾追加)

```bash
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
```

- [ ] **Step 2: zellij 占位** (在 `lib/mux/zellij.sh` 末尾追加)

```bash
# Placeholder: selecting a tab in a detached/other zellij session from outside
# needs a client context zellij doesn't expose the same way tmux does. Left as a
# no-op for now; the host-focus layer still brings the app forward. (TODO)
mux_select() { return 0; }
```

- [ ] **Step 3: 验证 tmux 选窗生效**

在 tmux 里建两个 window，从一个非 tmux 的 shell（模拟点击上下文，`env -u TMUX`）调用：

Run:
```bash
env -u TMUX bash -c 'source lib/mux/tmux.sh; mux_select <yourproj> <tab-name>; echo rc=$?'
tmux display-message -p '#{window_name}'   # 应已切到目标 window
```
Expected: `rc=0`，活动 window 变为目标 tab。

- [ ] **Step 4: 提交**

```bash
git add lib/mux/tmux.sh lib/mux/zellij.sh
git commit -m "feat(mux): add mux_select (select window without attaching)"
```

---

### Task 3: host / mux 探测助手

**Files:**
- Modify: `lib/core.sh` (`_load_mux` 重构出 `_mux_name`；新增 `_detect_host`)
- Test: `test/focus_test.sh` (追加)

- [ ] **Step 1: 追加失败测试** (`test/focus_test.sh` 末尾、`exit $fail` 之前)

```bash
# _detect_host: honour TERM_PROGRAM when it is a real terminal (not tmux).
# shellcheck source=/dev/null
source "$AGENTDECK_LIB/core.sh"
eq "host from TERM_PROGRAM" "ghostty" \
  "$(env -u TMUX TERM_PROGRAM=ghostty bash -c 'source "'"$AGENTDECK_LIB"'/core.sh"; _detect_host')"
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash test/focus_test.sh`
Expected: FAIL —— `_detect_host` 未定义。

- [ ] **Step 3: 重构 `_load_mux` + 新增 `_detect_host`** (`lib/core.sh`)

把现有 `_load_mux`（约 26-36 行）替换为：

```bash
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
```

- [ ] **Step 4: 跑测试确认通过**

Run: `bash test/focus_test.sh`
Expected: 全部 `ok`，exit 0。

- [ ] **Step 5: 提交**

```bash
git add lib/core.sh test/focus_test.sh
git commit -m "refactor(core): extract _mux_name, add _detect_host"
```

---

### Task 4: 状态文件新增 `host` / `mux`

**Files:**
- Modify: `lib/core.sh` (`_persist`，约 111-126 行)

- [ ] **Step 1: 改 `_persist`** —— 在 `jq -n` 调用前探测，并加进对象

把 `_persist` 里的 `jq -n ...` 块替换为：

```bash
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
```

- [ ] **Step 2: 手动验证字段写入**

触发一次状态写入（在已接入的 agent 里随便发一条消息，或手动跑 ingest），然后：

Run: `jq '{host, mux}' "$(agentdeck dir)"/*.json | head`
Expected: 看到 `{"host":"ghostty","mux":"tmux"}` 之类。

- [ ] **Step 3: 提交**

```bash
git add lib/core.sh
git commit -m "feat(state): record host terminal and mux in session state"
```

---

### Task 5: `core_focus` 子命令 + 分发

**Files:**
- Modify: `lib/core.sh` (新增 `core_focus`)
- Modify: `bin/agentdeck` (分发 `focus`；usage 注释)

- [ ] **Step 1: 新增 `core_focus`** (`lib/core.sh`，放在 `core_kill` 附近)

```bash
# focus: notification click handler. Runs detached (launchd, no tty), so it
# selects the window without attaching, then brings the host app/tab forward.
# Strategy is resolved HERE (at click time) from AGENTDECK_NOTIFY_FOCUS + the
# recorded host, so config changes take effect without re-launching agents.
core_focus() {
  local b f host mux proj tab cwd strat
  b="$(basename "${1:-}")"; [[ -n "$b" && "$b" == *.json ]] || return 0
  f="$AGENTDECK_STATE_DIR/$b"; [[ -f "$f" ]] || return 0
  strat="${AGENTDECK_NOTIFY_FOCUS:-auto}"
  [[ "$strat" == "off" ]] && return 0
  host="$(jq -r '.host // empty' "$f")"
  mux="$(jq -r '.mux // empty' "$f")"
  proj="$(jq -r '.proj // empty' "$f")"
  tab="$(jq -r '.tab // empty' "$f")"
  cwd="$(jq -r '.cwd // empty' "$f")"
  # axis ①: make the agent's window active (best-effort) using the recorded mux.
  if [[ -n "$mux" && -f "$AGENTDECK_LIB/mux/$mux.sh" ]]; then
    # shellcheck source=/dev/null
    source "$AGENTDECK_LIB/mux/$mux.sh"
    mux_select "$proj" "$tab" 2>/dev/null || true
  fi
  # axis ②: bring the host app/tab to the front.
  # shellcheck source=/dev/null
  source "$AGENTDECK_LIB/focus.sh"
  focus_host "$strat" "$host" "$cwd"
}
```

- [ ] **Step 2: 分发** (`bin/agentdeck` case 块加一行，紧跟 `kill`)

```bash
  focus)             core_focus "${1:-}" ;;
```

并在顶部命令清单注释加：

```bash
#   agentdeck focus <file>       Notification click handler — jump to that session.
```

- [ ] **Step 3: 手动验证回调（同 tab 内可见即可）**

Run: `agentdeck focus "$(basename "$(ls -t "$(agentdeck dir)"/*.json | head -1)")"; echo rc=$?`
Expected: `rc=0`；Ghostty 被调到前台并切到该会话 cwd 对应 tab（如该 tab 存在）。

- [ ] **Step 4: 提交**

```bash
git add lib/core.sh bin/agentdeck
git commit -m "feat(notify): add 'focus' subcommand (click handler)"
```

---

### Task 6: 通知挂载 `-execute` 回调（修 bug）

**Files:**
- Modify: `lib/core.sh` (`_notify` 约 87-107 行；`_ingest_hook`、`_ingest_notify` 调用处)

- [ ] **Step 1: 改 `_notify` 接受 file 并加 `-execute`**

`_notify` 头部改签名，terminal-notifier 分支加 `-execute`：

```bash
_notify() {
  local title="${1//[\"\\]/ }" msg="${2//[\"\\]/ }" file="${3:-}"
  if   command -v terminal-notifier >/dev/null 2>&1; then
    local -a tn=(-title "$title" -message "$msg")
    [[ -n "${AGENTDECK_NOTIFY_SENDER:-}" ]] && tn+=(-sender "$AGENTDECK_NOTIFY_SENDER")
    [[ -n "${AGENTDECK_NOTIFY_ICON:-}"   ]] && tn+=(-appIcon "$AGENTDECK_NOTIFY_ICON")
    # Click action: jump back to the waiting session. Without -execute,
    # terminal-notifier's default click reveals its own bundle folder in Finder.
    # The command runs detached via launchd; core_focus resolves the strategy.
    # terminal-notifier hands the string to `/bin/sh -c`, so shell-quote both the
    # launcher path and the (already-sanitized) file with %q to stay robust even
    # if the install path contains spaces/metacharacters.
    if [[ -n "$file" ]]; then
      local _cmd; printf -v _cmd '%q focus %q' "$(_self)" "$file"
      tn+=(-execute "$_cmd")
    fi
    terminal-notifier "${tn[@]}" >/dev/null 2>&1 || true
  elif command -v osascript >/dev/null 2>&1; then
    __CF_USER_TEXT_ENCODING=0x0:0x8000100:0x8000100 \
      osascript -e "display notification \"$msg\" with title \"$title\" sound name \"Glass\"" >/dev/null 2>&1 || true
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "$title" "$msg" >/dev/null 2>&1 || true
  fi
}
```

> 注：osascript / notify-send 分支无法携带点击动作，保持原样（已在 README 注明这两条兜底无 `-execute`）。

- [ ] **Step 2: 调用处传 file** —— `_ingest_hook`（约 162-163 行）

把：
```bash
    Notification) _notify "⏳ $tab is waiting on you" "${msg:-needs input}" ;;
    Stop) [[ "$AGENTDECK_NOTIFY_ON_STOP" == "1" ]] && _notify "✅ $tab finished" "${msg:-$repo}" ;;
```
改为（先在函数内算出 file basename，与 `_persist` 一致）：
```bash
    Notification) _notify "⏳ $tab is waiting on you" "${msg:-needs input}" "${agent}-${sid//[^A-Za-z0-9._-]/-}.json" ;;
    Stop) [[ "$AGENTDECK_NOTIFY_ON_STOP" == "1" ]] && _notify "✅ $tab finished" "${msg:-$repo}" "${agent}-${sid//[^A-Za-z0-9._-]/-}.json" ;;
```

- [ ] **Step 3: 调用处传 file** —— `_ingest_notify`（约 184 行 Codex 路径）

把：
```bash
  [[ "$state" == "waiting" ]] && _notify "⏳ $tab is waiting on you" "${msg:-needs input}"
```
改为：
```bash
  [[ "$state" == "waiting" ]] && _notify "⏳ $tab is waiting on you" "${msg:-needs input}" "${agent}-${sid//[^A-Za-z0-9._-]/-}.json"
```

- [ ] **Step 4: 静态检查 + 手动冒烟**

Run: `bash -n lib/core.sh && command -v shellcheck >/dev/null && shellcheck lib/core.sh lib/focus.sh lib/mux/tmux.sh || true`
Expected: 无语法错误。

- [ ] **Step 5: 提交**

```bash
git add lib/core.sh
git commit -m "fix(notify): make clicked banners jump to the session, not Finder"
```

---

### Task 7: 文档 + 版本

**Files:**
- Modify: `README.md`、`README.zh-CN.md`（NOTIFY 配置表）
- Modify: `CHANGELOG.md`
- Modify: `lib/core.sh`（`AGENTDECK_VERSION` → `0.2.0`）

- [ ] **Step 1: README.md** —— 在 NOTIFY 配置表加一行

```markdown
| `AGENTDECK_NOTIFY_FOCUS` | `auto` | Click a banner to jump back to the waiting session. `auto` detects the host terminal (Ghostty focuses the exact tab; others bring the app forward; VS Code reuses the project window); force with `ghostty`/`vscode`/`app:<bundle-id>`, or `off` to disable. macOS + `terminal-notifier` only |
```

- [ ] **Step 2: README.zh-CN.md** —— 对应中文行

```markdown
| `AGENTDECK_NOTIFY_FOCUS` | `auto` | 点击横幅跳回等待中的会话。`auto` 自动探测宿主终端（Ghostty 精确切到对应 tab；其它终端把 App 调前台；VS Code 复用项目窗口）；可强制 `ghostty`/`vscode`/`app:<bundle-id>`，或设 `off` 关闭。仅 macOS + `terminal-notifier` |
```

- [ ] **Step 3: CHANGELOG.md** —— 顶部加条目

```markdown
- feat(notify): clicking a banner now jumps back to the waiting agent — Ghostty
  focuses the exact tab, other terminals come forward, VS Code reuses the project
  window. Configurable via `AGENTDECK_NOTIFY_FOCUS`. Fixes the old behaviour where
  clicking opened terminal-notifier's install folder in Finder.
```

- [ ] **Step 4: 版本号** `lib/core.sh:13` `AGENTDECK_VERSION="0.1.0"` → `"0.2.0"`

- [ ] **Step 5: 提交**

```bash
git add README.md README.zh-CN.md CHANGELOG.md lib/core.sh
git commit -m "docs: document AGENTDECK_NOTIFY_FOCUS; bump 0.2.0"
```

---

### Task 8: 端到端真实验证（手动）

无法自动化（涉及真实通知 + GUI + launchd TCC）。

- [ ] **Step 1:** 确保 `terminal-notifier` 已装：`command -v terminal-notifier`
- [ ] **Step 2:** 在一个 Ghostty tab 的 tmux 会话里跑一个已接入的 agent，触发 `Notification`（等待输入）状态。
- [ ] **Step 3:** 切到**另一个** Ghostty tab，点击通知横幅。
- [ ] **Step 4:** 首次点击 macOS 弹「允许 terminal-notifier 控制 Ghostty」→ 允许。
- [ ] **Step 5:** 确认 Ghostty 被调前台并切到**等待 agent 所在的 tab**。✅
- [ ] **Step 6:** 验证配置：`AGENTDECK_NOTIFY_FOCUS=off` 时点击无动作（也不再打开 Finder）；`app:com.apple.Terminal` 时点击只激活 Terminal。

---

## Known limitations (写入代码注释/文档，不在本期解决)

- Ghostty 精确档按 cwd 匹配：当一个 tmux session 有多个 window 且 Ghostty 上报的 cwd 未随 `select-window` 更新（OSC7 不重发）时，可能落到同 session 的活动 tab 而非精确 window。用户当前「一个 Ghostty tab 一个 tmux session」布局不受影响。
- zellij 的 `mux_select` 为 no-op；zellij 用户点击仅把宿主 App 调前台。
- iTerm2 / WezTerm / kitty 精确档未实现（可经 `app:<bundle>` 走基础档；后续作为 `lib/focus.sh` 的新分支扩展）。
- osascript / notify-send 兜底路径无法携带点击动作。
