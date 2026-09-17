# Muster

[English](README.md) · **中文**

在 Omarchy 状态栏里看住你的 coding agent:谁在跑、谁在等你、谁刚干完活 ——
完成时还有提示音和系统弹窗,不需要开任何终端复用器。

- **状态栏图标** —— 每个有会话的 agent 一个标记,按"谁更急"排序(先 blocked,
  再 working)。每个标记按**自己那个会话的状态**着色:blocked 用警示色、working 用
  主题强调色、idle 用状态栏文字色 —— 混在一起也能一眼分清,而不是整条图标全变成
  同一种颜色。标记用的是 **omarchy 自己的品牌字形**(`omarchy default agent`
  菜单里用的那一套),不是我自己凑的符号。窗口刻意做窄:超过 5 个标记就裁剪并
  滚动(和 omarchy 媒体插件跑长歌名的方式一样),再忙也不会把时钟挤走。它始终
  显示;没有会话时是一枚铃铛 —— 会消失的图标是点不开的图标。
- **面板**(点图标打开)—— 每个会话一张卡片:agent 的标记 + 它所在的项目文件夹,
  下面一行是状态要说的话(最后一条 prompt,或阻塞时的提示)。卡片上不写 agent
  名字 —— 标记说明是谁,文件夹说明在哪。卡片内部永远是同一个灰色,状态体现在
  **边框和标题**上:working 是柔和的主题色呼吸边框,blocked 用警示色,idle 不变。
  没有计时器:面板只回答"有没有在跑、要不要我去看"。
- **提醒** —— 一次运行结束时响一声 + 发一条 Omarchy 通知;点通知会聚焦到那个终端。
  **点卡片**可以按需为那个会话触发同样的提醒,通知标题会带上 `test`,不会和真实
  完成混淆。

## 截图

![面板](assets/panel.png)

![状态栏图标](assets/chip.png)

截图放在 [`assets/`](assets/README.md);市场列表卡片是仓库根目录下可选的一个
`preview.png`。

## 状态是怎么来的

**只认记录(records)。** agent 每个会话写一个小 JSON 文件,插件只监听那个目录。
没有窗口标题抓取、没有进程扫描、没有规则引擎 —— 没有任何会猜错状态、或者悄悄
失效的东西。自带的 pi 桥接上报精确的 `working` / `blocked` / `idle`,外加一个
`completedRuns` 计数器,让"刚跑完一次"不可能被漏掉。

所以接入别的 agent 同样是精确的:写记录即可,见下面的「接入其它 agent」。

## 安装

```bash
# 1. 安装 shell 插件
omarchy plugin add https://github.com/77-223255/omarchy-muster.git --enable
omarchy plugin enable shienze.muster left     # 如果上面没加 --enable,这里选位置

# 2. 装 pi 桥接
ln -sfn ~/.config/omarchy/plugins/shienze.muster/pi/muster.ts \
        ~/.pi/agent/extensions/muster.ts

# 3. 体检:它依赖的每个外部命令都会检查一遍
~/.config/omarchy/plugins/shienze.muster/bin/muster-doctor
```

桥接要**重启 pi** 才会加载。改 `.qml` 是热重载的,只有 IPC 目标例外:改完要
`omarchy restart shell`。

### 从源码目录开发

`omarchy plugin add` 会把仓库克隆到 `~/.config/omarchy/plugins/<id>/`。如果你想
直接改自己的 checkout,就让那个路径指向仓库 —— shell 会跟随软链,插件 id 仍然
来自 `manifest.json`:

```bash
git clone https://github.com/77-223255/omarchy-muster.git ~/Projects/omarchy-muster
ln -sfn ~/Projects/omarchy-muster ~/.config/omarchy/plugins/shienze.muster
omarchy-shell shell rescanPlugins
omarchy plugin enable shienze.muster left
```

## 卸载

