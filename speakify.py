#!/usr/bin/env python3
"""把「写给眼睛看的回复」变成「能念给耳朵听的话」。

⛔ 存在的理由(作者 2026-07-28 拍 Q1乙):我的回复是给眼睛的 ——
代码块、`src/main.swift:378` 这种路径、表格、**加粗**、中英混排标识符。
逐字念出来是「星号星号 check 点 sh 冒号 四九八 星号星号」,不可用。

⛔ 为什么不用「我每轮额外写口播版」(方案甲):那依赖我记得写,
而本项目已反复证明「靠自觉」的东西必然失效 —— 同一天我自己就又犯了两次 pipefail。
过滤器不依赖任何人的自觉,坏了还能被闸抓。

用法:  cat reply.md | ./speakify.py
       ./speakify.py --selftest      # 判据自检(check.sh 用)
"""
import re
import sys

# ── 整块丢弃:念出来纯噪音,而且都是"眼睛才用得上"的东西 ──────────────
DROP_BLOCKS = [
    (re.compile(r"```.*?```", re.S), ""),          # 代码块
    (re.compile(r"^\s*\|.*\|\s*$", re.M), ""),      # 表格行
    (re.compile(r"^\s*[-*+]\s*[-—–]{3,}\s*$", re.M), ""),  # 分隔线
    (re.compile(r"^\s*<[^>]+>\s*$", re.M), ""),     # 独占一行的 HTML/标签
]

# ── 路径与代码标识符:说"某个文件"比逐字念路径有用得多 ─────────────────
PATHY = re.compile(r"`?(?:[\w.\-/]+/)+[\w.\-]+(?::\d+)?`?")   # a/b/c.swift:378
FILEY = re.compile(r"`([\w\-]+\.(?:swift|py|sh|json|md|txt|html|jsonl))(?::\d+)?`")
CMDY = re.compile(r"`[^`\n]{25,}`")                            # 长反引号 = 命令,别念

# ── 行内标记:符号本身不该出声 ─────────────────────────────────────
INLINE = [
    (re.compile(r"\*\*(.+?)\*\*"), r"\1"),
    (re.compile(r"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"), r"\1"),
    (re.compile(r"~~(.+?)~~"), r"\1"),
    (re.compile(r"\[([^\]]+)\]\([^)]+\)"), r"\1"),   # 链接只留文字
    (re.compile(r"^#{1,6}\s*", re.M), ""),
    (re.compile(r"^\s*[-*+]\s+", re.M), ""),
    (re.compile(r"^\s*>\s*", re.M), ""),
    (re.compile(r"`([^`\n]{1,24})`"), r"\1"),        # 短反引号:留字,去符号
]

# ── 符号 → 读法。⛔ 只处理**会出声**的,别把标点也念了 ───────────────
SYMBOL = [
    (re.compile(r"[⛔🔴❌]"), "注意，"),
    (re.compile(r"[⚠️⚠]"), "提醒，"),
    (re.compile(r"[✅✓🟢]"), "已通过，"),
    (re.compile(r"[⭐★]"), "重点，"),
    (re.compile(r"[🟡]"), "黄灯，"),
    (re.compile(r"[·•]"), "，"),
    (re.compile(r"[→⇒]"), "，就是，"),
    (re.compile(r"[#*_`~|<>\[\]{}\\]"), ""),         # 剩下的裸符号一律不出声
    (re.compile(r"[ \t]{2,}"), " "),
    (re.compile(r"\n{3,}"), "\n\n"),
]

