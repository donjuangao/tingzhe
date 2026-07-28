#!/bin/bash
# Stop 钩子 · 把我这一轮的回复念出来（作者 2026-07-28 拍 Q1乙/Q2改判MOSS/Q4甲）
#
# 链路：Claude 说完 → 本钩子拿 last_assistant_message → speakify.py 过滤+断句
#       → MOSS moss-tts 合成 → afplay 播放
#
# ⛔ 隐私：这一步把**我的回复正文**发给 MOSS（含项目代码/路径/业务内容）。
#    作者 2026-07-28 明确接受，理由=同一供应商同一账号。见 README 的隐私说明。
#    ⛔ 换任何别的 TTS 供应商都要重新拍。
#
# ⛔ 钩子不许拖住对话：整段跑在后台，超时硬杀。钩子自己永远立刻返回 0。
set -uo pipefail

DIR="${MOSS_CONNECT_DIR:-$HOME/Downloads/moss-connect}"
STATE="${MOSS_VOICE_STATE:-$HOME/Library/Caches/moss-ptt}"
LOG="${MOSS_LOG_DIR:-$HOME/Library/Logs/moss-ptt}/speak.log"
mkdir -p "$STATE" "$(dirname "$LOG")"

IN=$(cat)

# ⛔ 语音模式是**能开能关的模式**，不是全天候（§6c-3）。没开就什么都不做。
# 开：touch ~/Library/Caches/moss-ptt/voice-on   关：rm 它
[ -f "$STATE/voice-on" ] || exit 0

# ── 取回复正文。⚠ last_assistant_message 是官方文档字段，但本机此前无人用过 ──
#    所以**留了退路**：拿不到就从 transcript 里读最后一条 assistant 文本。
read -r -d '' EXTRACT <<'PY' || true
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
t = (d.get("last_assistant_message") or "").strip()
if not t:
    # 退路：读 transcript 末条 assistant 的 text block
    p = d.get("transcript_path")
    if p:
        try:
            last = ""
            for line in open(p, encoding="utf-8"):
                try:
                    r = json.loads(line)
                except Exception:
                    continue
                if r.get("type") != "assistant":
                    continue
                c = r.get("message", {}).get("content", [])
                s = "".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text")
                if s.strip():
                    last = s
            t = last.strip()
        except Exception:
            pass
print(t)
PY
# ⛔ 别写成 `python3 - <<'PY' <<<"$IN"` —— 两个重定向抢同一个 stdin，**后一个赢**，
# 于是 Python 把 JSON 当脚本执行；而 `{"a":"b"}` 恰好是**合法的 Python 字典字面量**，
# 它求值、丢弃、退出 0：**不报错、不输出、只测退出码会打绿**。2026-07-28 我当场踩到。
TXT=$(printf '%s' "$IN" | python3 -c "$EXTRACT")

[ -z "$TXT" ] && { echo "$(date -u +%FT%TZ) 取不到回复正文（last_assistant_message 与 transcript 都空）" >>"$LOG"; exit 0; }

# ⛔⛔ 2026-07-28 作者 抓「在两个 session 之间来回走时，你们俩的语音同时放给我听，
#    而且声音还不一样」。根因两条：
#    ① Stop 钩子挂在 ~/.claude/settings.json = **所有 session 共用**，于是每个 session 说完都念；
#    ② 两个 session 同时发 TTS 请求，一个成功、一个超时回落本机 say → **两种声音同时说话**。
#    (speak.log 逐字为证：「✓ 念了 1068 字」紧挨着「✗ MOSS 合成失败(HTTP 000) → 回落本机 say」)
# ⇒ 只有**你最后一次说话的那个 session**该出声。谁是那个？
#    `active-session` 由 UserPromptSubmit 钩子写 —— 你往哪个 session 发消息，哪个就是活的。
# ⛔ 只有 **作者 在菜单栏点选的那个 session** 才出声。
# 上一版用「最后跟他说话的那个」自动判定 —— 那是猜;作者 明说要**自己指定**:
# 「我需要一个前端交互，能够决定我跟哪个 session 进行语音对话，并且能关掉我不想要的，
#   并且在第二次打开的时候不用再继续听它的语音」
# ⇒ 没被选中 = 立刻退出,什么都不合成、什么都不排队 ⇒「第二次打开不用再听」自然成立。
PARTNER_F="$STATE/voice-partner"
MY_SID=$(printf '%s' "$IN" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("session_id") or "")
except Exception: print("")' 2>/dev/null)
PARTNER=$(cat "$PARTNER_F" 2>/dev/null | tr -d '[:space:]')
# ⛔⛔ 2026-07-28 踩过的坑:上一版「没选 session 就不出声」——而选 session 的唯一入口是菜单栏,
# 菜单栏在这个进程里**画不出来**(已查实)。**我造了一个永远无法满足的前置条件,把自己锁死了**,
# 作者 因此从头到尾没听到一次声音。
# ⇒ 没显式选的时候,**退回到"你最后说话的那个 session"** —— 那是个合理默认,不是猜不到的东西。
#   显式选中只作为**覆盖**。判据:能用 > 精确。
if [ -z "$PARTNER" ]; then
  PARTNER=$(cat "$STATE/active-session" 2>/dev/null | tr -d '[:space:]')
