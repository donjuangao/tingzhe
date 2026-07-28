# moss-ptt · macOS 中文语音输入 + 语音对话

一个 macOS 后台小程序，两种用法：

- **按住说话** — 按住一个键说话，松开 → 转写 → 专名词表修正 → 自动粘贴到当前焦点输入框。
- **语音对话** — 麦克风常开，你说话它转写并发送，对方的回复念给你听；你一开口它立刻闭嘴。

零第三方依赖，只需要 Xcode Command Line Tools（`swiftc`）。Swift + 几个 Python 标准库脚本，没有包管理器。

⚠ **自带 API key。** 默认接的是 [MOSS / MOSI](https://platform.mosi.cn)，但它的接口是 OpenAI 那个形状（`/v1/audio/transcriptions`、`/v1/audio/speech`），**换成任何 OpenAI 兼容的服务只要改 `api_base` 一个字符串**——代码里没有第二处要动的地方。这个版本刻意不做兼容层。

---

## 装

```bash
git clone <this repo> && cd moss-ptt
cp env.example .env.local        # 填进你的 API key
./build.sh
```

第一次跑要给两个权限：

| 权限 | 什么时候要 | 不给会怎样 |
|---|---|---|
| **麦克风** | 首次启动弹窗 | 直接退出 |
| **辅助功能** | 手动加：系统设置 → 隐私与安全性 → 辅助功能 → `moss-ptt.app` | 还能用，但转写只进剪贴板，要自己 ⌘V；单键热键退化成组合键 |

前台跑（能看日志）：

```bash
./moss-ptt.app/Contents/MacOS/moss-ptt
```

装成开机自启的常驻：

```bash
./install-agent.sh install     # status / uninstall
```

## 用

按住热键（默认右 ⌥）说话，松开出字。就这样。

**语音对话模式**：按 `⌃⌥V` 打开，屏幕右上角出现一个红色徽章。点它出面板：

- 跟哪个会话说话
- **收音灵敏度** 三档 —— 嘈杂环境点「迟钝」
- **发送方式** —— `攒成一条`（等你真停下来再发，边想边说不会被切碎）／ `一句一条`（说完一句立刻发）
- **快捷键** —— 点一下就能改，按下你想要的组合键即可（单键、轻点 ⌘/⌃/⌥ 都行）
- **按住说话** 用哪把键

## 配

所有配置在 `config.json`（没有就从 `config.example.json` 复制一份，程序读不到会自动退回示例）。改完大多**热重载**，不用重启。

```jsonc
{
  "api_base": "https://api.mosi.cn/v1",   // 换服务商只改这里
  "hotkey": "rightOption",                 // 按住说话
  "voice_toggle_key": "ctrl+opt+v",        // 语音对话 开/关
  "voice_mute_key":   "ctrl+opt+m",        // 单方面静音（我不说，它还念给我听）
  "voice_mode_key":   "ctrl+opt+b",        // 攒成一条 ⇄ 一句一条
  "voice_gate_mult": 3.5,                  // 收音门槛 = max(voice_start_rms, 环境底噪 × 这个)
  "voice_start_rms": 0.035,                // 绝对下限：嘈杂环境真正起作用的是它
  "voice_send_after_ms": 3200,             // 停多久算"这句说完了"
  "tts_model": "moss-tts",                 // 念给你听用哪个模型（只在语音对话里用到）
  "hud": true                              // 转写完在右上角闪一下结果；不想看就 false
}
```

**快捷键写法**：任意修饰键组合 + 任意主键，大小写随意。`ctrl+opt+v` · `cmd+shift+m` · `⌃⌥space` · `f13` · 单独一个 `cmd`（轻点一下）。设成 `none` = 不绑。

⚠ 不拦你选任何键。会误触发的会提醒（裸字母打字时会触发、左侧修饰键日常在用），但**选不选是你的事**。

## 语音对话怎么接上（要多一步）

「按住说话」装完就能用。**「语音对话」还需要把两个钩子接进 Claude Code**——
因为它要在 Claude 回答完的那一刻拿到回复正文念给你听，而这件事只有 Claude 自己能告诉它。

编辑 `~/.claude/settings.json`，把这两条加进去（把路径换成你 clone 的位置）：

```jsonc
{
  "hooks": {
    // 每轮回答结束 → 把回复念出来
    "Stop": [
      { "hooks": [ { "type": "command",
                     "command": "/你的路径/moss-ptt/speak-hook.sh" } ] }
    ],
    // 每次你发消息 → 记下"你在跟哪个会话说话"，并拉起边写边念的进程
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command",
                     "command": "/你的路径/moss-ptt/active-session-hook.sh" } ] }
    ]
  }
}
```

已经有 `hooks` 段的话，把这两条**加进已有数组**，别整段覆盖。

四个文件各干什么：

| 文件 | 干什么 |
|---|---|
| `active-session-hook.sh` | 记录活跃会话，供徽章上那个"跟哪个 session 说话"的列表使用 |
| `speak-watch.py` | **边写边念**：盯着回复落盘，每攒够一句就合成播放，所以第一声大约 1 秒就出来 |
| `speak-hook.sh` | 兜底：`speak-watch.py` 没在跑时，整轮结束后念一次 |
| `speakify.py` | 口播过滤器：把代码块、路径、markdown 记号去掉，只留能听的部分 |

⚠ 这条链会把**回复正文**发给你配的 TTS 服务。那里面可能有你的代码和路径 ——
不接这两个钩子，「按住说话」完全不受影响。

## 专名词表

模型听不准的专有名词，写进 `dict.json`（没有就用仓库带的 `dict.example.json`）：

```json
[["work tree", "worktree"], ["front matter", "frontmatter"]]
```

⛔ **顺序有意义**：长模式必须排在短模式前面，否则短的会先咬掉一段。加词用

```bash
./moss-ptt.app/Contents/MacOS/moss-ptt --fix <听错的> <正确的>
```

它会自动插到正确位置。改完跑 `./check.sh`。词表**热重载**，不用重启。

⚠ **英文规则有词边界保护，中文没有。** 中文不分词，一条 2 字规则 `星规→星轨` 会把包含它的更长真词（比如某个人名）一起改掉。缓解办法是 `protect.json`（把不该被改的词指出来）和 `negatives.txt`（把误伤过的句子记一行，`check.sh` 从此永久守着）。**这是这个方法的上限，不是 bug。**

## 收尾闸

```bash
./check.sh
```

十几项，全绿才算完成。它测的是**产品本身**，不是产品的副本——这个项目为此栽过三次，注释里都记着。

`ENGINEERING-NOTES.md` 是踩过的坑，跟这个项目本身无关的那些也许对你有用。

## 不做什么

- 不做多服务商兼容层（换 `api_base` 就够）
- 不做 Windows / Linux（整个东西建立在 macOS 的 TCC、AVAudioEngine、辅助功能 API 上）
- 不做说话人识别（嘈杂环境靠"近讲比远讲响一个数量级"这条物理事实，不靠模型）
- 不打包成 .dmg（`build.sh` 会自签名，授权跨构建存活）