# ⛔ 2026-07-28 作者 抓:「你话说到一半，然后就变成了还有三百八十六个字」。
# 两个毛病:① 400 太小,我的回复经常上千字 ② 找不到句号时**直接在半句话上砍**。
# ⭐ 而真正的修法不在这个数字上 —— **是我在语音模式下该写短**。
#   一个要靠截断来救的回复,本来就不该那么长。这个上限是安全网,不是解法。
import os as _os
def _cap():
    try:
        import json as _j
        d = _os.environ.get("TINGZHE_DIR") or _os.path.expanduser("~/Downloads/tingzhe")
        v = _j.load(open(_os.path.join(d, "config.json"))).get("speak_max_chars")
        if isinstance(v, (int, float)) and v > 50: return int(v)
    except Exception: pass
    return 1000
MAX_CHARS = _cap()

# ══ 断句层(作者 2026-07-28:「主要是你那个断句断的很扯淡」)════════════════
# ⛔ 作者 试过 Claude 自带的 read out loud,判词是「不是音色问题,是断句本身有问题」。
# 诊断:断句**不全是引擎的锅** —— 中文没空格,引擎得自己切词;我再喂它中英混排、
# 破折号、括号套括号的长句,它必然切烂。**有一半是我喂进去的文本的锅,而那一半我能控。**
# 实测 `say` 认内嵌停顿指令 `[[slnc N]]`:加 700ms 音频正好长 0.7s ⇒ **停在哪由我定,不交给引擎。**
SENT_END = "。！？!?；;"
PAUSE_SENT = 320      # 句末停顿(ms)
PAUSE_CLAUSE = 160    # 从句停顿
PAUSE_PARA = 520      # 段落停顿
LONG_RUN = 26         # 连续这么多字没标点 = 一口气念不完,插软停顿

# 中英夹缝:`装了pipefail的guard` 这种引擎会把中英粘成一坨切错。
# 两侧各给一点点空气,分词就不会跨语种粘连。
CJK = r"一-鿿"
MIX_A = re.compile(rf"([{CJK}])([A-Za-z][A-Za-z0-9_.\-]*)")
MIX_B = re.compile(rf"([A-Za-z0-9_.\-])([{CJK}])")


def _break_long(seg: str) -> str:
    """在**已有标点**处加停顿。⛔ 绝不在没有标点的地方硬插。

    ⚠ 第一版这里是「数满 26 字就硬插一个逗号」—— 实测把「苹果」劈成了「苹，果」,
    也就是**我为了修断句,自己造了一遍断句错误**,正是 作者 抱怨的那个病。
    而当时的自检只查「有没有停顿」不查「有没有把词劈开」,照样打绿。
    ⭐ 定论:**停错地方比不停难听得多**。宁可一句长,也只在真标点处喘气。
    ⇒ 本函数只**插入 [[slnc]] 标记**,一个字符都不改 —— 这条由自检机械验(剥掉标记必须还原原文)。
    """
    out, run = [], 0
    for ch in seg:
        out.append(ch)
        if ch in "，,、：:":
            if run >= LONG_RUN // 3:      # 太碎的短语不必再停
                out.append(f"[[slnc {PAUSE_CLAUSE}]]")
            run = 0
        elif ch in SENT_END:
            run = 0
        else:
            run += 1
    return "".join(out)


def prosody(text: str) -> str:
    """把一段话切成"能一口一口念"的形状,并把停顿写死。"""
    text = MIX_A.sub(r"\1 \2", text)
    text = MIX_B.sub(r"\1 \2", text)
    paras = [p.strip() for p in re.split(r"\n\s*\n", text) if p.strip()]
    out_paras = []
    for p in paras:
        p = re.sub(r"\s*\n\s*", " ", p)
        # 按句末标点切,标点留在前一句里
        sents = re.findall(rf"[^{SENT_END}]*[{SENT_END}]|[^{SENT_END}]+$", p)
        sents = [s.strip() for s in sents if s.strip()]
        out_paras.append(f"[[slnc {PAUSE_SENT}]]".join(_break_long(s) for s in sents))
    return f"[[slnc {PAUSE_PARA}]]".join(out_paras)