fi
if [ -z "$PARTNER" ]; then
  echo "$(date -u +%FT%TZ) 念（还不知道有哪些 session，先出声）" >>"$LOG"
  PARTNER="$MY_SID"
fi
if [ -n "$MY_SID" ] && [ "$PARTNER" != "$MY_SID" ]; then
  echo "$(date -u +%FT%TZ) 跳过：你选的不是这个 session" >>"$LOG"; exit 0
fi

# ⛔ 2026-07-28:这里原来有一把「同一时刻只许一个念」的目录锁 —— **已拆掉**。
# 它花了我四轮还没修对(trap 跨进程托付 → 锁泄漏 → 此后每一轮都被挡掉,
# 作者 因此从头到尾没听到回话;修完又出现"锁释放了但什么都不产出"的静默退出)。
# ⭐ 换方法而不是再修一条:**这把锁本来就不承重** ——
#   ① 跨 session 的重叠已经由上面的 partner 判定挡住(只有你选中的那个会出声)
#   ② 同一 session 内的重叠由播放前的 `pkill -x afplay` 挡住(新的一轮来了旧的就停)
# 一个不承重、却能让整个功能静默失效的机制,不值得留着。

# ⛔ 2026-07-28:有了「边写边念」的监听器(speak-watch.py)之后,这个钩子只当**兜底** ——
# 监听器在跑就别念,否则同一段会被念两遍。
# ⚠ 判据是"监听器进程在不在",不是"我以为它在" —— 它可能没起来/崩了,那时钩子必须顶上。
if pgrep -f "speak-watch.py" >/dev/null 2>&1; then
  echo "$(date -u +%FT%TZ) 跳过：边写边念的监听器在跑，不重复" >>"$LOG"
  exit 0
fi

# ── 后台跑：合成 + 播放。钩子本身立刻返回，绝不拖住对话 ──
(
  SPOKEN=$(printf '%s' "$TXT" | "$DIR/speakify.py" 2>/dev/null)
  [ -z "$SPOKEN" ] && exit 0

  # 地址/模型走 config —— 别人换成自己的 OpenAI 兼容服务即可
  API_BASE=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("api_base","https://api.mosi.cn/v1"))' "$DIR/config.json" 2>/dev/null || echo "https://api.mosi.cn/v1")
  TTS_MODEL=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("tts_model","moss-tts"))' "$DIR/config.json" 2>/dev/null || echo moss-tts)
  KEY=$(grep '^MOSS_API_KEY=' "$DIR/.env.local" 2>/dev/null | cut -d= -f2- | tr -d '"'"'"'')
  OUT="$STATE/reply-${MY_SID:-x}.mp3"   # ⛔ 每 session 一个：共用一个会互相覆盖、杀不干净

  if [ -n "$KEY" ]; then
    # ⚠ MOSS 不支持流式（stream=true → 400，2026-07-28 实测），只能等整段
    BODY=$(TTS_MODEL="$TTS_MODEL" python3 -c 'import json,sys,os;print(json.dumps({"model":os.environ.get("TTS_MODEL","moss-tts"),"input":sys.stdin.read(),"response_format":"mp3"}))' <<<"$SPOKEN")
    CODE=$(curl -s -o "$OUT" -w "%{http_code}" -X POST "$API_BASE/audio/speech" \
           -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
           -d "$BODY" --max-time 45)
  else
    CODE="nokey"
  fi

  if [ "$CODE" = "200" ] && [ -s "$OUT" ]; then
    # ⛔ 先杀掉上一段还在播的 —— 我说了新的一轮，旧的就该停
    pkill -x afplay 2>/dev/null      # 新的一轮来了，旧的一律停
    afplay "$OUT" &
    echo "$(date -u +%FT%TZ) ✓ 念了 ${#SPOKEN} 字" >>"$LOG"
  else
    # ⛔ fail-open：云端挂了绝不能让对话卡住，退回本机声音（难听但有总比没有强）
    echo "$(date -u +%FT%TZ) ✗ MOSS 合成失败(HTTP $CODE) → 回落本机 say" >>"$LOG"
    pkill -x say 2>/dev/null
    # ⛔ 只有本机 say 认 [[slnc]],所以回落这条路单独再过一遍断句层
    say -v Tingting "$(printf '%s' "$TXT" | "$DIR/speakify.py" --say 2>/dev/null)" &
  fi
) >/dev/null 2>&1 &

exit 0
