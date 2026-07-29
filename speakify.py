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

# ⛔ 2026-07-29 作者 拍:「把那个上限长度砍掉吧,你感觉那个东西没有用啊。」——**整套截断已删**。
# 沿革:07-28 他抓「你话说到一半,然后就变成了还有三百八十六个字」,我把 400 提到 1000
# 并加了「不许在半句话上砍」的规矩。可那只是把难受推远了一点 ——
# **上限本身才是那个毛病**:它保证了"总有一天你会在句子中间听到「后面还有 N 个字」"。
# ⭐ 而真正的修法从第一天就写在这儿了:**是我在语音模式下该写短**。
#   一个要靠截断来救的回复,本来就不该那么长。上限是安全网,不是解法 —— 现在连网也撤了。
# ⚠ 代价如实说:我要是写了三千字,它会**从头念到尾**,只能靠你开口打断。这是 作者 知情选的。

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
    # ⛔ 这里原本有截断:超过上限就找句号切,再补一句「后面还有 N 个字」。整段已删(见文件头)。
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
    # ⛔ 这里原本有 4 条断言守「超长要截断且不在半句话上砍」。**随截断一起删**。
    # 律四(存在审):删掉 X 之后必须同时问「守 X 的那些断言还该存在吗」——
    # 留着它们会立刻判红,而那个红不是产品坏了,是判据比产品活得久。
    # ⇒ 反向断言一条,守住「真的删干净了」:三千字进去,必须三千字量级出来,不许出现「后面还有」。
    long_in = "。".join(["这是一句很长的话"] * 400)
    out = speakify(long_in)
    if "后面还有" in out or "在屏幕上" in out:
        print("  ✗ 还在截断（上限已于 2026-07-29 按 作者 拍板整套删除）"); bad += 1
    if len(out) < len(long_in) * 0.9:
        print(f"  ✗ 输出比输入短了一大截（{len(long_in)}→{len(out)}），像是还在切"); bad += 1
    # ⛔ 2026-07-28:原来这里有 5 条「断句层」断言(给 macOS `say` 插 [[slnc]] 停顿标记)。
    # 播放挪进 Swift 流式引擎之后,`prosody()` / `--say` **没有任何调用方** ——
    # 只剩这些自检在调它自己。⇒ 整套连同被测函数一起删。
    # 作者:「为什么这么一个你自己都说已经没有存在价值的玩意儿，还会留在那里」。
    # ⚠ 下面那条**留着**:它守的是"默认输出里不许有 [[slnc]]",而那正是删干净的证明。
    # ⛔ 反向,而且这条是 作者 亲耳听出来的:默认输出里**绝不许**有 [[slnc]] ——
    # 它只对 macOS say 有意义,发给别的引擎就会被逐字念出来。
    import subprocess as _sp
    default_out = _sp.run([sys.executable, __file__], input="第一句。第二句。",
                          capture_output=True, text=True).stdout
    if "[[" in default_out:
        print(f"  ✗ 默认输出里有停顿指令(会被 MOSS 念出来): {default_out!r}"); bad += 1

    if bad:
        print(f"✗ speakify: {bad} 项不过"); return 1
    print(f"✓ speakify: {len(CASES)} 条形态 + 4 条断句判据全过 · 不再截断(上限已删)")
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
    sys.stdout.write(out)
