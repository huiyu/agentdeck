# agentdeck

[English](README.md) · **简体中文**

> 你的终端编码 agent 的任务指挥台 —— 一块面板统管 **Claude Code**、**Codex**(以及更多),支持 **zellij** 与 **tmux**。

同时跑多个编码 agent,往往意味着要在一墙的标签页里来回盯着,只为找出哪个已经跑完、或哪个正卡着等你。`agentdeck` 给你一块统一的面板:展示每个活跃会话及其状态,并让你一键跳转过去 —— 还会在某个后台会话需要你时,第一时间弹出桌面通知。

```
agentdeck>  🟡 🟣 blibee:main          3s      ← 等你处理 (Claude)
            🔴 🔵 api:fix-auth         12s      ← 工作中 (Codex)
            🟢 🟣 dotfiles:main         2m      ← 已完成 (Claude)
  🟡 等待 · 🔴 工作中 · 🟢 空闲    │ Enter: 跳转 · Ctrl-x: 移除
```

状态:🟡 **等待**(需要你)· 🔴 **工作中** · 🟢 **空闲**(已完成)。

## 为什么做它

[craftzdog/tmux-claude-session-manager](https://github.com/craftzdog/tmux-claude-session-manager)
在 **tmux + Claude** 上把这件事做得很好。agentdeck 沿两个维度把这个思路推广开来:

- **任意 agent** —— Claude Code 和 Codex 如今提供了*相同*的 hook 设计(JSON 走 stdin、事件名一致),所以把它们统一起来只是一份轻薄的「按 agent 区分」的 profile,而非重写。新增 agent = 一个小文件。
- **任意多路复用器** —— 状态存放在普通文件里,而非 tmux 的 session 变量,所以这块面板在 zellij 和 tmux 下都能用。

## 工作原理

```
        ┌──────────────── core(共享层)────────────────┐
        │   状态文件 · fzf 面板 · 通知 · 排序             │
        └───────┬─────────────────────────────┬──────────┘
            agent 适配器                   mux 适配器
        (事件 → 状态,接线)            (我在哪,如何跳转)
        claude · codex · …              zellij · tmux · …
```

每个 agent 都从它的 hook 里调用 `agentdeck ingest <agent>`,这会为每个会话向 `$XDG_STATE_HOME/agentdeck/` 写入一个 JSON 文件。`agentdeck pick` 读取这些文件 —— 所以无论当前聚焦的是哪个标签页,状态都始终准确;而选择器能把一个会话映射回它所在的多路复用器标签页,从而跳转过去。

为什么用「选择器 + 通知」而不是常驻的「每个标签页一个小圆点」:多路复用器只渲染*当前聚焦*标签页的标题,并会吞掉后台 pane 的转义序列,所以后台 agent 无法可靠地给自己的标签页打标记。面板直接读取状态,而桌面横幅则覆盖「需要你」这个需要主动提醒的时刻。

## 项目结构

```
bin/agentdeck            唯一入口 —— 解析 lib/、加载配置、分发命令
lib/core.sh              共享引擎 —— 状态存储、fzf 面板、通知、排序
lib/agents/<name>.sh     agent 适配器 —— 事件 → 状态,以及如何接线/探测 hook
   ├─ claude.sh          Claude Code profile
   └─ codex.sh           Codex profile(含「等待」状态的 notify 兜底)
lib/mux/<name>.sh        mux 适配器 —— 「我在哪」+「跳转到某个标签页」
   ├─ zellij.sh          zellij 后端(已实现)
   └─ tmux.sh            tmux 后端(已实现)
install.sh               把 CLI 软链到 PATH
agentdeck.example.config 示例配置,拷贝到 ~/.config/agentdeck/config
```

状态以「每个会话一个 JSON 文件」的形式存放在 `$AGENTDECK_STATE_DIR` 下,命名为
`<agent>-<session_id>.json`:

```json
{ "id": "…", "agent": "claude", "state": "waiting", "proj": "blibee",
  "tab": "blibee:main", "cwd": "/…", "transcript": "/…", "msg": "…", "ts": 1750000000 }
```

## 安装

需要 **bash**、**jq**、**fzf**(以及一个通知器:macOS 上为 `terminal-notifier`/
`osascript`,Linux 上为 `notify-send`)。

```sh
git clone https://github.com/huiyu/agentdeck ~/.agentdeck
~/.agentdeck/install.sh        # 把 `agentdeck` 软链到你的 PATH
agentdeck install              # 接线 Claude / Codex 的 hooks(幂等)
agentdeck doctor               # 检查依赖、已探测到的 agent、接线状态
```

然后把面板绑定到一个快捷键,例如在 zsh 中:

```sh
alias ad='agentdeck pick'
```

`agentdeck install` 会就地修补每个已探测到的 agent 的配置:

- **Claude Code** → `~/.claude/settings.json` 的 `hooks`(SessionStart、UserPromptSubmit、Notification、Stop、SessionEnd)
- **Codex** → `~/.codex/hooks.json`(working/idle/end)**以及** `~/.codex/config.toml` 里的一条 `notify`(「等待」信号 —— 见「限制」)

它只会添加自己的条目,重复执行不会重复写入,也不会覆盖已有的 Codex `notify`(而是打印出需要你手动添加的那一行)。

## 用法

| 命令 | 作用 |
|---|---|
| `agentdeck pick` | 打开面板。**Enter** 跳转 · **Ctrl-x** 杀掉该 agent · **Ctrl-d** 移除该行 |
| `agentdeck new [agent]` | 在当前目录所属项目的标签页里启动一个 agent(默认:首个探测到的) |
| `agentdeck doctor` | 依赖、已探测到的 agent、接线状态 |
| `agentdeck install [agent…]` | 接线 hooks(默认:所有已探测到的) |
| `agentdeck list` | 原始 TSV 行(可脚本化) |
| `agentdeck dir` | 打印状态目录(可脚本化) |

**kill 与 forget 的区别。** Ctrl-x 会**终止该 agent**:agentdeck 记录每个会话的 pid(从 hook 沿进程树向上找到 agent 进程)并向其发送 SIGTERM —— 在确认存活进程确实仍属于该 agent 之后才发送,所以即便 pid 被复用也不会误伤别的进程。标签页会作为一个普通 shell 保留(在 zellij 里关闭一个*后台*标签页需要抢占焦点)。Ctrl-d 只是移除该行、让 agent 继续运行 —— 用于清理已失效/崩溃的条目。

## 配置

把 `agentdeck.example.config` 拷贝到 `~/.config/agentdeck/config`(纯 `KEY=value`;全部可选)。每个键也都会从环境变量读取。

| 键 | 默认值 | 作用 |
|---|---|---|
| `AGENTDECK_STATE_DIR` | `$XDG_STATE_HOME/agentdeck` | 每会话状态文件的存放位置 |
| `AGENTDECK_TTL` | `86400` | 超过这么多秒未更新的状态文件将被清理(已死/崩溃的会话) |
| `AGENTDECK_NOTIFY_ON_STOP` | `1` | 会话完成时弹桌面横幅;设为 `0` 则只在*等待*时提醒 |
| `AGENTDECK_MUX` | *(自动探测)* | 强制指定多路复用器,而非从 `$ZELLIJ` / `$TMUX` 自动探测 |
| `AGENTDECK_NOTIFY_SENDER` | *(无)* | 借用另一个 app 的通知图标与身份(一个 bundle id,例如 `com.apple.Terminal`)。需要 `terminal-notifier`;对 osascript 兜底无效 |
| `AGENTDECK_NOTIFY_ICON` | *(无)* | 自定义通知图标图片的路径/URL。需要 `terminal-notifier`;对 osascript 兜底无效 |

## 扩展它

面板、状态存储与通知都与具体的 agent 和 mux 无关。新增支持只需在两条适配器轴线之一上加一个文件。

**新增一个 agent** —— `lib/agents/<name>.sh`(可参照 `claude.sh`):

- `AGENT_F_SID` / `AGENT_F_CWD` / `AGENT_F_TRANSCRIPT` —— 进入 hook JSON 的 jq 路径
- `agent_detect` —— 这个 agent 是否已安装?
- `agent_state_for <event>` —— 把一个 hook 事件映射为 `idle` / `working` / `waiting` / `gone` / `skip`
- `agent_notify_state <type>` —— 同上,用于带外的 `notify` 传输通道(没有则 `echo skip`)
- `agent_installed` / `agent_install <self>` —— 检查并幂等地接线 hook

然后把它的图标加到 `lib/core.sh` 的 `_agentdeck_icon_json` 里。

**新增一个多路复用器** —— `lib/mux/<name>.sh` 只需两个函数:

- `mux_jump <proj> <tab>` —— 聚焦到该会话的标签页(支撑 `agentdeck pick`)
- `mux_launch <proj> <tab> <cwd> <cmd>` —— 新开一个运行 `<cmd>` 的标签页(支撑 `agentdeck new`)

zellij(`lib/mux/zellij.sh`)与 tmux(`lib/mux/tmux.sh`)两个后端都恰好实现了这两个函数 —— 可作为参考。

## 限制(v0.1)

- **Codex 的「等待」是尽力而为。** Codex 尚未把 `approval-requested` 暴露给 hooks([openai/codex#14813](https://github.com/openai/codex/issues/14813)),所以它通过 `notify` 程序送达,而后者既不带 session id 也不带 cwd([#4005](https://github.com/openai/codex/issues/4005));agentdeck 会把它匹配到该目录下最新的 Codex 会话。工作中/空闲(经由 hooks)则是精确的。
- **跨 zellij 会话跳转**需要先 detach(你无法在一个会话内部 attach 另一个会话)。

## 路线图

- v0.2:可选的 zellij `zjstatus` 小组件,在状态栏常驻显示一个聚合计数。
- 之后:随着各自的 hook 支持落地,接入更多 agent(gemini-cli、aider、opencode)。

## 许可证

MIT © Jeff Yu
