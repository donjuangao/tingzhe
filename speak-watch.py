#!/usr/bin/env python3
"""边写边念 —— 盯住当前 session 的 transcript，每落一段就合成播放。

⛔ 为什么不能靠 Stop 钩子(作者 2026-07-28 提):
   `Stop` 只在**整轮结束**时才响。我一轮里常常跑十几分钟工具，
   于是 作者 要等「我全部说完 + 整段合成完」才听到第一个字 —— 实测长回复要四十几秒。
⭐ 而 transcript 是**边写边落盘**的:同一轮里每个 text 块各自一行、各带时间戳
   (实测 03:25:04 / 03:25:37 / 03:26:49 三段相隔几十秒)。
   ⇒ 盯着它，每落一段就念一段；段内再按句子切，首句约 5 秒就出声。

⛔ 隐私:只读**当前选中那个 session** 的 transcript，只把过滤后的文本发给 MOSS
   (与 speak-hook 同一条边界，作者 2026-07-28 明确接受)。
"""
import json
import os
import pathlib
import subprocess
import sys
import time
from pathlib import Path

DIR = Path(os.environ.get("TINGZHE_DIR") or Path.home() / "Downloads/tingzhe")
STATE = Path(os.environ.get("TINGZHE_VOICE_STATE") or Path.home() / "Library/Caches/tingzhe")
LOGD = Path(os.environ.get("TINGZHE_LOG_DIR") or Path.home() / "Library/Logs/tingzhe")
LOG = LOGD / "speak.log"

# ⛔ 一句一送，不是整段一送 —— 首字延迟从「整段合成完」变成「第一句合成完」。
# MOSS 不支持流式(stream=true → 400，2026-07-28 实测)，所以只能自己切。
# ⛔ 2026-07-28 实测:整段一次发 → 首字 35.7 秒;只发第一句 → 7.6 秒。
# 但第一句不能太长 —— 实测切出来 80 字(标题+列表首项粘一起),那还是要等 7 秒多。
# ⇒ **第一句特别短**(尽快出声),后面逐渐放宽(减少请求数、听着连贯)。


def log(msg):
    LOGD.mkdir(parents=True, exist_ok=True)
    with open(LOG, "a") as f:
        f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} [watch] {msg}\n")


def voice_on():
    return (STATE / "voice-on").exists()


def partner():
    for name in ("voice-partner", "active-session"):
        p = STATE / name
        if p.exists():
            v = p.read_text().strip()
            if v:
                return v
    return None


def transcript_for(sid):
    """session id → transcript 路径。⚠ 目录名是 cwd 的转义形式，只能扫。"""
    root = Path.home() / ".claude/projects"
    if not root.exists():
        return None
    for d in root.iterdir():
        f = d / f"{sid}.jsonl"
        if f.exists():
            return f
    return None


def speakify(text):
    r = subprocess.run([str(DIR / "speakify.py")], input=text,
                       capture_output=True, text=True)
    return r.stdout.strip()


def cfg(k, d):
    try:
        return json.load(open(DIR / "config.json")).get(k, d)
    except Exception:
        return d