```bash
# 1. 移掉 pi 桥接
rm -f ~/.pi/agent/extensions/muster.ts

# 2. 移除 shell 插件(会删掉状态栏条目和插件目录)
omarchy plugin disable shienze.muster
omarchy plugin remove shienze.muster

# 3. 删掉它读的会话记录
rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/muster"
```

`omarchy plugin remove` 只做两件事:删插件目录、删 `~/.config/omarchy/shell.json`
里的那条条目。如果你是上面那种"软链 checkout"的装法,改成删软链和你的 clone:

```bash
rm -f ~/.config/omarchy/plugins/shienze.muster
rm -rf ~/Projects/omarchy-muster
```

除了 `~/.config/omarchy/`、`~/.local/state/omarchy/muster/` 和那个 pi 桥接软链,
它不碰任何文件;也不会在你不知情的情况下覆盖用户配置(改设置只有你在面板里点)。

## 用法

| 位置 | 操作 |
|------|------|
| 状态栏图标 | 左键 = 开面板,中键 = 测试提醒 |
| 面板卡片 | 点击 = 为这个会话发一条测试提醒 |
| 面板按键 | `j`/`k` 移动,Enter 触发选中卡片,`t` 触发第一个会话,Esc 关闭 |
| IPC | `omarchy-shell shienze.muster <open\|close\|toggle\|test\|status>` |

```bash
omarchy-shell shienze.muster status | jq '.details[]'
# {"agent":"pi","state":"working","folder":"tiny-model-primitives",
#  "pid":835161,"completedRuns":3,"window":"0x601dc3f347b0"}
```

## 设置

只有两个开关,面板里可以点,也存在 `~/.config/omarchy/shell.json`:

| 键 | 默认 | 含义 |
|-----|---------|------|
| `soundEnabled` | `true` | 运行结束时响一声 |
| `notifyEnabled` | `true` | 运行结束时发系统通知 |

其余参数**刻意写死在代码里** —— 一个因为某个歪设置而悄悄不响的部件,比一个需要
改一行代码才能调的要糟得多。它们在 `Service.qml` 顶部:

| 常量 | 值 | 含义 |
|----------|-------|---------|
| `refreshIntervalSec` | `2` | 扫描新增/删除记录的间隔(已存在的记录是文件监听,所以提醒是即时的) |
| `staleAfterSec` | `120` | 多久没心跳就忘掉一条记录(桥接每 30s 心跳一次) |
| `debounceMs` | `2000` | 多个会话同时结束只提醒一次 |
| `soundFile` | freedesktop `complete.oga` | |
| `soundPlayer` | `paplay` | `pw-play` / `mpv` 也行 |

## 记录契约

每个会话一个 JSON 对象,放在
`$XDG_STATE_HOME/omarchy/muster/sessions/`(默认 `~/.local/state/...`),文件名以
`.json` 结尾即可。写入要原子(临时文件 + `rename`),并定期重写一次当心跳。

| 字段 | 说明 |
|-------|-------|
| `schemaVersion` | `1` |
| `agent` | 必填;任何 id 都行,omarchy 自己的别名(`claude-code`、`oh-my-pi`、`cursor`…)会归并到规范 id |
| `sessionId`、`name`、`cwd`、`project` | 身份与显示;`project` 默认取 `cwd` 的最后一段 |
| `state` | `working` \| `blocked` \| `idle` \| `unknown` |
| `message` | `blocked` 时显示 |
| `lastPrompt` | 显示在卡片上 |
| `pid` | 归属进程;也是去重依据(同 pid 的多条只留最新) |
| `windowAddress` | Hyprland 窗口地址;让通知被点击时能聚焦那个终端 |
| `updatedAt` | 毫秒时间戳;决定过期(`staleAfterSec`) |
| `completedRuns` | **提醒的触发器** —— 每完成一次运行就 +1 |
| `seq` | 单调递增的写入计数,用来在两条同 pid 记录里挑最新的 |

提醒看的是 `completedRuns` **增长**,而不是状态变化 —— 所以哪怕一次很短的运行在
两次扫描之间就 `working → idle` 过去了,也照样会响,且只响一次。