def speakify(text: str) -> str:
    for pat, rep in DROP_BLOCKS:
        text = pat.sub(rep, text)
    text = FILEY.sub(lambda m: m.group(1).split(".")[0] + "那个文件", text)
    text = CMDY.sub("（一条命令）", text)
    text = PATHY.sub("（某个文件）", text)
    for pat, rep in INLINE:
        text = pat.sub(rep, text)
    for pat, rep in SYMBOL:
        text = pat.sub(rep, text)
    text = re.sub(r"[ \t]*\n[ \t]*", "\n", text).strip()
    # ⛔ 2026-07-28:原来把所有换行压成空格 —— 于是标题和下一段粘成一句,
    # 切分时切不开,首块 95 字、首字延迟下不来。
    # ⇒ 换行处补一个句号(如果本来就没有终止标点),让它成为可切的边界。
    text = re.sub(r"([^。！？!?，,、；;：:])\n", r"\1。\n", text)
    text = re.sub(r"\n+", " ", text)
    text = re.sub(r"，{2,}", "，", text)
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) > MAX_CHARS:
        cut = text[:MAX_CHARS]
        # ⛔ 绝不在半句话上砍 —— 句末标点找不到就退到逗号,再找不到**就整段不截**。
        # 判据:念完整比念够短重要。截在半句话上的那一下,比多念两句难受得多。
        m = max(cut.rfind("。"), cut.rfind("！"), cut.rfind("？"), cut.rfind("."))
        if m < MAX_CHARS // 3:
            m = max(cut.rfind("，"), cut.rfind("、"), cut.rfind(","))
        if m < MAX_CHARS // 3:
            return text        # 找不到干净的断点 → 宁可全念,也不半句话切断
        cut = cut[: m + 1]
        text = cut + f" 后面还有{len(text) - len(cut)}个字，在屏幕上。"
    return text


# ⛔ 判据自检:每一条都来自「真的会念错」的形态,不是我想象的
CASES = [
    ("**已通过**：`check.sh` 第 9 项", ["星号", "反引号", "`", "*"], ["已通过"]),
    ("改的是 `src/main.swift:378` 那一行", ["main.swift", "378", "/"], ["文件"]),
    ("```bash\nrm -rf /\n```\n说完了", ["rm", "bash"], ["说完了"]),
    ("| 列一 | 列二 |\n|---|---|\n正文在这", ["列一", "|"], ["正文在这"]),
    ("跑 `TINGZHE_REAL_BUILD=1 ./build.sh && ./install-agent.sh install` 就行",
     ["TINGZHE_REAL_BUILD", "&&"], ["一条命令"]),
    ("⛔ 别这么写 → 会炸", ["⛔", "→"], ["注意", "就是"]),
    ("[面板](https://example.com/x)", ["https", "example"], ["面板"]),
]