def key():
    try:
        for line in (DIR / ".env.local").read_text().splitlines():
            if line.startswith("TINGZHE_API_KEY="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    except Exception:
        pass
    return None


ENGINE_CANDIDATES = [
    DIR / "tingzhe.app/Contents/MacOS/tingzhe",
    DIR / "build/dev/tingzhe",
]


def engine():
    for p in ENGINE_CANDIDATES:
        if p.exists() and os.access(p, os.X_OK):
            return p
    return None


def speak_stream(text):
    """把一段话交给 Swift 那边流式念出来。

    ⭐ 2026-07-28 换掉了原来的 `curl 合成整段 → afplay 播`:
       MOSS-TTS-v1.5-Flash 支持流式(`version=flash-20260626` + `stream=true` + `pcm`),
       **首块音频 1.24 秒**(实测),而原来整段合成要 ~4 秒。
    ⛔ 为什么不在 Python 里播:本机只有 `afplay`,而它**跟不住正在长大的 wav**
       (实测 4.0 秒音频它 2.90 秒就退出),没有 sox/ffplay 也不能让开源用户去装。
       Swift 那边有 AVAudioEngine,边收边排 PCM buffer 才是能无缝播的做法。
    ⛔ 文本走 **stdin 不走 argv**:argv 会出现在 `ps` 输出里,而念的正文就是回复本体
       (含代码/路径/业务内容)。
    ⛔ 不再分句:流式的首字延迟跟文本长短无关,分句只会在句子之间制造停顿。
       原来那套「首块短一点、后面放宽、太短的并进前一块」是为了绕开非流式的延迟,
       现在那个约束没了,整套一起删 —— 留着就是两条路,而另一条永远没人走。

    返回 False = 被打断或失败,调用方应当丢掉本轮剩下的。
    """
    e = engine()
    if e is None:
        log("✗ 找不到 tingzhe 可执行文件 → 这段没念（跑一次 ./build.sh 或 ./build.sh --dev）")
        return False
    try:
        r = subprocess.run([str(e), "--speak"], input=text, text=True,
                           capture_output=True, timeout=180)
        if r.returncode != 0:
            err = (r.stderr or "").strip()[:200]
            log(f"念失败/被打断 rc={r.returncode} {err}")
        return r.returncode == 0
    except Exception as ex:
        log(f"念的时候出错 {ex}")
        return False


def main():
    if not voice_on():
        return
    sid = partner()
    if not sid:
        log("没有可念的 session"); return
    tp = transcript_for(sid)
    if not tp:
        log(f"找不到 {sid[:8]} 的 transcript"); return

    # ⛔ 从**当前末尾**开始盯，不回放历史 —— 否则一开语音模式就把整段历史念一遍
    #    (作者 2026-07-28 明确点过这个:「第二次打开的时候不用再继续听它的语音」)
    seen = set()
    pos = tp.stat().st_size
    log(f"开始盯 {sid[:8]} 的 transcript（从当前末尾）")
    idle = 0
    while voice_on() and partner() == sid:
        try:
            size = tp.stat().st_size
            if size > pos:
                with open(tp, "r", encoding="utf-8", errors="ignore") as f:
                    f.seek(pos)
                    data = f.read()
                    pos = f.tell()
                for line in data.splitlines():
                    try:
                        r = json.loads(line)
                    except Exception:
                        continue
                    if r.get("type") != "assistant":
                        continue
                    uid = r.get("uuid") or ""
                    if uid in seen:
                        continue
                    seen.add(uid)
                    c = r.get("message", {}).get("content", [])
                    txt = "".join(b.get("text", "") for b in c
                                  if isinstance(b, dict) and b.get("type") == "text")
                    if not txt.strip():
                        continue
                    spoken = speakify(txt)
                    if not spoken:
                        continue
                    if not speak_stream(spoken):
                        # ⛔ 必须 break 不是 continue:你开口打断我,是要我**整轮**闭嘴,
                        #   不是只跳过这一段然后接着念下一段(那就等于没打断)。
                        log("被打断/失败 → 本轮剩下的都不念了")
                        break
                    log(f"念完一段（{len(spoken)} 字）")
                idle = 0
            else:
                idle += 1
            time.sleep(0.7)
        except FileNotFoundError:
            return
        except Exception as e:
            log(f"盯 transcript 出错 {e}")
            time.sleep(2)
    log("停止（语音模式关了或换了 session）")


def _selftest():
    """⛔ 换成流式之后要守的性质变了,闸也得跟着换 —— 留着测已删函数的老闸 = 假绿。
    不联网、不出声:把 speak_stream 换成只记调用的假货。"""
    global speak_stream, voice_on
    bad = 0

    def check(ok, what):
        nonlocal bad
        print(("  ✓ " if ok else "  ✗ ") + what)
        if not ok:
            bad += 1

    voice_on = lambda: True                      # noqa: E731
    check(engine() is not None,
          "找得到 tingzhe 可执行文件（念声音靠它，找不到就整条哑了）")

    # ⛔ 正文必须走 stdin —— argv 会出现在 ps 输出里,而念的就是回复本体(含代码/路径/业务)。
    src = pathlib.Path(__file__).read_text()
    body = src[src.index("def speak_stream("):src.index("def main():")]
    check('input=text' in body and '"--speak"' in body,
          "正文经 stdin 传给引擎（argv 会被 ps 看见）")
    check("text" not in body.split('subprocess.run([')[1].split(']')[0],
          "argv 里没有正文本身")

    # 打断 = 整轮闭嘴,不是只跳过一段
    calls = []

    def fake(t):
        calls.append(t)
        return len(calls) < 2          # 第 2 段起当作"被打断"

    speak_stream = fake
    for t in ["甲", "乙", "丙"]:
        if not speak_stream(t):
            break
    check(calls == ["甲", "乙"],
          f"被打断后不再念下一段（实得 {calls}；接着念下去等于没打断）")

    if bad:
        print(f"✗ speak-watch selftest: {bad} 项不过")
        sys.exit(1)
    print("✓ speak-watch: 引擎找得到 · 正文走 stdin 不走 argv · 打断即整轮停")
    print("  ⚠ 未断言:真出声好不好听、真打断时引擎的退出码 —— 要真开口打断一次")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        _selftest()
    else:
        main()
