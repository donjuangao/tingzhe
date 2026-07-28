#!/usr/bin/env python3
"""吃 review.html 复制出来的回执，改词表 / 写负例 —— 由 Code 跑，作者 不用碰。

配对关系：`review.py` 出页面（作者 点选）→ 回执只含**词与条目号** → 本脚本按条目号
在**本地** JSONL 里取回那句原话写进 negatives.txt。
⛔ 句子全程留在本机：回执里没有句子，本脚本也不把句子打到 stdout（只打条目号与词）。

回执格式（review.html 自动生成，作者 不用记）：
  OK   #12  星规→星轨
  BAD  #7   星规→星轨
  MISS #3   「树权」应为「授权」

用法：
  ./apply_review.py <回执文件>        # 预演，只说要做什么，不动任何文件
  ./apply_review.py <回执文件> --go   # 真做
  pbpaste | ./apply_review.py - --go  # 直接吃剪贴板
"""
import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.abspath(__file__))
LOG = os.environ.get("TINGZHE_REVIEW_LOG",
                     os.path.expanduser("~/Library/Logs/tingzhe/transcripts.jsonl"))
NEG = os.path.join(REPO, "negatives.txt")
PROT = os.path.join(REPO, "protect.json")
BIN = os.path.join(REPO, "tingzhe.app/Contents/MacOS/tingzhe")
DEV = os.path.join(REPO, "build/dev/tingzhe")


def rows():
    if not os.path.exists(LOG):
        return []
    return [json.loads(l) for l in open(LOG, encoding="utf-8") if l.strip()]


def parse(text):
    """→ (oks, bads, misses)；每项带条目号。刻意宽松：多余空白/全角箭头/中文引号都吃。"""
    oks, bads, misses = [], [], []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r"^(OK|BAD|MISS)\s+#(\d+)\s*(.*)$", line, re.I)
        if not m:
            print(f"  ⚠ 读不懂这行，跳过: {line[:40]}")
            continue
        kind, idx, rest = m.group(1).upper(), int(m.group(2)), m.group(3)
        if kind == "OK":
            oks.append(idx)
        elif kind == "BAD":
            pm = re.search(r"保护[「\"']([^」\"']+)[」\"']", rest)
            bads.append((idx, pm.group(1).strip() if pm else None))
        else:
            mm = re.search(r"[「\"']([^」\"']+)[」\"'].*?[「\"']([^」\"']+)[」\"']", rest)
            if not mm:
                print(f"  ⚠ MISS #{idx} 少了词对，跳过")
                continue
            misses.append((idx, mm.group(1).strip(), mm.group(2).strip()))
    return oks, bads, misses


def main():
    args = [a for a in sys.argv[1:]]
    go = "--go" in args
    args = [a for a in args if a != "--go"]
    if not args:
        print(__doc__)
        sys.exit(2)
    text = sys.stdin.read() if args[0] == "-" else open(args[0], encoding="utf-8").read()

    R = rows()
    oks, bads, misses = parse(text)
    print(f"回执：OK {len(oks)} · BAD {len(bads)} · MISS {len(misses)}"
          + ("" if go else "   [预演，不动文件；加 --go 真做]"))

    # ① BAD → 那句原话进 negatives.txt（句子从本地 JSONL 取，不经过对话）
    add, prot_new = [], []
    for idx, word in bads:
        if word:
            prot_new.append(word)
        else:
            print(f"  ⚠ BAD #{idx} 没指定要保护哪个词 → 负例会记下，但闸会因此判红且无法修（去页面点一下候选）")
        if idx >= len(R):
            print(f"  ⚠ BAD #{idx} 超出记录范围（共 {len(R)} 条），跳过")
            continue
        s = R[idx].get("raw", "").strip()
        if not s:
            print(f"  ⚠ BAD #{idx} 原话为空，跳过")
            continue
        add.append(s)
    if add:
        have = set()
        if os.path.exists(NEG):
            have = {l.strip() for l in open(NEG, encoding="utf-8")}
        new = [s for s in add if s not in have]
        print(f"  → negatives.txt: 新增 {len(new)} 条（{len(add) - len(new)} 条已存在）"
              f"  ⛔ 句子不打印，只在文件里")
        if go and new:
            with open(NEG, "a", encoding="utf-8") as f:
                if not os.path.exists(NEG) or os.path.getsize(NEG) == 0:
                    f.write("# 词表把这些句子改坏过 —— 每行都不该再被词表动。check.sh 第 9 项守着。\n")
                for s in new:
                    f.write(s + "\n")

    # ①.5 保护词 → protect.json（中文侧词边界的唯一可行解：不猜，由 作者 点定）
    if prot_new:
        cur = []
        if os.path.exists(PROT):
            try:
                cur = json.load(open(PROT, encoding="utf-8"))
            except Exception:
                cur = []
        fresh = [w for w in prot_new if w not in cur]
        print(f"  → protect.json: 新增 {len(fresh)} 个保护词 {fresh}（{len(prot_new) - len(fresh)} 个已有）")
        if go and fresh:
            merged = cur + fresh
            open(PROT, "w", encoding="utf-8").write(
                "[\n" + ",\n".join("  " + json.dumps(w, ensure_ascii=False) for w in merged) + "\n]\n")

    # ② MISS → --fix 加规则
    exe = BIN if os.path.exists(BIN) else DEV
    for idx, wrong, right in misses:
        print(f"  → --fix {wrong} {right}   (条目 #{idx})")
        if go:
            r = subprocess.run([exe, "--fix", wrong, right], capture_output=True, text=True)
            for l in (r.stdout or "").splitlines():
                print("     " + l)
            if r.returncode != 0:
                print(f"     ⚠ 退出码 {r.returncode}（多半是校验拦下了，看上面的原因）")

    if go:
        print()
        print("跑一遍闸确认：./check.sh")
        print("（常驻进程会自己热重载，不用重启）")


if __name__ == "__main__":
    main()
