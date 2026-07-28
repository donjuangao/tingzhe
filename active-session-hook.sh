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
exit 0
