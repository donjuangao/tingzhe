#!/bin/bash
# UserPromptSubmit 钩子 · 登记「有哪些 session 存在、哪个刚被说话」
#
# ⛔ 它只**登记**,不决定谁出声 —— 谁出声由 作者 在菜单栏点选(voice-partner)。
# 2026-07-28 作者:「我需要一个前端交互，能够决定我跟哪个 session 进行语音对话，
#                并且能关掉那些我不想继续语音对话的 session」
# ⇒ 「最后说话的那个」是**猜**,作者 要的是**他自己指定**。所以这里只记名单。
set -uo pipefail
STATE="${TINGZHE_VOICE_STATE:-$HOME/Library/Caches/tingzhe}"
mkdir -p "$STATE/sessions"
IN=$(cat)
python3 - "$STATE" <<'PY' <<<"$IN" 2>/dev/null || true
PY
python3 -c '
import json,sys,os,time
state=sys.argv[1]
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
sid=d.get("session_id") or ""
if not sid: sys.exit(0)
cwd=d.get("cwd") or ""
label=os.path.basename(cwd.rstrip("/")) or sid[:8]
os.makedirs(os.path.join(state,"sessions"),exist_ok=True)
with open(os.path.join(state,"sessions",sid),"w") as f:
    json.dump({"id":sid,"label":label,"cwd":cwd,"seen":time.time()},f)
# ⛔ 同时记下「你此刻在跟哪个说话」—— 没显式选 session 时,钩子拿它当默认。
# 上一版只登记名单不记这个,配上"必须先选"的判据 = 永远不出声。
with open(os.path.join(state,"active-session"),"w") as f:
    f.write(sid)
# 名单里只留最近 8 个,别让菜单无限长
ds=os.path.join(state,"sessions")
fs=sorted(os.listdir(ds),key=lambda n: os.path.getmtime(os.path.join(ds,n)),reverse=True)
for n in fs[8:]:
    try: os.remove(os.path.join(ds,n))
    except OSError: pass
' "$STATE" <<<"$IN"
# ⛔ 确保「边写边念」的监听器在跑 —— 它盯 transcript,每落一段就念一段。
# 为什么放这里:这个钩子在**你发消息时**触发,那正是"接下来会有输出"的时刻,
# 而且此刻才知道是哪个 session。
STATE="${TINGZHE_VOICE_STATE:-$HOME/Library/Caches/tingzhe}"
if [ -f "$STATE/voice-on" ]; then
  pgrep -f "speak-watch.py" >/dev/null 2>&1 || \
    ( "${TINGZHE_DIR:-$HOME/Downloads/tingzhe}/speak-watch.py" >/dev/null 2>&1 & )
fi

# ⭐ 语音快车道(作者 2026-07-30 拍 D1乙 · 面板 1613d176)
# 实测:作者 说完话到听见回话**中位 269s**,其中 **87% 是工具链**(n=178 真实轮次);
# 而 0 工具的轮次只要 25.6s —— 把重活挪走 = 269s → 约 25s。
#
# ⛔ 判据**两条都要命中**,这是 作者 备注亲问的作用域:
#   ①语音模式开着(voice-on 存在) ②partner 就是**本条** session(voice-partner == session_id)
#   ⇒ 治理线/MICA 线哪怕麦克风开着也**零影响** —— 它们的 session_id 不等于 partner。
#
# 为什么扩这只而不是新装一只:它已经拿到 session_id、已经在读 voice-on、
# 触发时机也正是"接下来会有输出"那一刻。再装一只 = 同一件事两处实现(律三)。
if [ -f "$STATE/voice-on" ] && [ -f "$STATE/voice-partner" ]; then
  SID=$(printf '%s' "$IN" | python3 -c \
        'import json,sys;print(json.load(sys.stdin).get("session_id") or "")' 2>/dev/null || true)
  PARTNER=$(tr -d '[:space:]' < "$STATE/voice-partner" 2>/dev/null || true)
  if [ -n "$SID" ] && [ "$SID" = "$PARTNER" ]; then
    cat <<'FASTLANE'
⚡ 语音快车道已生效（作者 拍 D1乙 · 只对本条 session,别的线不受影响）

作者 此刻在用**语音**跟你说话 —— 他多等的每一秒都是干等着听。
实测中位 269s,其中 87% 花在工具链上;而不开工具的轮次只要 25.6s。

⇒ **先把话说回去,重活派后台**:
· 只读调查 / 大输出 / 能并行的活 → `Agent(run_in_background: true)` 派出去,别在主线里串着跑
· 主线只留:回他的话 + 必须你亲自判断的那一两步
· **派完立刻先答一句**,不要等工兵回来才开口

⛔ 边界不变:改代码 / 改配置 / 碰 prod 仍然你自己来(今天那个 30s 的 bug 正是你盯日志看出来的形状,
派出去多半只会回来一句"未发现异常");派工模型永不 Fable。
FASTLANE
  fi
fi
exit 0
