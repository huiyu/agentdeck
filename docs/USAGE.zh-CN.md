# agentdeck — 使用手册

[English](USAGE.md) · **简体中文** · [← README](../README.zh-CN.md)

安装、接入、配置与故障排查的完整参考。如需快速概览，请先阅读 [README](../README.zh-CN.md)。

## 目录

- [概念](#概念)
- [安装与接入](#安装与接入)
- [命令](#命令)
- [看板](#看板)
- [通知与点击跳转](#通知与点击跳转)
- [配置](#配置)
- [状态文件](#状态文件)
- [多路复用器行为](#多路复用器行为)
- [Agent 接入细节](#agent-接入细节)
- [扩展](#扩展)
- [故障排查](#故障排查)
- [常见问题](#常见问题)

## 概念

agentdeck 由三个部分构成：

- **Core** (`lib/core.sh`) — 共享引擎：状态存储、fzf 面板、排序与通知。与具体 agent 和多路复用器无关。
- **Agent 适配器** (`lib/agents/<name>.sh`) — 将某个编码 agent 的 hook 事件映射为状态，并负责接线/探测。内置：`claude`、`codex`。
- **多路复用器适配器** (`lib/mux/<name>.sh`) — 回答「我在哪」和「跳转到某个标签页」。内置：`tmux`、`zellij`。

所有流程均通过唯一入口 `bin/agentdeck` 分发：它解析自身的 `lib/` 目录（跟随软链），加载配置，再派发子命令。

两个贯穿全文的术语：

- **proj** — 项目，对应多路复用器的 *session* 名称。
- **tab** — `repo:branch`，对应多路复用器的 *window/tab* 名称。

## 安装与接入

### 依赖

| 工具 | 是否必须 | 用途 |
|---|---|---|
| `bash` | 是 | 引擎 |
| `jq` | 是 | 读写状态 JSON |
| `fzf` | 是 | `pick` 面板 |
| `tmux` 或 `zellij` | 是 | 运行 agent 的多路复用器 |
| `terminal-notifier` | macOS，用于可点击通知 | 横幅 + 点击跳转 |
| `osascript` | macOS 内置 | 横幅兜底（无点击动作） |
| `notify-send` | Linux | 横幅 |

### 步骤

```sh
git clone https://github.com/huiyu/agentdeck ~/.agentdeck
~/.agentdeck/install.sh        # symlinks bin/agentdeck into ~/.local/bin
agentdeck install              # wires detected agents (idempotent)
agentdeck doctor               # prints deps, detected agents, wiring, notifier
brew install terminal-notifier # macOS: enables clickable, jump-back banners
```

`install.sh` 只将启动器放入 PATH。`agentdeck install` 完成各 agent 的 hook 接线。`agentdeck doctor` 是验证命令 —— 任何时候遇到异常都可以跑一下。

### `agentdeck install` 写了什么

它就地修补每个*已探测到*的 agent 配置，只追加自身的条目。重复执行是安全的（幂等），不会覆盖已有设置。

- **Claude Code** → `~/.claude/settings.json` 的 `hooks`：`SessionStart`、`UserPromptSubmit`、`Notification`、`Stop`、`SessionEnd`。每个 hook 均调用 `agentdeck ingest claude`。
- **Codex** → `~/.codex/hooks.json`（working/idle/end），**以及** `~/.codex/config.toml` 里的一条 `notify`（`waiting` 信号）。如果你已有 Codex `notify` 程序，agentdeck 不会覆盖它 —— 而是打印出需要手动添加的那一行。

写入每个 hook 的命令使用稳定的启动器路径（`$HOME/.local/bin/agentdeck`），只要它软链回仓库，仓库移动后依然有效。

### 更新

启动器是指向 clone 里 `bin/agentdeck` 的符号链接，运行时再加载 `lib/` —— 所以更新就是拉取这个 clone，无需重建链接。

```sh
# 不确定 clone 目录时，反查：
dirname "$(dirname "$(readlink -f "$(command -v agentdeck)")")"

git -C ~/.agentdeck pull   # 换成上一步查到的路径
agentdeck version          # 确认新版本
agentdeck doctor           # 检查 deps / agents / 接线 / notifier
```

- **无需重建链接** —— 链接指向仓库，`git pull` 就地更新。
- **仅在需要时重跑 `agentdeck install`** —— 各版本间 hook 接线很少变；只有当 `doctor` 报告接线缺失、或你新增了 agent 时才重跑（幂等）。通知的点击跳转是运行时接线的（通过横幅的 `-execute`），并非安装时写入，所以无需重新 install。
- **新增依赖** —— 某个版本可能引入新工具；`doctor` 会标出缺失项。点击跳转需安装 `terminal-notifier`（见[通知与点击跳转](#通知与点击跳转)）。

## 命令

```
agentdeck <command> [args]
```

| 命令 | 说明 | 备注 |
|---|---|---|
| `pick` | 打开 fzf 面板 | Enter 跳转 · Ctrl-x 终止 · Ctrl-d 移除 |
| `new [agent]` | 在当前目录所属项目的标签页启动 agent | 默认：首个探测到的 agent |
| `install [agent…]` | 接线 hooks | 默认：所有已探测到的 agent |
| `doctor` | 显示依赖/agent/接线/通知器状态 | 验证命令 |
| `list` | 原始 TSV 行 | 可脚本化；`pick` 内部使用 |
| `dir` | 打印状态目录 | 可脚本化 |
| `version` | 打印版本 | |
| `help` | 打印用法 | |
| `ingest <agent>` | Hook 入口 | 由 agent 调用；**非人工使用** |
| `focus <file>` | 通知点击处理器 | 由点击触发；**非人工使用** |
| `preview <file>` | 为 fzf 预览窗渲染单个会话 | 内部 |
| `kill <file>` | 终止 agent 并移除该行 | 内部（面板 Ctrl-x） |
| `forget <file>` | 移除该行，保留 agent 运行 | 内部（面板 Ctrl-d） |

### `agentdeck new [agent]`

在当前目录所属项目的标签页启动一个 agent。不传参数时使用首个探测到的 agent（依次检查 `claude`、`codex`）。mux 适配器按需创建 session，将标签页命名为 `repo:branch`，然后 attach。

### `agentdeck focus <file>`

点击处理器。`<file>` 为状态文件的 basename。它由 macOS launchd 通过 terminal-notifier 的 `-execute` **以脱离终端的方式**调用，无控制终端，`PATH` 极简。它读取记录的 `host`/`mux`/`proj`/`tab`/`cwd`，然后：

1. **轴 ①** — 在*不 attach* 的情况下选中 agent 所在窗口（`mux_select`）。
2. **轴 ②** — 将宿主 App/标签页调到前台（`focus_host`）。

聚焦策略在**点击时**从 `AGENTDECK_NOTIFY_FOCUS` 加上已记录的 host 中解析，因此修改配置无需重启 agent 即可生效。无需手动运行；它是通知点击动作的目标。

## 看板

`agentdeck pick` 打开一个覆盖所有活跃会话的 fzf 选择器。

**列**（排序：waiting → working → idle，同状态内按最新优先）：

```
🟡 🟣 blibee:main   3s   ← state dot · agent icon · tab · age
```

- **状态点** — 🟡 等待 · 🔴 工作中 · 🟢 空闲。
- **Agent 图标** — 🟣 claude · 🔵 codex · 🟤 gemini · 🟠 aider。
- **tab** — `repo:branch`。
- **age** — 距上次状态更新的时间。

**按键：**

| 按键 | 动作 |
|---|---|
| `Enter` | 跳转到该会话的标签页 |
| `Ctrl-x` | **终止** agent（SIGTERM）并移除该行 |
| `Ctrl-d` | **移除**该行（agent 继续运行） |

右侧预览窗显示所选会话：agent/proj/tab/state/cwd/age，以及最近的 assistant 消息和转录尾部。

**kill 与 forget 的区别。** `kill` 会记录每个会话的 pid（从 hook 沿进程树向上找到 agent 进程），并发送 SIGTERM —— 在确认存活进程仍属于该 agent 之后才发送，避免 pid 复用误伤其他进程。标签页作为普通 shell 保留。`forget` 只移除状态行，保留 agent 运行 —— 用于清理已失效或崩溃的条目。

## 通知与点击跳转

### 何时触发横幅

- **waiting** — agent 需要你处理（Claude `Notification` 事件；Codex 通过 `notify` 程序）。始终通知。
- **finished** — agent 已停止（Claude `Stop`）。当 `AGENTDECK_NOTIFY_ON_STOP=1`（默认）时通知；设为 `0` 则只在 *waiting* 时提醒。

### 后端选择

`_notify` 依次选用第一个可用的：`terminal-notifier` → `osascript` → `notify-send`。**只有 `terminal-notifier` 支持点击动作。** 在 osascript 兜底模式下，横幅仍会出现，但点击无效（macOS 不允许在 `display notification` 上绑定自定义点击动作）。

### 点击流水线

```
banner click
   └─ launchd runs:  agentdeck focus <agent>-<sid>.json   (detached, minimal env)
        └─ core_focus reads state → mux_select (axis ①) → focus_host (axis ②)
             └─ Ghostty: osascript focuses the tab whose working dir == agent cwd
```

该命令通过 `terminal-notifier -execute` 写入通知，并用 `printf %q` 进行 shell 转义，无论安装路径如何均可稳定运行。

### 策略 — `AGENTDECK_NOTIFY_FOCUS`

| 值 | 点击行为 |
|---|---|
| `auto`（默认） | 自动探测宿主终端，选用下方最佳策略 |
| `ghostty` | 精确聚焦到对应 Ghostty 标签页（按工作目录匹配） |
| `vscode` | 激活 VS Code 并复用项目窗口（`code <cwd>`） |
| `app:<bundle-id>` | 仅激活指定 App，例如 `app:com.apple.Terminal` |
| `off` | 无点击动作 |

在 `auto` 模式下，即使在 tmux 内部（tmux 会覆写 `TERM_PROGRAM`），也能在 hook 执行时通过读取 tmux server 的全局环境恢复宿主信息。已识别的宿主对应：Ghostty → 精确 tab 聚焦；VS Code → 项目窗口；其他 → 将 App 调至前台（"基础"级）。

### macOS 一次性设置

1. `brew install terminal-notifier`
2. **系统设置 → 通知 → terminal-notifier**：*允许通知* 开启，样式选 **提醒**（横幅会自动消失，容易漏掉或误点）。
3. 首次点击 → 允许 *terminal-notifier 控制你的终端*（永久生效）。

如果横幅不显示或点击不跳转，请参阅[故障排查](#故障排查)。

## 配置

配置文件为纯 shell 格式的 `KEY=value` 行。解析顺序：先 source `AGENTDECK_CONFIG` 指向的文件（默认 `~/.config/agentdeck/config`），再由同名环境变量覆盖。复制 `agentdeck.example.config` 即可开始。所有键均为可选。

| 键 | 默认值 | 作用 |
|---|---|---|
| `AGENTDECK_STATE_DIR` | `$XDG_STATE_HOME/agentdeck`（`~/.local/state/agentdeck`） | 每会话状态文件存放位置 |
| `AGENTDECK_TTL` | `86400` | 超过此秒数未更新的状态文件将被清理（已死/崩溃的会话） |
| `AGENTDECK_MUX` | 自动探测 | 强制指定 `tmux` / `zellij`，而非从 `$ZELLIJ` / `$TMUX` 自动探测 |
| `AGENTDECK_NOTIFY_ON_STOP` | `1` | 完成时弹横幅；`0` = 只在 waiting 时提醒 |
| `AGENTDECK_NOTIFY_FOCUS` | `auto` | 点击跳转策略：`auto` / `ghostty` / `vscode` / `app:<bundle-id>` / `off`。仅 macOS + terminal-notifier |
| `AGENTDECK_NOTIFY_SENDER` | 无 | 借用另一个 App 的图标与身份（bundle id）。仅 terminal-notifier |
| `AGENTDECK_NOTIFY_ICON` | 无 | 自定义通知图标（路径/URL）。仅 terminal-notifier |
| `AGENTDECK_CONFIG` | `~/.config/agentdeck/config` | 配置文件路径本身（仅限环境变量） |

## 状态文件

每个会话在 `$AGENTDECK_STATE_DIR/<agent>-<session_id>.json` 存放一个 JSON 文件：

| 字段 | 含义 |
|---|---|
| `id` | Agent 的 session id |
| `agent` | `claude` / `codex` / … |
| `state` | `waiting` / `working` / `idle` |
| `proj` | 项目 = mux session 名称 |
| `tab` | `repo:branch` = mux window/tab 名称 |
| `cwd` | Agent 工作目录（点击跳转的匹配键） |
| `transcript` | Agent 转录文件路径（支撑预览） |
| `msg` | 最后一条 assistant 消息（预览 + 横幅正文） |
| `pid` | Agent 进程 pid（供 `kill` 终止） |
| `host` | 启动 agent 的终端（例如 `ghostty`）—— 用于点击跳转 |
| `mux` | `tmux` / `zellij` —— 脱离终端的点击处理器驱动哪个后端 |
| `ts` | 最后更新的 Unix 时间戳（用于 age 计算与 TTL 清理） |

**生命周期。** Hook 在每次状态变更时写入文件。`SessionEnd`（或 Codex end）时删除。崩溃后从未发送 end 事件的会话由 `AGENTDECK_TTL` 清理（文件超过 TTL 未更新，下次 `list`/`pick` 时被丢弃）。`host`/`mux` 在 hook 执行时探测；早于本版本写入的状态缺少这两个字段，点击跳转会降级为仅将 App 调至前台。

## 多路复用器行为

### tmux

- **跳转**（`mux_jump`）：在 tmux 内部时用 `switch-client` 切换到对应窗口；否则先 `select-window` 再 `attach`。
- **选中**（`mux_select`，点击跳转）：通过唯一 `@N` id 对解析到的窗口执行 `select-window`，**不 attach** —— 在脱离终端的点击上下文中安全可用。
- 窗口通过精确名称匹配解析为唯一 `@N` id，不以含冒号的 `repo:branch` 字符串作为目标（tmux 的目标语法为 `session:window`）。

### zellij

- **跳转**：设置标签页标题，attach，待客户端连接后跳到该标签页（rename/go-to 在 detached 状态下为空操作）。
- **点击时的选中**目前为**空操作** —— zellij 无法像 tmux 那样从外部选中另一个 detached/其他 session 的标签页。宿主 App 仍会被调至前台。
- 跨 zellij session 跳转需要先 detach（无法在一个 session 内部 attach 另一个 session）。

## Agent 接入细节

### Claude Code

`~/.claude/settings.json` 中的 hooks 映射到以下状态：

| 事件 | 状态 |
|---|---|
| `SessionStart` / `UserPromptSubmit` | working / session 记账 |
| `Notification` | waiting |
| `Stop` | idle（已完成） |
| `SessionEnd` | gone（文件删除） |

每个 hook 将其 JSON 通过 stdin 管道传给 `agentdeck ingest claude`。

### Codex

- **Hooks**（`~/.codex/hooks.json`）覆盖 working / idle / end —— 精确。
- **`notify`**（`~/.codex/config.toml`）传递 `waiting` 信号。由于 Codex 的 `notify` payload 不含 session id 或 cwd，agentdeck 以当前目录为键，更新该目录下最新的 Codex 会话。这是尽力而为的方案，直到 Codex 将 `approval-requested` 暴露给 hooks 为止。

## 扩展

### 新增 agent — `lib/agents/<name>.sh`

参照 `claude.sh` 实现以下内容：

- `AGENT_F_SID` / `AGENT_F_CWD` / `AGENT_F_TRANSCRIPT` — 进入 hook JSON 的 jq 路径。
- `agent_detect` — 该 agent 是否已安装？
- `agent_state_for <event>` — 将 hook 事件映射为 `idle` / `working` / `waiting` / `gone` / `skip`。
- `agent_notify_state <type>` — 同上，用于带外的 `notify` 传输通道（无则 `echo skip`）。
- `agent_installed` / `agent_install <self>` — 检查并幂等地接线 hook。

然后将其图标添加到 `lib/core.sh` 的 `_agentdeck_icon_json` 中。

### 新增多路复用器 — `lib/mux/<name>.sh`

实现三个函数：

- `mux_jump <proj> <tab>` — 聚焦到该会话的标签页（支撑 `pick`）。
- `mux_launch <proj> <tab> <cwd> <cmd>` — 新开一个运行 `<cmd>` 的标签页（支撑 `new`）。
- `mux_select <proj> <tab>` — **不 attach** 地选中该窗口（支撑点击跳转，在无 tty 的脱离环境中运行）。session/window 不存在时返回非零，供调用方优雅降级。

参考 `lib/mux/tmux.sh` 与 `lib/mux/zellij.sh`。

## 故障排查

从 `agentdeck doctor` 开始 —— 它会打印依赖、已探测到的 agent、接线状态及当前活跃的通知器。

### 面板空白 / "no active agent sessions"

- `agentdeck doctor` → `fzf`/`jq` 是否存在，agent 是否已探测并已接线？
- `agentdeck list` → 有无输出行？若为空，说明 hooks 未触发。重新运行 `agentdeck install` 并检查 agent 配置中的 hook 行。
- 会话在 `AGENTDECK_TTL` 后自动清理；长时间空闲的会话可能已被丢弃。

### 不显示通知横幅

这通常是 terminal-notifier 的 macOS 权限/样式问题，**与 agentdeck 无关**：

1. `command -v terminal-notifier` — 是否已安装？否则：`brew install terminal-notifier`。未安装时 agentdeck 降级为 osascript（仅横幅，无点击）。
2. **系统设置 → 通知 → terminal-notifier** → *允许通知* 开启，样式选 **提醒**。新安装的 terminal-notifier 往往处于未注册/禁止状态，macOS 会静默丢弃其横幅。
3. 检查是否被**专注模式 / 勿扰**压制。
4. `terminal-notifier -list ALL` — 如果通知出现在此处，说明已*送达*（问题在于显示样式/专注模式，而非送达本身）。
5. 仍未出现在设置列表中？重新注册 App bundle：
   `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(find /opt/homebrew/Cellar/terminal-notifier -name '*.app' -maxdepth 3 -type d | head -1)"`

### 点击横幅不跳转

- **首次点击**会弹出允许 *terminal-notifier 控制你的终端* 的提示 —— 必须点击 **允许**。首次点击可能被该提示消耗；点击下一个横幅即可。
- **目标标签页已关闭**，或其 cwd 不再匹配（一个 tmux session 中有多个窗口）：点击跳转按工作目录匹配，无法匹配时降级为仅将宿主 App 调至前台。此为预期行为。
- **非 Ghostty 终端**：精确 tab 聚焦目前仅限 Ghostty；其他终端仅调至前台。宿主未被探测时，可用 `AGENTDECK_NOTIFY_FOCUS=app:<bundle-id>` 强制指定层级。
- **已禁用**：检查 `AGENTDECK_NOTIFY_FOCUS` 是否为 `off`。

### 点击后跳转到了 Finder 文件夹

这是旧版 terminal-notifier 在无点击动作时的行为。请升级到支持点击跳转的 agentdeck 版本（该版本会附加 `-execute`），并确认 `AGENTDECK_NOTIFY_FOCUS` 不为 `off`。

## 常见问题

**需要 tmux/zellij 吗？** 需要 —— agentdeck 通过多路复用器启动并跳转 agent。面板读取的是普通状态文件，但跳转功能需要一个后端。

**点击跳转在 Linux 上可用吗？** 不可用。该功能依赖 macOS + terminal-notifier。Linux 上仍可通过 notify-send 获得横幅通知。

**会影响我已有的 Claude/Codex 配置吗？** 不会。`agentdeck install` 是幂等的，只追加自身条目；不会覆盖已有的 Codex `notify`（而是打印出需要手动添加的那一行）。

**如何查看当前使用的通知器？** 运行 `agentdeck doctor`。

**状态文件在哪里？** 运行 `agentdeck dir`。