## omarchy 自带的 agent

`omarchy default agent` 接受的 13 个 agent 全部按名字认识,同时也接受那条命令的
别名:`claude-code`、`oh-my-pi`、`open-code`、`cursor`、`github-copilot`、
`gemini-cli`、`muse-code` 等等。用别名写的记录会归并到规范 agent,不会变成第二个。

状态栏图标画的是 omarchy 自己的标记,取自
`/usr/share/omarchy/default/omarchy/omarchy-menu.jsonc` 里的
`setup.default.agent.*`:8 个是 `/usr/share/fonts/omarchy/omarchy.ttf` 里的品牌
字形(U+E901…U+E90D),5 个是 Nerd Font 字形 —— 和 omarchy 菜单用的完全一样。

| id | 面板显示 | 还接受 |
|----|----------|--------------|
| `pi` | Pi | `pi-coding-agent` |
| `omp` | Oh My Pi | `oh-my-pi` |
| `opencode` | OpenCode | `open-code` |
| `claude` | Claude | `claude-code`、`anthropic` |
| `codex` | Codex | `openai-codex` |
| `copilot` | Copilot | `github-copilot` |
| `crush` | Crush | |
| `cursor-agent` | Cursor | `cursor` |
| `gemini` | Gemini | `gemini-cli` |
| `grok` | Grok | |
| `hermes` | Hermes | |
| `muse` | Muse | `muse-code`、`musecode` |
| `openclaw` | OpenClaw | |

其它 id 也能用,只是以自己的 id 显示(没有标记,除非你给它一个)。加一个 agent
就是在 `Model.js` 顶部的 `AGENTS` 表里加一行,填上 omarchy 给它的码点。

## 接入其它 agent

不是 pi 的 agent,一律用 `bin/muster-report` 上报:

```bash
report=~/.config/omarchy/plugins/shienze.muster/bin/muster-report

$report --agent claude --session "$SESSION_ID" --state working \
        --name "Refactor auth" --cwd "$PWD" --prompt "$PROMPT"
$report --agent claude --session "$SESSION_ID" --state blocked --message "approve"
$report --agent claude --session "$SESSION_ID" --state idle --completed  # 响一声 + 弹窗
$report --agent claude --session "$SESSION_ID" --remove
```

它会用 `--pid`(默认 `$PPID`)沿进程链在 Hyprland 窗口列表里找到你所在的终端,
所以"点通知聚焦终端"不需要额外配置。于是 Claude Code 的 `Stop` hook 只要一行:

```jsonc
// ~/.claude/settings.json
{ "hooks": { "Stop": [ { "hooks": [ { "type": "command",
  "command": "~/.config/omarchy/plugins/shienze.muster/bin/muster-report --agent claude --session \"$CLAUDE_SESSION_ID\" --state idle --completed" } ] } ] } }
```

### omarchy 提供了什么、没提供什么

**没有**一个统一的 agent 状态钩子可接。相邻的东西只有三样:

- `omarchy agent` 启动默认 agent 时,会给每个它开出来的窗口打上 class
  **`org.omarchy.agent`**(故意所有 agent 共用,给窗口规则和主题用)。这是一个
  可靠的"这是 omarchy 启动的 agent 窗口"信号,但它不告诉你**是哪个** agent、
  也**不知道在不在跑** —— 而且 `--inline` 会绕过它。
- `~/.config/omarchy/hooks/<event>.d/` 只是生命周期钩子:`battery-low`、
  `font-set`、`post-boot`、`post-update`、`pre-refresh-pacman`、`theme-set`。
  没有一个会在 agent 活动时触发。
- `omarchy-agent-usage-<agent>` **确实是**统一插件接口,但那是**额度**:一个
  agent 一个采集器,写一条 `omarchy.agents` 读的 JSON 记录。本插件刻意照它的
  形状做"状态"。