def selftest() -> int:
    bad = 0
    for src, banned, needed in CASES:
        out = speakify(src)
        for b in banned:
            if b in out:
                print(f"  ✗ 念得出「{b}」不该出现 ← {src!r} → {out!r}")
                bad += 1
        for n in needed:
            if n not in out:
                print(f"  ✗ 少了「{n}」 ← {src!r} → {out!r}")
                bad += 1
    # ⚠ 判据自己先要对:必须构造**真的超过上限**的输入,否则测的是"没截断"这件事
    long_in = "。".join(["这是一句很长的话"] * (MAX_CHARS // 8 + 40))
    assert len(long_in) > MAX_CHARS, "自检输入没超过上限,这条测了个寂寞"
    out = speakify(long_in)
    if len(out) > MAX_CHARS + 40:
        print(f"  ✗ 超长没截断（{len(out)} 字）"); bad += 1
    if "在屏幕上" not in out:
        print("  ✗ 截断了却没告诉人还有多少"); bad += 1
    # ⛔ 作者 2026-07-28 亲耳抓出的那条:「你话说到一半，然后就变成了还有三百八十六个字」
    head = out.split(" 后面还有")[0]
    if head and head[-1] not in "。！？.，、,":
        print(f"  ✗ 在半句话上截断了(结尾是 {head[-1]!r})"); bad += 1
    # ⛔ 反向:找不到干净断点时**宁可全念**,不许硬切
    nopunct = "啊" * (MAX_CHARS * 2)
    o2 = speakify(nopunct)
    if "后面还有" in o2:
        print("  ✗ 没有标点可断时仍然硬切了（应当整段全念）"); bad += 1
    # ── 断句层判据(作者 2026-07-28:「断句断的很扯淡」) ──────────────────
    # ⛔ 每一条都对应一种**实际会念错**的情形,不是我想象的
    p = prosody("第一句话。第二句话。")
    if "[[slnc" not in p:
        print("  ✗ 句子之间没有插停顿 —— 引擎会把两句连着念"); bad += 1
    p2 = prosody("装了 pipefail 的 guard")
    if "了pipefail" in p2 or "pipefail的" in p2:
        print(f"  ✗ 中英粘连没拆开(引擎会把中英切成一坨) → {p2!r}"); bad += 1
    # ⛔⛔ 最要紧的一条:断句层**绝不能把词劈开** —— 第一版就是这么把「苹果」念成「苹,果」的,
    # 而当时的自检只查「有没有停顿」照样打绿。判据 = 剥掉停顿标记必须**逐字还原**原文。
    for src in ["好的那两档 Enhanced 苹果有，只是没下载。",
                "这是一句很长的话里面一个标点都没有所以引擎根本不知道该在哪里换气结果就会一路念到底",
                "第一句。第二句，第三个分句。"]:
        stripped = re.sub(r"\[\[slnc \d+\]\]", "", prosody(src))
        if re.sub(r"\s+", "", stripped) != re.sub(r"\s+", "", MIX_A.sub(r"\1 \2", MIX_B.sub(r"\1 \2", src))):
            print(f"  ✗ 断句层改动了正文(会把词劈开) ← {src!r}\n     → {stripped!r}"); bad += 1
    p4 = prosody("第一段。\n\n第二段。")
    if f"slnc {PAUSE_PARA}" not in p4:
        print("  ✗ 段落之间没给更长的停顿"); bad += 1
    # ⛔ 反向,而且这条是 作者 亲耳听出来的:默认输出里**绝不许**有 [[slnc]] ——
    # 它只对 macOS say 有意义,发给别的引擎就会被逐字念出来。
    import subprocess as _sp
    default_out = _sp.run([sys.executable, __file__], input="第一句。第二句。",
                          capture_output=True, text=True).stdout
    if "[[" in default_out:
        print(f"  ✗ 默认输出里有停顿指令(会被 MOSS 念出来): {default_out!r}"); bad += 1
    say_out = _sp.run([sys.executable, __file__, "--say"], input="第一句。第二句。",
                      capture_output=True, text=True).stdout
    if "[[slnc" not in say_out:
        print("  ✗ --say 版本反而没有停顿指令"); bad += 1

    if bad:
        print(f"✗ speakify: {bad} 项不过"); return 1
    print(f"✓ speakify: {len(CASES)} 条形态 + 4 条断句判据全过 · 超长截断并告知")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    out = speakify(sys.stdin.read())
    # ⛔⛔ 2026-07-28 作者 抓「每句话前面多一串数字和字母」——就是 `[[slnc 320]]`。
    # 那是 **macOS `say` 的专用指令**,MOSS 不认识 → **照着念出来了**。
    # 病根:断句层当初是为了修本机拼接式引擎的烂断句;换成 MOSS 神经 TTS 之后
    # 它既不需要、又有害,而我忘了摘。
    # ⇒ **默认出干净文本**(神经引擎自己看标点断句);停顿指令只在 `--say` 时才加。
    sys.stdout.write(prosody(out) if "--say" in sys.argv else out)
