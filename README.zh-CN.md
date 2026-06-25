# agentdeck

[English](README.md) · **简体中文**

> 你的终端编码 agent 的任务指挥台 —— 一块面板统管 **Claude Code**、**Codex**(以及更多),支持 **zellij** 与 **tmux**。

同时跑多个编码 agent,往往意味着要在一墙的标签页里来回盯着,只为找出哪个已经跑完、或哪个正卡着等你。`agentdeck` 给你一块统一的面板:展示每个活跃会话及其状态,并让你一键跳转过去 —— 还会在某个后台会话需要你时第一时间弹出桌面通知。**点击通知即可跳回那个精确的标签页。**

```
agentdeck>  🟡 🟣 blibee:main          3s      ← 等你处理 (Claude)
            🔴 🔵 api:fix-auth         12s      ← 工作中 (Codex)
            🟢 🟣 dotfiles:main         2m      ← 已完成 (Claude)
  🟡 等待 · 🔴 工作中 · 🟢 空闲    │ Enter: 跳转 · Ctrl-x: 终止 · Ctrl-d: 移除
```

状态:🟡 **等待**(需要你)· 🔴 **工作中** · 🟢 **空闲**(已完成)。

> **初次使用?** 直接看[快速上手](#快速上手)。想了解所有参数和故障排查?见 **[使用手册](docs/USAGE.zh-CN.md)**。

## 目录

- [为什么做它](#为什么做它)
- [工作原理](#工作原理)
- [快速上手](#快速上手)
- [用法](#用法)
- [通知与点击跳转](#通知与点击跳转)
- [配置](#配置)
- [状态模型](#状态模型)
- [扩展 agentdeck](#扩展-agentdeck)
- [限制](#限制)
- [路线图](#路线图)
- [许可证](#许可证)

## 为什么做它

[craftzdog/tmux-claude-session-manager](https://github.com/craftzdog/tmux-claude-session-manager)
在 **tmux + Claude** 上把这件事做得很好。agentdeck 沿两个维度把这个思路推广开来:

- **任意 agent** —— Claude Code 和 Codex 如今提供了*相同*的 hook 设计(JSON 走 stdin、事件名一致),所以把它们统一起来只是一份轻薄的「按 agent 区分」的 profile,而非重写。新增 agent = 一个小文件。
- **任意多路复用器** —— 状态存放在普通文件里,而非 tmux 的 session 变量,所以这块面板在 zellij 和 tmux 下都能用。

为什么用「选择器 + 通知」而不是常驻的「每个标签页一个小圆点」:多路复用器只渲染*当前聚焦*标签页的标题,并会吞掉后台 pane 的转义序列,所以后台 agent 无法可靠地给自己的标签页打标记。面板直接读取状态,而桌面横幅则覆盖「需要你」这个需要主动提醒的时刻。

## 工作原理

```
        ┌──────────────── core (shared) ────────────────┐
        │  state files · fzf board · notifications · rank │
        └───────┬─────────────────────────────┬──────────┘
            agent adapter                  mux adapter
        (events → state, wiring)        (where am I, jump)
        claude · codex · …              zellij · tmux · …
```

每个 agent 都从它的 hook 里调用 `agentdeck ingest <agent>`,这会为每个会话向 `$XDG_STATE_HOME/agentdeck/` 写入一个 JSON 文件。`agentdeck pick` 读取这些文件 —— 所以无论当前聚焦的是哪个标签页,状态都始终准确;而选择器能把一个会话映射回它所在的多路复用器标签页,从而跳转过去。

同一份状态文件也驱动**点击跳转**:点击通知后会运行 `agentdeck focus <file>`,读取会话记录的宿主终端与多路复用器,将那个精确的标签页调到前台。详见[通知与点击跳转](#通知与点击跳转)。

## 快速上手

需要 **bash**、**jq**、**fzf**,以及一个通知器(macOS 上为 `terminal-notifier` —— 见[通知](#通知与点击跳转);Linux 上为 `notify-send`)。

```sh
git clone https://github.com/huiyu/agentdeck ~/.agentdeck
~/.agentdeck/install.sh        # symlink `agentdeck` onto your PATH
agentdeck install              # wire Claude / Codex hooks (idempotent)
agentdeck doctor               # verify deps, detected agents, wiring

# (macOS) for clickable, jump-back notifications:
brew install terminal-notifier
```

把面板绑定到一个快捷键,例如在 zsh 中:

```sh
alias ad='agentdeck pick'
```

`agentdeck install` 会就地修补每个已探测到的 agent 的配置,只添加自己的条目(幂等,不覆盖已有内容):

- **Claude Code** → `~/.claude/settings.json` 的 `hooks`(SessionStart、UserPromptSubmit、Notification、Stop、SessionEnd)
- **Codex** → `~/.codex/hooks.json`(working/idle/end)**以及** `~/.codex/config.toml` 里的一条 `notify`(「等待」信号 —— 见[限制](#限制))

完整安装/接线说明:**[使用手册 → 安装与接入](docs/USAGE.zh-CN.md#安装与接入)**。

### 更新

agentdeck 就是一个 git clone 加一个符号链接,所以就地更新即可 —— 无需重建链接:

```sh
git -C ~/.agentdeck pull   # 换成你实际 clone 的目录
agentdeck version          # 确认新版本
agentdeck doctor           # 检查 deps / 接线 / notifier
```

只有当 `doctor` 提示接线缺失、或你新增了 agent 时,才需要重跑 `agentdeck install`(幂等)。点击跳转是运行时接线的,无需重新 install —— 但需要 `terminal-notifier`(见[通知与点击跳转](#通知与点击跳转))。

## 用法

| 命令 | 作用 |
|---|---|
| `agentdeck pick` | 打开面板。**Enter** 跳转 · **Ctrl-x** 终止 agent · **Ctrl-d** 移除该行 |
| `agentdeck new [agent]` | 在当前目录所属项目的标签页里启动一个 agent(默认:首个探测到的) |
| `agentdeck doctor` | 依赖、已探测到的 agent、接线状态 |
| `agentdeck install [agent…]` | 接线 hooks(默认:所有已探测到的) |
| `agentdeck list` | 原始 TSV 行(可脚本化) |
| `agentdeck dir` | 打印状态目录(可脚本化) |
| `agentdeck version` · `help` | 版本 / 用法 |

`ingest` 与 `focus` 供 hook 和通知点击使用 —— 无需手动调用。所有命令、参数和退出码:**[使用手册 → 命令](docs/USAGE.zh-CN.md#命令)**。

**kill 与 forget 的区别。** Ctrl-x 会**终止该 agent**:agentdeck 记录每个会话的 pid(从 hook 沿进程树向上找到 agent 进程)并向其发送 SIGTERM —— 在确认存活进程确实仍属于该 agent 之后才发送,所以即便 pid 被复用也不会误伤别的进程。标签页会作为一个普通 shell 保留。Ctrl-d 只是移除该行、让 agent 继续运行 —— 用于清理已失效/崩溃的条目。

## 通知与点击跳转

agentdeck 在会话进入**等待**状态时弹出桌面横幅,默认也会在会话**完成**时弹出(可用 `AGENTDECK_NOTIFY_ON_STOP` 切换)。**点击横幅即可跳回那个会话的标签页。**

按优先级依次选用第一个可用的通知器:

| 通知器 | 横幅 | 点击跳转 | 备注 |
|---|---|---|---|
| **terminal-notifier** | ✅ | ✅ | macOS;`brew install terminal-notifier`。唯一支持点击动作的后端 |
| **osascript**(内置) | ✅ | ❌ | macOS 兜底;macOS 禁止对此类通知自定义点击动作 |
| **notify-send** | ✅ | 部分支持 | Linux |

**点击跳转**(macOS + terminal-notifier)由 `AGENTDECK_NOTIFY_FOCUS` 控制,并按宿主终端优雅降级:

- **Ghostty** —— 精确聚焦到*对应*标签页(按工作目录匹配)。
- **iTerm2 / 其它** —— 将终端 App 调到前台。
- **VS Code** —— 复用该项目的窗口。
- 目标标签页已关闭或其 cwd 已漂移 → 降级为仅将 App 调到前台。

### macOS 设置(一次性)

不做此步骤该功能将静默失效:

1. `brew install terminal-notifier`
2. **系统设置 → 通知 → terminal-notifier** → 打开*允许通知*,并将样式设为 **提醒**(横幅会自动消失,容易错过或误点)。
3. **第一次**点击横幅时,macOS 会询问是否允许 *terminal-notifier 控制你的终端* —— 点击**允许**(永久生效)。

横幅不显示或点击后不跳转?见 **[使用手册 → 故障排查](docs/USAGE.zh-CN.md#故障排查)**。

## 配置

把 `agentdeck.example.config` 拷贝到 `~/.config/agentdeck/config`(纯 `KEY=value`;全部可选)。每个键也都会从环境变量读取。

| 键 | 默认值 | 作用 |
|---|---|---|
| `AGENTDECK_STATE_DIR` | `$XDG_STATE_HOME/agentdeck` | 每会话状态文件的存放位置 |
| `AGENTDECK_TTL` | `86400` | 超过这么多秒未更新的状态文件将被清理(已死/崩溃的会话) |
| `AGENTDECK_MUX` | *(自动探测)* | 强制指定多路复用器,而非从 `$ZELLIJ` / `$TMUX` 自动探测 |
| `AGENTDECK_NOTIFY_ON_STOP` | `1` | 会话完成时弹桌面横幅;设为 `0` 则只在*等待*时提醒 |
| `AGENTDECK_NOTIFY_FOCUS` | `auto` | 点击横幅跳回会话。`auto` 自动探测宿主终端(Ghostty 精确切到对应 tab；其它终端将 App 调前台；VS Code 复用项目窗口);可强制 `ghostty` / `vscode` / `app:<bundle-id>`,或设 `off` 关闭。仅 macOS + `terminal-notifier` |
| `AGENTDECK_NOTIFY_SENDER` | *(无)* | 借用另一个 App 的通知图标与身份(bundle id,例如 `com.apple.Terminal`)。仅 `terminal-notifier` |
| `AGENTDECK_NOTIFY_ICON` | *(无)* | 自定义通知图标图片的路径/URL。仅 `terminal-notifier` |
| `AGENTDECK_CONFIG` | `~/.config/agentdeck/config` | 配置文件本身的路径 |

## 状态模型

状态以「每个会话一个 JSON 文件」的形式存放在 `$AGENTDECK_STATE_DIR` 下,命名为 `<agent>-<session_id>.json`:

```json
{ "id": "…", "agent": "claude", "state": "waiting",
  "proj": "blibee", "tab": "blibee:main", "cwd": "/…",
  "transcript": "/…", "msg": "…", "pid": 12345,
  "host": "ghostty", "mux": "tmux", "ts": 1750000000 }
```

`host`(启动 agent 的终端)和 `mux`(多路复用器)在 hook 时捕获,使脱离终端的通知点击处理器也能跳回对应标签页。逐字段说明:**[使用手册 → 状态文件](docs/USAGE.zh-CN.md#状态文件)**。

## 扩展 agentdeck

面板、状态存储与通知都与具体的 agent 和 mux 无关。新增支持只需在两条适配器轴线之一上加一个文件。

**新增一个 agent** —— `lib/agents/<name>.sh`(参照 `claude.sh`):

- `AGENT_F_SID` / `AGENT_F_CWD` / `AGENT_F_TRANSCRIPT` —— 进入 hook JSON 的 jq 路径
- `agent_detect` —— 这个 agent 是否已安装?
- `agent_state_for <event>` —— 把一个 hook 事件映射为 `idle` / `working` / `waiting` / `gone` / `skip`
- `agent_notify_state <type>` —— 同上,用于带外的 `notify` 传输通道(没有则 `echo skip`)
- `agent_installed` / `agent_install <self>` —— 检查并幂等地接线 hook

然后把它的图标加到 `lib/core.sh` 的 `_agentdeck_icon_json` 里。

**新增一个多路复用器** —— `lib/mux/<name>.sh` 实现三个函数:

- `mux_jump <proj> <tab>` —— 聚焦到该会话的标签页(支撑 `agentdeck pick`)
- `mux_launch <proj> <tab> <cwd> <cmd>` —— 新开一个运行 `<cmd>` 的标签页(支撑 `agentdeck new`)
- `mux_select <proj> <tab>` —— 在**不 attach** 的情况下选中该窗口(支撑点击跳转,以脱离终端方式运行)

zellij(`lib/mux/zellij.sh`)与 tmux(`lib/mux/tmux.sh`)两个后端均可作为参考。完整说明:**[使用手册 → 扩展](docs/USAGE.zh-CN.md#扩展)**。

## 限制

- **Codex 的「等待」是尽力而为。** Codex 尚未把 `approval-requested` 暴露给 hooks([openai/codex#14813](https://github.com/openai/codex/issues/14813)),所以它通过 `notify` 程序送达,而后者既不带 session id 也不带 cwd([#4005](https://github.com/openai/codex/issues/4005));agentdeck 会把它匹配到该目录下最新的 Codex 会话。工作中/空闲(经由 hooks)则是精确的。
- **点击跳转的精确度目前仅限 Ghostty。** 其它终端只能将 App 调到前台,无法从外部选中精确标签页;VS Code 复用项目窗口。iTerm2 / WezTerm / kitty 的精确聚焦留待未来适配器实现。
- **点击跳转按工作目录匹配**,若目标标签页已关闭或其 cwd 已漂移(同一 tmux session 中存在多个窗口),则降级为将宿主 App 调到前台。
- **zellij 点击时的窗口选择目前为空操作**(zellij 无法从外部在 detached session 中选中标签页,tmux 可以);宿主 App 仍会被调到前台。
- **跨 zellij 会话跳转**需要先 detach(你无法在一个会话内部 attach 另一个会话)。

## 路线图

- 随着各自的 hook 支持落地,接入更多 agent(gemini-cli、aider、opencode)。
- 为 iTerm2 / WezTerm / kitty 实现精确点击跳转适配器。
- 可选的 zellij `zjstatus` 小组件,在状态栏常驻显示聚合计数。

## 许可证

MIT © Jeff Yu