所以状态只能由 agent 自己报:它有 hook 就用 hook(Claude 的 `Stop`、Codex 的
`notify`、pi 的扩展 API),没有就套一层 wrapper。汇入口都是上面那一行命令。

## 依赖

无构建步骤、无包管理器、运行期不联网。语言是宿主定的,不是选的:omarchy 的状态栏
部件/服务必须是 QML,pi 扩展必须是 TypeScript。

| 部分 | 语言 | 依赖 |
|-------|----------|-----------|
| `Service.qml`、`BarWidget.qml`、`Panel.qml`、`Record.qml` | QML | omarchy shell(Quickshell、Qt 6)、`hyprctl`、`find`、`mkdir` |
| `Model.js` | JavaScript(QML 引擎) | 无 |
| `pi/muster.ts` | TypeScript | pi 自带的 Bun 运行时;只用 node 内置模块,零 npm 依赖 |
| `bin/muster-report` | Bash | `jq`、`flock`、`hyprctl` |
| 提醒 | — | `paplay`(或 `pw-play`/`mpv`)和 `omarchy-notification-send` |

`bin/muster-doctor` 会把上面每一条都查一遍(`--json` 给机器读),只有必需项缺失
时才以非 0 退出。

用 Rust 在这里没有收益:它既当不了 Quickshell 插件,也当不了 pi 扩展,编译型组件
只能是"一个带 socket 的独立守护进程"(正是本插件要避免的重东西),或者替换掉一个
在 omarchy 上本来就有的 `jq`+`flock` 脚本。

## 刻意不做的事

去检测那些什么都不上报的 agent(抓窗口标题、嗅探进程)。这个东西写过、能用,代价
是 ~700 行加一个规则引擎 —— 因为终端外面的部件看不到 pane 内容;而且一个进程托管
多个窗口的终端(ghostty 单实例、kitty)会让 `pid → 窗口` 产生歧义,光凭标题匹配
证明不了什么。接入新 agent 的正解是给它写 hook。哪天真想要自动检测,**省钱的版本**
是拿 omarchy 自己的 `org.omarchy.agent` class 当闸门(而不是嗅探进程),而且它应该
是独立的小插件,不该塞进这里。

## 文件

| 路径 | 作用 |
|------|---------|
| `manifest.json` | 插件清单(`service` + `bar-widget`) |
| `Service.qml` | 单例:监听记录、排序会话、触发提醒 |
| `BarWidget.qml` | 状态栏图标、设置推送、IPC |
| `Panel.qml` | 会话面板和两个开关 |
| `Record.qml` | 单条记录的文件监听 |
| `Model.js` | 记录归一化、排序、agent 名字与标记 |
| `pi/muster.ts` | pi → 记录 桥接 |
| `bin/muster-report` | 给其它 agent 的记录写入器 |
| `bin/muster-doctor` | 依赖体检 |
| `assets/` | README 截图 |
| `preview.png` | 市场列表卡片(可选,放根目录) |
| `docs/submission-body.md` | 提交 issue 的正文 |
| `docs/marketplace-submission.md` | 如何提交那个 issue |

## 排查

```bash
omarchy-shell shienze.muster status | jq '.details[]'   # 部件当前看到什么
~/.config/omarchy/plugins/shienze.muster/bin/muster-doctor   # 依赖
journalctl --user --since "5 min ago" -o cat SYSLOG_IDENTIFIER=omarchy-shell | grep -i muster
omarchy-shell shienze.muster test                        # 验证提醒链路
```

- **图标一直是暗的**:没有记录在写。跑一个 agent,或者用 `muster-report` 手写一条。
- **崩溃后会话还挂着**:最后一次心跳起 `staleAfterSec` 之后它会自动消失。
- **没有声音**:`command -v paplay`,并检查面板里的 *Completion sound* 开关。
- **改完代码 IPC 函数不见了**:`omarchy restart shell`。

## 许可

MIT —— 见 [LICENSE](LICENSE)。
